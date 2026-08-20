// The loop: watch Sepolia for authorisations, wait for them to become provable, decide whether to
// carry them, and hand them to a contract that will check our work.
//
// Read the ordering as a claim about trust. The agent decides *before* it proves, so a refusal
// costs nothing; it proves *before* it submits, so a submission is never speculative; and the
// contract re-derives everything *after* it submits, so the agent's judgement is never the last
// word. A compromised agent in this arrangement can stop paying out and can waste its own gas. It
// cannot pay out on something that did not happen.
import { JsonRpcProvider, Wallet, Contract, type ContractEventPayload, type EventLog } from 'ethers';
import { load } from './config.js';
import { Attestcoin, type Proof } from './attestcoin.js';
import { judge, Ledger, DEFAULT_LIMITS, type Authorisation } from './policy.js';

const SOURCE_ABI = ['event Authorised(address indexed actor, uint256 amount, uint256 deadline)'];
const GOVERNOR_ABI = [
  'function execute(uint64 chainKey, uint64 height, bytes encodedTransaction, ' +
    '(bytes32,(bytes32,bool)[]) merkleProof, (bytes32,bytes32[]) continuityProof)',
  'function consumed(bytes32) view returns (bool)',
  'function credited(address) view returns (uint256)',
];

const now = (): number => Math.floor(Date.now() / 1000);
const log = (...a: unknown[]) => console.log(new Date().toISOString().slice(11, 19), ...a);

async function main(): Promise<void> {
  const cfg = load();
  const source = new JsonRpcProvider(cfg.sourceRpc);
  const target = new JsonRpcProvider(cfg.targetRpc);
  const attestcoin = new Attestcoin(cfg, source, target);

  // Before anything else. A chainKey that resolves to the wrong chain here produces proofs that are
  // genuine and universally rejected, and no later error message would point at the cause.
  await attestcoin.assertChainKeyIsWhatWeThink();
  log(`chainKey ${cfg.chainKey} confirmed as chainId ${cfg.sourceChainId}`);

  const key = process.env.PRIVATE_KEY;
  const signer = key ? new Wallet(key, target) : null;
  if (!signer) log('no PRIVATE_KEY set — running in observe-only mode, nothing will be submitted');

  const governor = new Contract(cfg.governor, GOVERNOR_ABI, signer ?? target);
  // Resolve the fragment up front rather than relying on the dynamic proxy: a typo in the ABI
  // string would otherwise surface as `undefined is not a function` at submission time, minutes
  // after the authorisation that triggered it.
  const execute = governor.getFunction('execute');
  const ledger = new Ledger();

  const watched = new Contract(cfg.sourceAuthorization, SOURCE_ABI, source);

  // One ingestion path for both the historical scan and the live feed, so an authorisation is
  // handled identically however it arrives, and never twice. A live subscription delivers events
  // only from the moment it connects, so the same event can also surface in the backfill; the seen
  // set keyed on tx-hash + log-index collapses that overlap.
  const seen = new Set<string>();
  async function ingest(ev: EventLog): Promise<void> {
    const [actor, amount, deadline] = ev.args as unknown as [string, bigint, bigint];
    const key = `${ev.transactionHash}:${ev.index}`;
    if (seen.has(key)) return;
    seen.add(key);

    const auth: Authorisation = {
      actor,
      amount,
      deadline: Number(deadline),
      txHash: ev.transactionHash,
      sourceHeight: ev.blockNumber,
      observedAt: now(),
    };
    log(`seen  ${auth.txHash.slice(0, 12)}…  actor=${actor.slice(0, 10)}…  amount=${amount}`);
    try {
      await handle(auth);
    } catch (e) {
      log(`error ${auth.txHash.slice(0, 12)}…  ${(e as Error).message}`);
    }
  }

  // Catch up on anything emitted while the agent was down BEFORE going live, so a restart is not a
  // silent outage for whoever authorised in the gap.
  const head = await source.getBlockNumber();
  const from = Math.max(0, head - cfg.lookbackBlocks);
  const past = (await watched.queryFilter('Authorised', from, head)) as EventLog[];
  log(`watching ${cfg.sourceAuthorization} on chainId ${cfg.sourceChainId} — backfilling ${past.length} from block ${from}`);
  for (const ev of past) await ingest(ev);

  await watched.on('Authorised', (_actor, _amount, _deadline, payload: ContractEventPayload) =>
    ingest(payload.log),
  );

  async function handle(auth: Authorisation): Promise<void> {
    // Judge first. Most refusals are knowable now, and waiting eight minutes to refuse something we
    // could refuse immediately is time the operator spends not knowing.
    const { blocks } = await attestcoin.lag();
    const verdict = judge(auth, ledger, blocks, now(), DEFAULT_LIMITS);
    if (!verdict.forward) {
      log(`hold  ${auth.txHash.slice(0, 12)}…  ${verdict.reason}`);
      return;
    }

    // Reserve in the SAME synchronous tick as the verdict — there is no await between them — so a
    // burst of concurrent handlers for one actor each see the others' reservations. Recording only
    // after the transaction lands (minutes later, past several awaits) would let every handler in a
    // burst pass the velocity and exposure checks against a ledger that is still empty, which is the
    // one situation those limits exist for. Released below on every path that does not land.
    const reservation = ledger.reserve(auth.actor, auth.amount, now());
    try {
      log(`wait  ${auth.txHash.slice(0, 12)}…  block ${auth.sourceHeight}, attestation is ${blocks} behind`);
      const proof: Proof = await attestcoin.proveWhenReady(auth.txHash, auth.sourceHeight, {
        onWait: (l) => log(`      …attested to ${l.attestedHeight}, need ${auth.sourceHeight}`),
      });

      // Re-judge on the far side of the wait. Minutes passed, so the deadline or the attestation lag
      // may have moved; velocity was already decided and reserved above, so recheckOnly skips it.
      const second = judge(auth, ledger, (await attestcoin.lag()).blocks, now(), DEFAULT_LIMITS, {
        recheckOnly: true,
      });
      if (!second.forward) {
        ledger.release(reservation);
        log(`hold  ${auth.txHash.slice(0, 12)}…  after waiting: ${second.reason}`);
        return;
      }

      if (!signer) {
        ledger.release(reservation);
        log(`would submit ${auth.txHash.slice(0, 12)}…  (observe-only)`);
        return;
      }

      const tx = await execute(
        proof.chainKey,
        proof.headerNumber,
        proof.txBytes,
        [proof.merkleProof.root, proof.merkleProof.siblings.map((s) => [s.hash, s.isLeft])],
        [proof.continuityProof.lowerEndpointDigest, proof.continuityProof.roots],
      );
      const receipt = await tx.wait();
      // The reservation stays — it is now the permanent record of a landed carry.
      log(`done  ${auth.txHash.slice(0, 12)}…  -> CC3 ${receipt.hash}  credited ${auth.amount}`);
    } catch (e) {
      // A proof timeout, an RPC hiccup, a reverted submission — none of these landed, so the
      // reservation must not keep counting against the actor's limit. The outer handler logs.
      ledger.release(reservation);
      throw e;
    }
  }

  // Nothing below this line: the process lives in the event handler.
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
