// Runs LiveProbe's constructor on CC3 Testnet via `eth_call` and asserts every precompile
// assumption the mocked unit tests rely on.
//
//   cd contracts && forge build && cd ..
//   node tools/live-check.mjs
//
// No key, no gas, nothing deployed. `eth_call` with no `to` executes creation code and returns
// whatever the constructor returns.
//
// This layer exists because the unit tests mock the prover, and a mock can only ever prove that
// the governor behaves correctly given a verdict. If the real precompile returned `false` instead
// of reverting, or reverted uncatchably, or resolved chainKey 1 to something other than Sepolia,
// every one of those tests would still pass and the deployed contract would be wrong.
import { readFileSync } from 'node:fs';
import { JsonRpcProvider, AbiCoder, concat } from 'ethers';

const CC3_RPC = 'https://rpc.cc3-testnet.creditcoin.network';
const coder = AbiCoder.defaultAbiCoder();

const fx = JSON.parse(readFileSync('contracts/test/fixtures/sepolia-call.json', 'utf8'));
const probe = JSON.parse(readFileSync('contracts/out/LiveProbe.sol/LiveProbe.json', 'utf8'));

const [mp, cp] = coder.decode(
  ['tuple(bytes32,tuple(bytes32,bool)[])', 'tuple(bytes32,bytes32[])'],
  fx.proofEncoded,
);
const args = coder.encode(
  ['uint64', 'uint64', 'bytes', 'tuple(bytes32,tuple(bytes32,bool)[])', 'tuple(bytes32,bytes32[])'],
  [fx.chainKey, fx.height, fx.txBytes, mp, cp],
);

const provider = new JsonRpcProvider(CC3_RPC);
const raw = await provider.call({ data: concat([probe.bytecode.object, args]) });
const [sepoliaChainId, ethereumChainId, validVerifies, tamperedCaught, tamperedReason, wrongKeyCaught, wrongKeyReason] =
  coder.decode(['uint64', 'uint64', 'bool', 'bool', 'string', 'bool', 'string'], raw);

let failures = 0;
const check = (label, actual, expected) => {
  const ok = String(actual) === String(expected);
  if (!ok) failures++;
  console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${label}`);
  if (!ok) console.log(`          expected ${expected}, got ${actual}`);
};

console.log(`\nAgainst the live CC3 Testnet runtime, proving Sepolia tx ${fx.txHash.slice(0, 18)}…\n`);
check('chainKey 1 resolves to Sepolia (11155111) in THIS environment', sepoliaChainId, 11155111n);
check('chainKey 3 resolves to Ethereum mainnet (1) — the pair that makes hardcoding unsafe', ethereumChainId, 1n);
check('a real proof verifies through the `verify` interface (not the SDK\'s `verifySingle`)', validVerifies, true);
check('a tampered transaction is REJECTED', tamperedCaught, true);
check('a genuine proof replayed under another chainKey is REJECTED', wrongKeyCaught, true);

// Getting a decoded answer back at all is the evidence for this one: an uncatchable Frontier
// ExitError would have unwound the constructor and returned nothing.
check('precompile refusals are catchable, so AttestedGovernor\'s try/catch is sound', true, true);

console.log('\nWhat the precompile actually said:');
console.log(`  tampered transaction  -> ${tamperedReason}`);
console.log(`  wrong chainKey        -> ${wrongKeyReason}`);
console.log(
  failures === 0
    ? '\nAll live checks passed.\n'
    : `\n${failures} live check(s) FAILED — the mocks in Attacks.t.sol no longer describe reality.\n`,
);
process.exit(failures === 0 ? 0 : 1);
