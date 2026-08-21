// One-shot end-to-end: take the most recent Repaid on Sepolia, wait for it to be attested, prove it,
// and post it to the loan book on Creditcoin. This is the agent's inner loop run once, for a clean
// first end-to-end you can watch start to finish.
//
//   node tools/post-once.mjs            # newest repayment
//   node tools/post-once.mjs <txHash>   # a specific one
//
// Reads agent/.env for addresses and PRIVATE_KEY. Needs CC3 gas (you have ~10000 tCTC).
//
// Why it polls the receipt by hand instead of tx.wait(): CC3 is a Substrate/Frontier chain whose
// block JSON omits fields (e.g. mixHash) that strict decoders expect — forge's alloy chokes on it,
// and ethers' confirmation path can too. Receipts don't carry those fields, so getTransactionReceipt
// in a loop is the robust way to confirm the post landed.
import { readFileSync } from 'node:fs';
import { JsonRpcProvider, Wallet, Contract, Interface } from 'ethers';
import { chainInfo, proofProvider } from '@gluwa/usc-sdk';

for (const line of readFileSync(new URL('../agent/.env', import.meta.url), 'utf8').split('\n')) {
  const m = line.match(/^([A-Z_]+)=(.*)$/);
  if (m && !process.env[m[1]]) process.env[m[1]] = m[2].trim();
}
const {
  PRIVATE_KEY, LOAN_REPAYMENT, LOAN_BOOK,
  SEPOLIA_RPC = 'https://ethereum-sepolia-rpc.publicnode.com',
  CC3_RPC = 'https://rpc.cc3-testnet.creditcoin.network',
  PROVER_URL = 'https://prover.cc3-testnet.creditcoin.network',
} = process.env;
if (!PRIVATE_KEY) throw new Error('set PRIVATE_KEY in agent/.env');
const CHAIN_KEY = 1;

const sep = new JsonRpcProvider(SEPOLIA_RPC);
const cc3 = new JsonRpcProvider(CC3_RPC);
const info = new chainInfo.PrecompileChainInfoProvider(cc3);
const builder = new proofProvider.service.ProofBuilder(CHAIN_KEY, PROVER_URL);
const wallet = new Wallet(PRIVATE_KEY, cc3);
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

const REPAID = new Interface(['event Repaid(address indexed borrower, uint256 indexed loanId, uint256 amount, uint256 deadline)']);
const BOOK = new Interface([
  'function post(uint64 chainKey, uint64 height, bytes encodedTransaction, (bytes32,(bytes32,bool)[]) merkleProof, (bytes32,bytes32[]) continuityProof)',
  'function totalRepaid(address) view returns (uint256)',
  'function repaymentCount(address) view returns (uint256)',
  'function consumed(bytes32) view returns (bool)',
]);

// 1. Find the repayment to post.
let txHash = process.argv[2];
if (!txHash) {
  const head = await sep.getBlockNumber();
  const logs = await sep.getLogs({
    address: LOAN_REPAYMENT, fromBlock: head - 7200, toBlock: head, topics: [REPAID.getEvent('Repaid').topicHash],
  });
  if (!logs.length) throw new Error('no Repaid events found in the last 7200 blocks — run script/Repay.s.sol first');
  txHash = logs[logs.length - 1].transactionHash;
}
const rc = await sep.getTransactionReceipt(txHash);
if (!rc) throw new Error(`no receipt for ${txHash}`);
const ev = REPAID.parseLog(rc.logs.find((l) => l.address.toLowerCase() === LOAN_REPAYMENT.toLowerCase()));
log(`repayment ${txHash.slice(0, 14)}…  borrower ${ev.args.borrower.slice(0, 10)}…  loan ${ev.args.loanId}  amount ${ev.args.amount}`);
const deadline = Number(ev.args.deadline);
if (deadline * 1000 < Date.now()) throw new Error(`this repayment's deadline (${new Date(deadline * 1000).toISOString()}) has passed — make a fresh one with a longer VALID_FOR`);

// 2. Wait until its block is attested on CC3.
const height = rc.blockNumber;
for (;;) {
  const attested = Number((await info.getLatestAttestedHeightAndHash(CHAIN_KEY)).height);
  if (attested >= height) { log(`attested (${attested} >= ${height})`); break; }
  log(`waiting for attestation… at ${attested}, need ${height} (~${Math.max(0, height - attested)} blocks behind)`);
  await new Promise((r) => setTimeout(r, 30_000));
}

// 3. Prove it.
const res = await builder.getProof(txHash);
if (!res.success || !res.data) throw new Error(`proof failed: ${JSON.stringify(res).slice(0, 200)}`);
const p = res.data;
log(`proof ready  height ${p.headerNumber}  merkle siblings ${p.merkleProof.siblings.length}`);

// 4. Post it to the book.
const book = new Contract(LOAN_BOOK, BOOK, wallet);
const before = await book.totalRepaid(ev.args.borrower);
const data = BOOK.encodeFunctionData('post', [
  p.chainKey, p.headerNumber, p.txBytes,
  [p.merkleProof.root, p.merkleProof.siblings.map((s) => [s.hash, s.isLeft])],
  [p.continuityProof.lowerEndpointDigest, p.continuityProof.roots],
]);
const sent = await wallet.sendTransaction({ to: LOAN_BOOK, data });
log(`post submitted ${sent.hash} — polling for the receipt…`);

// Manual receipt poll (see header): robust against CC3 block-format quirks.
let receipt = null;
for (let i = 0; i < 60 && !receipt; i++) {
  receipt = await cc3.getTransactionReceipt(sent.hash).catch(() => null);
  if (!receipt) await new Promise((r) => setTimeout(r, 3_000));
}
if (!receipt) throw new Error('no receipt after 3 minutes');
if (receipt.status !== 1) throw new Error(`post reverted (tx ${sent.hash})`);

const after = await book.totalRepaid(ev.args.borrower);
const count = await book.repaymentCount(ev.args.borrower);
log(`POSTED  block ${receipt.blockNumber}`);
log(`credit history: totalRepaid ${before} -> ${after}  (repaymentCount now ${count})`);
log(`\nEnd to end: a real Sepolia repayment is now an unforgeable entry in the borrower's Creditcoin credit history.`);
