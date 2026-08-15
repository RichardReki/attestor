// Captures a real, attested Sepolia contract call as a test fixture: the exact `txBytes` the
// BlockProver precompile verified, alongside the same transaction's fields read independently from
// a Sepolia RPC.
//
// The point is the independence. `AttestedTx` was written by reading the encoder's source, so a
// test that feeds it data this repo also encoded would only prove we are self-consistent. Ground
// truth here comes from eth_getTransactionByHash / eth_getTransactionReceipt — a different source,
// which the decoder has to agree with.
//
//   node tools/capture-fixture.mjs
//
// Writes contracts/test/fixtures/sepolia-call.json. Needs no key and no gas.
import { writeFileSync, mkdirSync } from 'node:fs';
import { JsonRpcProvider } from 'ethers';
import { proofProvider, blockProver, chainInfo } from '@gluwa/usc-sdk';

const CC3_RPC = 'https://rpc.cc3-testnet.creditcoin.network';
const PROVER = 'https://prover.cc3-testnet.creditcoin.network';
const SEPOLIA = 'https://ethereum-sepolia-rpc.publicnode.com';
const CHAIN_KEY = 1;

const cc3 = new JsonRpcProvider(CC3_RPC);
const sep = new JsonRpcProvider(SEPOLIA);
const info = new chainInfo.PrecompileChainInfoProvider(cc3);
const prover = new blockProver.PrecompileBlockProver(cc3);

const latest = await info.getLatestAttestedHeightAndHash(CHAIN_KEY);
console.log(`latest attested Sepolia height: ${latest.height}`);

// Find a *contract call* — `to` set and at least a selector. A plain transfer would exercise none
// of the selector/argument logic, and a contract creation is rejected by the decoder outright.
let picked = null;
for (let h = Number(latest.height); h > Number(latest.height) - 30 && !picked; h--) {
  const block = await sep.getBlock(h, true);
  if (!block) continue;
  for (const txh of block.transactions) {
    const tx = await sep.getTransaction(txh);
    if (!tx?.to || (tx.data?.length ?? 0) < 10) continue; // 0x + 8 hex chars = a selector
    const rx = await sep.getTransactionReceipt(txh);
    if (!rx) continue;
    picked = { tx, rx, height: h };
    break;
  }
}
if (!picked) throw new Error('no contract call found in the attested range');

const { tx, rx, height } = picked;
console.log(`picked ${tx.hash}\n  block=${height} type=${tx.type} from=${tx.from} to=${tx.to} status=${rx.status}`);

const res = await new proofProvider.service.ProofBuilder(CHAIN_KEY, PROVER).getProof(tx.hash);
if (!res.success) throw new Error(`proof failed: ${JSON.stringify(res).slice(0, 200)}`);
const p = res.data;

// Only fixture a transaction the precompile itself accepts; otherwise the test would be asserting
// against bytes that are not actually provable.
const ok = await prover.verifySingle(p.chainKey, p.headerNumber, p.txBytes, p.merkleProof, p.continuityProof);
if (!ok) throw new Error('precompile rejected the proof for the captured transaction');
console.log(`  precompile verify -> ${ok}`);

const fixture = {
  note: 'Real attested Sepolia contract call. expected.* comes from a Sepolia RPC, NOT from the encoder.',
  txHash: tx.hash,
  chainKey: p.chainKey,
  height: p.headerNumber,
  txType: tx.type,
  chunkCount: null, // filled below
  txBytes: p.txBytes,
  expected: {
    from: tx.from,
    to: tx.to,
    value: tx.value.toString(),
    nonce: tx.nonce,
    status: rx.status,
    selector: tx.data.slice(0, 10),
    dataLength: (tx.data.length - 2) / 2,
  },
};

// Record how many chunks this transaction type produced — the count that varies, and that a
// consumer must not hardcode.
const { AbiCoder } = await import('ethers');

// Store the two proof structs ABI-encoded exactly as IBlockProver declares them, so the fork test
// can abi.decode them straight into Solidity structs instead of walking JSON field by field.
fixture.proofEncoded = AbiCoder.defaultAbiCoder().encode(
  ['tuple(bytes32,tuple(bytes32,bool)[])', 'tuple(bytes32,bytes32[])'],
  [
    [p.merkleProof.root, p.merkleProof.siblings.map((s) => [s.hash, s.isLeft])],
    [p.continuityProof.lowerEndpointDigest, p.continuityProof.roots],
  ],
);
// (uint8 txType, bytes[] chunks) — NOT bytes[], despite what the SDK's own docs say.
const [envType, envChunks] = AbiCoder.defaultAbiCoder().decode(['uint8', 'bytes[]'], p.txBytes);
fixture.chunkCount = envChunks.length;
fixture.envelopeTxType = Number(envType);
console.log(`  chunks=${fixture.chunkCount}  envelope txType=${fixture.envelopeTxType}  rpc type=${tx.type}`);

mkdirSync('contracts/test/fixtures', { recursive: true });
writeFileSync('contracts/test/fixtures/sepolia-call.json', JSON.stringify(fixture, null, 2) + '\n');
console.log('wrote contracts/test/fixtures/sepolia-call.json');
