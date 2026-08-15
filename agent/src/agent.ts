// The loop: watch Sepolia for authorisations, wait for them to become provable, decide whether to
// carry them, and hand them to a contract that will check our work.
//
// Read the ordering as a claim about trust. The agent decides *before* it proves, so a refusal
// costs nothing; it proves *before* it submits, so a submission is never speculative; and the
// contract re-derives everything *after* it submits, so the agent's judgement is never the last
// word. A compromised agent in this arrangement can stop paying out and can waste its own gas. It
// cannot pay out on something that did not happen.
import { JsonRpcProvider, Wallet, Contract, type ContractEventPayload } from 'ethers';
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
  log(`watching ${cfg.sourceAuthorization} on chainId ${cfg.sourceChainId}`);

  await watched.on('Authorised', async (actor: string, amount: bigint, deadline: bigint, ev: ContractEventPayload) => {
    const auth: Authorisation = {
      actor,
      amount,
      deadline: Number(deadline),
      txHash: ev.log.transactionHash,
      sourceHeight: ev.log.blockNumber,
      observedAt: now(),
    };
    log(`seen  ${auth.txHash.slice(0, 12)}…  actor=${actor.slice(0, 10)}…  amount=${amount}`);

    try {
      await handle(auth);
    } catch (e) {
      log(`error ${auth.txHash.slice(0, 12)}…  ${(e as Error).message}`);
    }
  });

  async function handle(auth: Authorisation): Promise<void> {
    // Judge first. Most refusals are knowable now, and waiting eight minutes to refuse something we
    // could refuse immediately is time the operator spends not knowing.
    const { blocks } = await attestcoin.lag();
    const verdict = judge(auth, ledger, blocks, now(), DEFAULT_LIMITS);
    if (!verdict.forward) {
      log(`hold  ${auth.txHash.slice(0, 12)}…  ${verdict.reason}`);
      return;
    }

    log(`wait  ${auth.txHash.slice(0, 12)}…  block ${auth.sourceHeight}, attestation is ${blocks} behind`);
    const proof: Proof = await attestcoin.proveWhenReady(auth.txHash, auth.sourceHeight, {
      onWait: (l) => log(`      …attested to ${l.attestedHeight}, need ${auth.sourceHeight}`),
    });

    // Judge again on the far side of the wait. Minutes passed; the deadline may have, too.
    const second = judge(auth, ledger, (await attestcoin.lag()).blocks, now(), DEFAULT_LIMITS);
    if (!second.forward) {
      log(`hold  ${auth.txHash.slice(0, 12)}…  after waiting: ${second.reason}`);
      return;
    }

    if (!signer) {
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
    ledger.record(auth.actor, auth.amount, now());
    log(`done  ${auth.txHash.slice(0, 12)}…  -> CC3 ${receipt.hash}  credited ${auth.amount}`);
  }

  // Nothing below this line: the process lives in the event handler.
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
