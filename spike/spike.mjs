// 48h feasibility gate, run keylessly: Sepolia tx -> hosted prover -> on-chain
// verification on CC3 Testnet. verifySingle is a view call, so this needs no
// private key, no gas and no deployed contract.
import { JsonRpcProvider } from 'ethers';
import { proofProvider, blockProver, chainInfo } from '@gluwa/usc-sdk';

const CC3_RPC = 'https://rpc.cc3-testnet.creditcoin.network';
const PROVER = 'https://prover.cc3-testnet.creditcoin.network';
const SEPOLIA = 'https://ethereum-sepolia-rpc.publicnode.com';
const CHAIN_KEY = 1; // Ethereum Sepolia, per the testnet environment table

const cc3 = new JsonRpcProvider(CC3_RPC);
const sep = new JsonRpcProvider(SEPOLIA);

const info = new chainInfo.PrecompileChainInfoProvider(cc3);
const prover = new blockProver.PrecompileBlockProver(cc3);

console.log('--- 1. what the ChainInfo precompile says is supported ---');
const chains = await info.getSupportedChains();
for (const c of chains) console.log(`   chainKey=${c.chainKey}  chainId=${c.chainId}  ${c.chainName}  encoding=${c.chainEncoding}`);

const latest = await info.getLatestAttestedHeightAndHash(CHAIN_KEY);
console.log(`\n--- 2. latest attested Sepolia block, as CC3 sees it ---`);
console.log(`   height=${latest.height}  isAttestation=${latest.isAttestation}  exists=${latest.exists}`);
const head = await sep.getBlockNumber();
console.log(`   live Sepolia head=${head}  -> attestation lag = ${head - Number(latest.height)} blocks`);

// Pick a transaction from a block we know is attested.
console.log(`\n--- 3. pick a source transaction from an attested block ---`);
let target = Number(latest.height), txHash = null;
for (let i = 0; i < 40 && !txHash; i++) {
  const b = await sep.getBlock(target - i);
  if (b?.transactions?.length) { txHash = b.transactions[0]; target = target - i; }
}
console.log(`   block=${target}  tx=${txHash}`);

console.log(`\n--- 4. hosted Proof Builder ---`);
const builder = new proofProvider.service.ProofBuilder(CHAIN_KEY, PROVER);
const res = await builder.getProof(txHash);
if (!res.success) { console.log('   FAILED:', JSON.stringify(res).slice(0, 300)); process.exit(1); }
const p = res.data;
console.log(`   headerNumber=${p.headerNumber}  txIndex=${p.txIndex}  cached=${p.cached}`);
console.log(`   merkle siblings=${p.merkleProof.siblings.length}  continuity roots=${p.continuityProof.roots.length}`);
console.log(`   txBytes=${p.txBytes.length} chars`);

console.log(`\n--- 5. ON-CHAIN verification via the 0x0FD2 BlockProver precompile ---`);
const ok = await prover.verifySingle(p.chainKey, p.headerNumber, p.txBytes, p.merkleProof, p.continuityProof);
console.log(`   verifySingle -> ${ok}`);

console.log(`\n--- 6. NEGATIVE control: same proof, one byte of the tx flipped ---`);
const tampered = p.txBytes.slice(0, -2) + (p.txBytes.slice(-2) === 'ff' ? 'ee' : 'ff');
try {
  const bad = await prover.verifySingle(p.chainKey, p.headerNumber, tampered, p.merkleProof, p.continuityProof);
  console.log(`   tampered -> ${bad}   ${bad === false ? '(correctly rejected)' : '*** ACCEPTED A FORGERY ***'}`);
} catch (e) {
  console.log(`   tampered -> reverted (correctly rejected): ${String(e.shortMessage || e.message).slice(0, 120)}`);
}

console.log(`\n--- 7. NEGATIVE control: wrong chainKey ---`);
try {
  const bad2 = await prover.verifySingle(3, p.headerNumber, p.txBytes, p.merkleProof, p.continuityProof);
  console.log(`   chainKey=3 -> ${bad2}   ${bad2 === false ? '(correctly rejected)' : '*** ACCEPTED WRONG CHAIN ***'}`);
} catch (e) {
  console.log(`   chainKey=3 -> reverted (correctly rejected): ${String(e.shortMessage || e.message).slice(0, 120)}`);
}
