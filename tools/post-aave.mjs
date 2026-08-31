// Find a real Aave V3 repayment, prove it with Attestcoin, and post it to AaveLoanBook on Creditcoin.
//
//   AAVE_BOOK=0x… PRIVATE_KEY=0x… node tools/post-aave.mjs
//   AAVE_BOOK=0x… node tools/post-aave.mjs --dry     # everything except the send
//
// The borrower is whoever Aave says it is. We do not pick them, cannot influence them, and only find
// out who they are by reading the event — which is the difference between this and posting a
// repayment to a contract we wrote ourselves.
import { JsonRpcProvider, Wallet, Contract, AbiCoder, id, getAddress, formatUnits } from 'ethers';
import { proofProvider } from '@gluwa/usc-sdk';

const CC3_RPC = process.env.CC3_RPC ?? 'https://rpc.cc3-testnet.creditcoin.network';
const PROVER_URL = process.env.PROVER_URL ?? 'https://prover.cc3-testnet.creditcoin.network';
const SEPOLIA_RPC = process.env.SEPOLIA_RPC ?? 'https://ethereum-sepolia-rpc.publicnode.com';
const CHAIN_KEY = Number(process.env.CHAIN_KEY ?? 1);
const POOL = getAddress(process.env.AAVE_POOL ?? '0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951');
const REPAY = id('Repay(address,address,address,uint256,bool)');

const dry = process.argv.includes('--dry');
const abi = AbiCoder.defaultAbiCoder();
const die = (m) => { console.error(`\n${m}`); process.exit(1); };

const BOOK_ABI = [
  'function post(uint64 chainKey, uint64 height, bytes encodedTransaction, (bytes32 root,(bytes32 hash,bool isLeft)[] siblings) merkleProof, (bytes32 lowerEndpointDigest,bytes32[] roots) continuityProof, uint256 logIndex)',
  'function totalRepaid(address) view returns (uint256)',
  'function repaymentCount(address) view returns (uint256)',
  'function repaidByOthers(address) view returns (uint256)',
  'function pool() view returns (address)',
  'function maxAgeBlocks() view returns (uint64)',
];

const CHAIN_INFO_ABI = [
  'function get_latest_attestation_height_and_hash(uint64) view returns ((uint64 height,bytes32 hash,bool isAttestation,bool exists))',
];
const CHAIN_INFO = '0x0000000000000000000000000000000000000fD3';

const bookAddr = process.env.AAVE_BOOK;
if (!bookAddr) die('set AAVE_BOOK to the deployed AaveLoanBook address');

const cc3 = new JsonRpcProvider(CC3_RPC);
const sep = new JsonRpcProvider(SEPOLIA_RPC);
const book = new Contract(bookAddr, BOOK_ABI, cc3);
const info = new Contract(CHAIN_INFO, CHAIN_INFO_ABI, cc3);

// 1. How far Creditcoin has attested. A repayment in an unattested block cannot be proven, and one
//    older than the book's window will be refused on-chain — so bound the search by both ends here
//    rather than discovering it in a reverting transaction.
const tip = await info.get_latest_attestation_height_and_hash(CHAIN_KEY);
if (!tip.exists) die(`Creditcoin has no attestation for chainKey ${CHAIN_KEY}`);
const attested = Number(tip.height);
const maxAge = Number(await book.maxAgeBlocks());
const head = await sep.getBlockNumber();
console.log(`attested height ${attested}   sepolia head ${head}   lag ${head - attested} blocks`);
console.log(`book accepts repayments within ${maxAge} source blocks of the tip\n`);

const onChainPool = getAddress(await book.pool());
if (onChainPool !== POOL) die(`book reads ${onChainPool}, this script is looking at ${POOL}`);

// 2. Find a repayment that is both attested and inside the freshness window.
const floor = Math.max(attested - maxAge + 1, 0);
let logs = [];
for (const span of [5_000, 20_000, Math.max(attested - floor, 1)]) {
  const from = Math.max(attested - span, floor);
  logs = await sep.getLogs({ address: POOL, topics: [REPAY], fromBlock: from, toBlock: attested });
  if (logs.length) break;
  console.log(`no repayments in the last ${span} attested blocks, widening…`);
}
if (!logs.length) die('no Aave repayment found that is attested and still fresh');

const target = logs[logs.length - 1];
const user = getAddress('0x' + target.topics[2].slice(26));
const repayer = getAddress('0x' + target.topics[3].slice(26));
console.log(`repayment  ${target.transactionHash}`);
console.log(`  block    ${target.blockNumber}  (${attested - target.blockNumber} behind the tip)`);
console.log(`  user     ${user}`);
console.log(`  repayer  ${repayer}${repayer === user ? '  (self-repaid — this one earns credit)' : '  (third party — recorded, not credited)'}`);
console.log(`  amount   ${formatUnits(BigInt(target.data.slice(0, 66)), 6)} (assuming 6dp)\n`);

// 3. Build the proof.
const builder = new proofProvider.service.ProofBuilder(CHAIN_KEY, PROVER_URL);
const res = await builder.getProof(target.transactionHash);
if (!res.success) die(`proof builder refused: ${JSON.stringify(res).slice(0, 300)}`);
const p = res.data;
console.log(`proof      headerNumber=${p.headerNumber} txIndex=${p.txIndex} siblings=${p.merkleProof.siblings.length} roots=${p.continuityProof.roots.length}`);

// 4. Find the log index the CONTRACT wants.
//
//    This is the one place where the obvious value is the wrong one. `eth_getLogs` numbers logs per
//    BLOCK; the attested receipt numbers them per TRANSACTION, and the book indexes the receipt. For
//    a repayment observed while building this, the two were 53 and 5. Passing the block-level index
//    reverts on a short receipt and, on a long one, reads a different event and credits the wrong
//    borrower — a wrong answer rather than an error. So derive it from the payload the contract will
//    actually see.
const [, chunks] = abi.decode(['uint8', 'bytes[]'], p.txBytes);
const [status, , receiptLogs] = abi.decode(
  ['uint8', 'uint64', 'tuple(address,bytes32[],bytes)[]', 'bytes'],
  chunks[chunks.length - 1],
);
if (Number(status) !== 1) die('the source transaction reverted; the book would refuse it');
const logIndex = receiptLogs.findIndex(
  (l) => getAddress(l[0]) === POOL && l[1][0]?.toLowerCase() === REPAY.toLowerCase(),
);
if (logIndex < 0) die('the Repay event is not in the attested receipt');
console.log(`logIndex   ${logIndex} within the transaction  (${target.index} within the block — not the same number)\n`);

const before = {
  credited: await book.totalRepaid(user),
  count: await book.repaymentCount(user),
  others: await book.repaidByOthers(user),
};

if (dry) {
  console.log('--dry: nothing sent. Would post:');
  console.log(`  post(${CHAIN_KEY}, ${p.headerNumber}, <${p.txBytes.length} chars>, …, logIndex=${logIndex})`);
  process.exit(0);
}

const pk = process.env.PRIVATE_KEY;
if (!pk) die('set PRIVATE_KEY (or pass --dry)');
const wallet = new Wallet(pk, cc3);
const signer = book.connect(wallet);

const args = [
  CHAIN_KEY,
  p.headerNumber,
  p.txBytes,
  { root: p.merkleProof.root, siblings: p.merkleProof.siblings.map((s) => ({ hash: s.hash, isLeft: s.isLeft })) },
  { lowerEndpointDigest: p.continuityProof.lowerEndpointDigest, roots: p.continuityProof.roots },
  logIndex,
];

// CC3 is Frontier-based and under-estimates gas for calls that touch a precompile; a plain send
// reverts out of gas. Estimate, then give it room.
let gasLimit;
try {
  gasLimit = ((await signer.post.estimateGas(...args)) * 4n);
} catch (e) {
  console.log(`gas estimation reverted (${String(e.shortMessage ?? e.message).slice(0, 120)}) — using a fixed limit`);
  gasLimit = 3_000_000n;
}

const tx = await signer.post(...args, { gasLimit });
console.log(`submitted  ${tx.hash}`);
const rcpt = await tx.wait();
console.log(`status     ${rcpt.status === 1 ? 'success' : 'REVERTED'}  block ${rcpt.blockNumber}  gas ${rcpt.gasUsed}`);
if (rcpt.status !== 1) process.exit(1);

const after = {
  credited: await book.totalRepaid(user),
  count: await book.repaymentCount(user),
  others: await book.repaidByOthers(user),
};
console.log(`\n${user}`);
console.log(`  totalRepaid     ${before.credited} -> ${after.credited}`);
console.log(`  repaymentCount  ${before.count} -> ${after.count}`);
console.log(`  repaidByOthers  ${before.others} -> ${after.others}`);
console.log(`\nA repayment made to Aave by someone we have never met is now credit history on Creditcoin.`);
