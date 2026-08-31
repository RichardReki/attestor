// Can Attestcoin prove a repayment made to a lending protocol we did not write?
//
// `spike.mjs` answered "can this pipeline prove an arbitrary Sepolia transaction". This answers the
// question that actually matters for AaveLoanBook: take a REAL `Repay` event emitted by the real
// Aave V3 Pool, prove it, verify it on Creditcoin, and then confirm the attested payload still
// contains the event — because the book reads the log, not the calldata, and nothing guarantees the
// prover carries logs through until you look.
//
// Keyless: `verifySingle` is a view call. No private key, no gas, no deployment.
//
//   cd spike && node aave-proof.mjs
import { JsonRpcProvider, AbiCoder, id, getAddress } from 'ethers';
import { proofProvider, blockProver, chainInfo } from '@gluwa/usc-sdk';

const CC3_RPC = 'https://rpc.cc3-testnet.creditcoin.network';
const PROVER = 'https://prover.cc3-testnet.creditcoin.network';
const SEPOLIA = 'https://ethereum-sepolia-rpc.publicnode.com';
const CHAIN_KEY = 1;

const POOL = '0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951'; // Aave V3 Pool, Sepolia
const REPAY = id('Repay(address,address,address,uint256,bool)');

const cc3 = new JsonRpcProvider(CC3_RPC);
const sep = new JsonRpcProvider(SEPOLIA);
const abi = AbiCoder.defaultAbiCoder();

const info = new chainInfo.PrecompileChainInfoProvider(cc3);
const prover = new blockProver.PrecompileBlockProver(cc3);

const fail = (m) => { console.log(`\n*** ${m}`); process.exit(1); };

console.log('--- 1. how far Creditcoin has attested Sepolia ---');
const tip = await info.getLatestAttestedHeightAndHash(CHAIN_KEY);
const head = await sep.getBlockNumber();
console.log(`   attested height = ${tip.height}   live Sepolia head = ${head}   lag = ${head - Number(tip.height)} blocks`);

console.log('\n--- 2. find a real Aave V3 repayment inside the attested range ---');
// Search backwards from the attested tip, not from the chain head: a repayment in a block Creditcoin
// has not attested yet cannot be proven, however real it is.
const to = Number(tip.height);
let logs = [];
for (const span of [5_000, 20_000, 60_000]) {
  logs = await sep.getLogs({ address: POOL, topics: [REPAY], fromBlock: to - span, toBlock: to });
  if (logs.length) break;
  console.log(`   none in the last ${span} attested blocks, widening…`);
}
if (!logs.length) fail('no Aave repayments found inside the attested range');

const target = logs[logs.length - 1]; // the most recent one that is already attested
console.log(`   ${logs.length} repayments in range; taking the newest`);
console.log(`   tx        ${target.transactionHash}`);
console.log(`   block     ${target.blockNumber}   (${to - target.blockNumber} blocks behind the attested tip)`);
console.log(`   BLOCK-level logIndex ${target.index}   <- note: per block, not per transaction`);
console.log(`   user      ${getAddress('0x' + target.topics[2].slice(26))}`);
console.log(`   repayer   ${getAddress('0x' + target.topics[3].slice(26))}`);
console.log(`   amount    ${BigInt(target.data.slice(0, 66))}`);

console.log('\n--- 3. hosted Proof Builder ---');
const builder = new proofProvider.service.ProofBuilder(CHAIN_KEY, PROVER);
const res = await builder.getProof(target.transactionHash);
if (!res.success) fail(`proof builder refused: ${JSON.stringify(res).slice(0, 300)}`);
const p = res.data;
console.log(`   headerNumber=${p.headerNumber}  txIndex=${p.txIndex}  siblings=${p.merkleProof.siblings.length}  roots=${p.continuityProof.roots.length}`);

console.log('\n--- 4. on-chain verification via the 0x0FD2 precompile ---');
const ok = await prover.verifySingle(p.chainKey, p.headerNumber, p.txBytes, p.merkleProof, p.continuityProof);
console.log(`   verifySingle -> ${ok}`);
if (!ok) fail('the precompile rejected a proof of a real Aave repayment');

console.log('\n--- 5. does the ATTESTED payload still contain the event? ---');
// This is the assumption AaveLoanBook rests on. The receipt is the last chunk whatever the tx type.
const [txType, chunks] = abi.decode(['uint8', 'bytes[]'], p.txBytes);
const receipt = chunks[chunks.length - 1];
const [status, , decodedLogs] = abi.decode(
  ['uint8', 'uint64', 'tuple(address,bytes32[],bytes)[]', 'bytes'],
  receipt,
);
console.log(`   txType=${txType}  chunks=${chunks.length}  status=${status}  logs in receipt = ${decodedLogs.length}`);
if (!decodedLogs.length) fail('the attested receipt carries NO logs — AaveLoanBook cannot work');

// The index the contract wants is the position within THIS TRANSACTION's logs. The value returned by
// eth_getLogs is the position within the BLOCK. Passing the block-level one would read a different
// event, or none. Find the real one and show both, so the difference is on the record.
const inTx = decodedLogs.findIndex(
  (l) => l[0].toLowerCase() === POOL.toLowerCase() && l[1][0]?.toLowerCase() === REPAY.toLowerCase(),
);
if (inTx < 0) fail('the Repay event is not in the attested receipt');

const [addr, topics, data] = decodedLogs[inTx];
const amount = BigInt(abi.decode(['uint256', 'bool'], data)[0]);
console.log(`   TRANSACTION-level logIndex ${inTx}   (block-level was ${target.index})`);
console.log(`   emitter   ${addr}`);
console.log(`   user      ${getAddress('0x' + topics[2].slice(26))}`);
console.log(`   repayer   ${getAddress('0x' + topics[3].slice(26))}`);
console.log(`   amount    ${amount}`);

const same =
  addr.toLowerCase() === POOL.toLowerCase() &&
  topics[2].toLowerCase() === target.topics[2].toLowerCase() &&
  topics[3].toLowerCase() === target.topics[3].toLowerCase() &&
  amount === BigInt(target.data.slice(0, 66));
console.log(`   matches what Sepolia's own RPC reports: ${same}`);
if (!same) fail('the attested log does not match the source chain');

console.log('\n--- 6. NEGATIVE control: one byte of the transaction flipped ---');
const tampered = p.txBytes.slice(0, -2) + (p.txBytes.slice(-2) === 'ff' ? 'ee' : 'ff');
try {
  const bad = await prover.verifySingle(p.chainKey, p.headerNumber, tampered, p.merkleProof, p.continuityProof);
  console.log(`   tampered -> ${bad}  ${bad === false ? '(correctly rejected)' : '*** ACCEPTED A FORGERY ***'}`);
  if (bad !== false) process.exit(1);
} catch (e) {
  console.log(`   tampered -> reverted (correctly rejected): ${String(e.shortMessage || e.message).slice(0, 110)}`);
}

console.log(`
=== what this establishes ===
A repayment made by a stranger to Aave V3 — a protocol we did not write and cannot influence — is
provable on Creditcoin, and the attested payload still carries the event AaveLoanBook reads.
Post it with chainKey=${p.chainKey}, height=${p.headerNumber}, logIndex=${inTx}.

Note the two different log indices above. eth_getLogs numbers logs per BLOCK; the attested receipt
numbers them per TRANSACTION, and the contract indexes the latter. They are equal only when the
repayment happens to be in the first transaction of its block.`);
