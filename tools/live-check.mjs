// Runs the real contracts against the real precompiles on CC3 Testnet, and asserts every precompile
// assumption the mocked unit tests rely on. No key, no gas, nothing deployed.
//
//   cd contracts && forge build && cd ..
//   node tools/live-check.mjs
//
// Why a fresh proof every run, not a committed fixture: a proof's continuity is validated against
// the precompile's CURRENT attestation/checkpoint state, so a proof captured days ago stops
// verifying as the chain advances. This tool therefore captures a fresh attested Sepolia
// transaction each time — the advertised command has to actually work when a judge runs it.
//
// `eth_call` with no `to` executes creation code and returns whatever the constructor returns, so
// LiveProbe's findings come back as if they were runtime bytecode. Getting a decoded answer at all
// is itself the evidence that precompile refusals are catchable reverts rather than uncatchable
// Frontier ExitErrors — an ExitError would unwind the whole call and return nothing.
import { readFileSync } from 'node:fs';
import { JsonRpcProvider, AbiCoder, concat } from 'ethers';
import { chainInfo, proofProvider } from '@gluwa/usc-sdk';

const CC3_RPC = 'https://rpc.cc3-testnet.creditcoin.network';
const SEPOLIA = 'https://ethereum-sepolia-rpc.publicnode.com';
const PROVER = 'https://prover.cc3-testnet.creditcoin.network';
const CHAIN_KEY = 1; // Sepolia, on CC3 Testnet
const coder = AbiCoder.defaultAbiCoder();

const cc3 = new JsonRpcProvider(CC3_RPC);
const sep = new JsonRpcProvider(SEPOLIA);
const info = new chainInfo.PrecompileChainInfoProvider(cc3);
const builder = new proofProvider.service.ProofBuilder(CHAIN_KEY, PROVER);

const probe = JSON.parse(readFileSync('contracts/out/LiveProbe.sol/LiveProbe.json', 'utf8'));

// A freshly attested Sepolia transaction. Step back a few blocks below the attested tip to stay
// clear of the prover's reorg-protection window, then take the first transaction in a non-empty block.
const attested = Number((await info.getLatestAttestedHeightAndHash(CHAIN_KEY)).height);
let txHash = null;
for (let h = attested - 4; h > attested - 40 && !txHash; h--) {
  const block = await sep.getBlock(h);
  if (block?.transactions?.length) txHash = block.transactions[0];
}
if (!txHash) throw new Error('no attested Sepolia transaction found to prove');

const res = await builder.getProof(txHash);
if (!res.success || !res.data) throw new Error(`proof failed: ${JSON.stringify(res).slice(0, 200)}`);
const p = res.data;

const args = coder.encode(
  ['uint64', 'uint64', 'bytes', 'tuple(bytes32,tuple(bytes32,bool)[])', 'tuple(bytes32,bytes32[])'],
  [
    p.chainKey,
    p.headerNumber,
    p.txBytes,
    [p.merkleProof.root, p.merkleProof.siblings.map((s) => [s.hash, s.isLeft])],
    [p.continuityProof.lowerEndpointDigest, p.continuityProof.roots],
  ],
);

const raw = await cc3.call({ data: concat([probe.bytecode.object, args]) });
const [sepoliaChainId, ethereumChainId, validVerifies, tamperedCaught, tamperedReason, wrongKeyCaught, wrongKeyReason] =
  coder.decode(['uint64', 'uint64', 'bool', 'bool', 'string', 'bool', 'string'], raw);

let failures = 0;
const check = (label, actual, expected) => {
  const ok = String(actual) === String(expected);
  if (!ok) failures++;
  console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${label}`);
  if (!ok) console.log(`          expected ${expected}, got ${actual}`);
};

console.log(`\nAgainst the live CC3 Testnet runtime, proving Sepolia tx ${txHash.slice(0, 18)}… at height ${p.headerNumber}\n`);
check('chainKey 1 resolves to Sepolia (11155111) in THIS environment', sepoliaChainId, 11155111n);
check('chainKey 3 resolves to Ethereum mainnet (1) — the pair that makes hardcoding unsafe', ethereumChainId, 1n);
check("a real proof verifies through the `verify` interface (not the SDK's `verifySingle`)", validVerifies, true);
check('a tampered transaction is REJECTED', tamperedCaught, true);
check('a genuine proof replayed under another chainKey is REJECTED', wrongKeyCaught, true);
// Getting a decoded answer back at all proves the refusals above were catchable reverts, not
// uncatchable Frontier ExitErrors — an ExitError would have returned no data from the eth_call.
check('precompile refusals are catchable reverts (a decoded answer implies it)', raw.length > 2, true);

console.log('\nWhat the precompile actually said:');
console.log(`  tampered transaction  -> ${tamperedReason}`);
console.log(`  wrong chainKey        -> ${wrongKeyReason}`);
console.log(
  failures === 0
    ? '\nAll live checks passed.\n'
    : `\n${failures} live check(s) FAILED — the mocks in Attacks.t.sol no longer describe reality.\n`,
);
process.exit(failures === 0 ? 0 : 1);
