# Attested Risk Governor

An autonomous risk agent that can propose cross-chain actions, but **cannot fabricate the
source-chain facts it acts on**.

Built for **BUIDL CTC 2026 Fall** (2026-08-13 → 2026-09-06). Every line of this repository was
written inside the contest window; see `git log` for the first commit. Prior work of ours
(RotorVault, on Flare) is named here as the origin of the *pattern* — an agent proposes, an on-chain
rule disposes — and nothing from it is reused: different chain, different protocol, different code.

## Status

The source half is deployed and the security core is done. 41 tests pass — 21 on the contracts,
20 on the agent — and six claims about the precompiles are re-checked against the live CC3 runtime
on every run (via `tools/live-check.mjs`), because mocked tests cannot make claims about a precompile
they are mocking. What remains is the first end-to-end execution, which is waiting on CC3 testnet
funding — the governor is not yet deployed.

Reproduce the whole proof pipeline yourself, with no key and no gas:

```bash
cd spike && npm install && node spike.mjs      # Sepolia tx -> proof -> verified on CC3
cd contracts && forge test                     # 21 forge tests; the attack suite rejects 13 forgeries
node tools/live-check.mjs                      # the precompile assumptions, against the real chain
```

## What Attestcoin actually guarantees — and what it does not

Attestcoin proves a transaction was **included in a confirmed block on the source chain**. That is
all it proves. In particular it does **not** prove the transaction *succeeded*. A consumer contract
that treats "attested" as "happened the way I wanted" is exploitable. Ours checks, on-chain:

| Check | Why |
| --- | --- |
| `status == 0x1` | inclusion ≠ success; a reverted tx is still includable |
| `chainKey` | see the environment-scoping trap below |
| source contract address | otherwise any contract's event can impersonate ours |
| function selector + decoded args | otherwise a different call on the right contract passes |
| `msg.sender` of the source tx | authorisation belongs to the source actor, not the relayer |
| freshness / deadline | attested facts stay provable forever; authority should not |
| tx-hash consumption | otherwise one authorisation replays without limit |

## Seven things we found that the documentation does not say

Recorded as we hit them, each one load-bearing. Two of them make a consumer written from the
documentation fail outright, and one of those two is a bug we shipped ourselves before the live
checks caught it — see 7.

**1. The precompile reverts; it does not return `false`.** `@gluwa/usc-sdk` types
`verifySingle(): Promise<boolean>` and documents "resolving to true if verification succeeds,
**false otherwise**". Empirically, a bad proof reverts:

```
tampered tx bytes -> execution reverted: "Merkle proof validation failed"
wrong chainKey    -> execution reverted: "Continuity proof does not match attestation or checkpoint"
```

So in a consumer contract an `if (!verified) { ... }` branch is dead code. Every failure path has to
be handled as a revert, which changes how a contract must be structured — and is the difference
between a rejection your users can read and an opaque one.

**2. End-to-end latency is about 8 minutes, and it is a product constraint, not an implementation
detail.** A source fact is not provable until it is attested, which we measured at ~39 Sepolia
blocks behind the head (~8 minutes). The last **32 of those** are a reorg-protection window the
prover enforces explicitly — a number that appears only in the text of its `BlockNotOnSourceChain`
error, in no documentation. The figures are not additive: the reorg window is the tail of the lag,
not extra on top of it. An agent built on this cannot act on fresher source facts than that, so we
state the bound rather than implying real-time.

**3. `chainKey` is environment-scoped, not a global chain id.**

| Environment | chainKey 1 | chainKey 3 |
| --- | --- | --- |
| CC3 Testnet | Ethereum Sepolia (`chainId 11155111`) | Ethereum mainnet (`chainId 1`) |
| CC3 Mainnet | Ethereum mainnet (`chainId 1`) | — |

A contract that hardcodes `chainKey == 1` and is promoted from testnet to mainnet **silently changes
which chain it trusts**, with no code change and no error. Bind to `chainId` via the ChainInfo
precompile (`0x…0FD3`), not to `chainKey`. This is the sharpest attack in our demo.

**4. The names differ between the SDK and the chain, in both directions.** The BlockProver function
is `verify` on-chain, not the SDK's `verifySingle` — a Solidity interface transcribed from the SDK
produces a selector the precompile does not have, and fails for a reason with nothing to do with
your proof. ChainInfo goes the other way: on-chain it is snake_case (`get_chain_by_key`,
`is_height_attested`), camelCase only in the SDK.

**5. The proof envelope is `(uint8 txType, bytes[] chunks)`, not `bytes[]` — and the SDK documents
the wrong one.** `encoding/abi/v1` says, verbatim, "To decode it: Type: `bytes[]`", while the
`abiEncode` function in that same file encodes `['uint8', 'bytes[]']`. A consumer written from the
documentation cannot decode a single real transaction. We found it only by dumping the bytes a live
proof actually contained, and `test_envelopeIsNotBareBytesArray` now pins it.

Inside the envelope, the receipt is the **last** chunk and the chunk count varies by transaction
type — three for legacy/access-list/EIP-1559, four for blob. Reading the receipt as `chunks[2]`
works on every transaction you are likely to test with and misreads a blob transaction, so
`AttestedTx` indexes from the end.

**6. The precompiles cannot be fork-tested, and the failure is silent.** They are Substrate runtime
code, so `eth_getCode` at `0x0FD2` returns `0x`. A forked node therefore has nothing at that
address, and a `CALL` to a codeless address *succeeds* and returns no data — so a fork test of
"a tampered proof is rejected" does not fail loudly, it passes the wrong assertion. We built
`LiveProbe` instead: it does its work in a constructor and returns the findings as runtime
bytecode, so `eth_call` with no `to` runs the real contracts against the real precompiles with no
key, no gas and nothing deployed.

**7. `get_chain_by_key` returns one tuple containing `(Chain, bool)`, not two return values.** The
ABI is `get_chain_by_key(uint64) -> (((uint64,uint64,bytes,uint8),bool))` — note the doubled
parentheses. `Chain` holds a `bytes`, so it is dynamic, and the single-tuple form carries an extra
level of indirection. We had it wrong. Every mocked test passed, because the mock encoded it the
same wrong way; on the real chain it reverted every time. This is the concrete reason the live
checks exist, and it is why we do not treat a green unit suite as evidence about a precompile.

## Deployed

| | |
| --- | --- |
| `SourceAuthorization` (Sepolia) | [`0xe31906a2A7162b865b672a3a51B75813564db5e9`](https://sepolia.etherscan.io/address/0xe31906a2A7162b865b672a3a51B75813564db5e9) |
| `AttestedGovernor` (CC3 Testnet) | not yet deployed |

## Environment

| | |
| --- | --- |
| Source chain | Ethereum Sepolia — `chainKey 1`, `chainId 11155111` |
| Target chain | Creditcoin **CC3 Testnet**, `chainId 102031`, RPC `https://rpc.cc3-testnet.creditcoin.network` |
| Hosted prover | `https://prover.cc3-testnet.creditcoin.network` (`/api/v1/proof-by-tx/{chainKey}/{txHash}`) |
| BlockProver precompile | `0x0000000000000000000000000000000000000FD2` |
| ChainInfo precompile | `0x0000000000000000000000000000000000000fd3` |
| SDK | `@gluwa/usc-sdk` 0.18.0 |

Neither precompile returns bytecode from `eth_getCode` — they are native, and must be called.
