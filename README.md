# Attestor — a cross-chain loan book you cannot lie to

An autonomous agent watches loan repayments happen on Ethereum and posts them to a credit history on
Creditcoin — but it **cannot fabricate a repayment that did not happen**, because the on-chain book
re-derives every one from an Attestcoin proof of the source transaction and refuses anything that
does not check out.

That is Creditcoin's own thesis made literal: the money moves where the money lives (Ethereum), and
the *record of it* lives where a record can be trusted (Creditcoin). The agent proposes; the chain
disposes; neither the agent nor we can write a false entry into someone's history.

Built for **BUIDL CTC 2026 Fall** (2026-08-13 → 2026-09-06). Every line of this repository was
written inside the contest window; see `git log` for the first commit. Prior work of ours
(RotorVault, on Flare) is named here as the origin of the *pattern* — an agent proposes, an on-chain
rule disposes — and nothing from it is reused: different chain, different protocol, different code.

**Live evidence page:** https://richardreki.github.io/attestor/ — the attestation gap and the attack/refusal table, read live from both chains in your browser.

## Status

The security core is done and the proof pipeline is verified end to end against the live
precompiles. 48 tests pass — 28 on the contracts, 20 on the agent — and six claims about the
precompiles are re-checked against the live CC3 runtime on every run (via `tools/live-check.mjs`),
because mocked tests cannot make claims about a precompile they are mocking. An earlier build of the
source contract is already live on Sepolia (it demonstrated the pipeline; see git history); the loan
contracts here deploy to Sepolia in one command, and the book on Creditcoin is waiting on CC3
testnet funds for its first posting.

Reproduce the whole proof pipeline yourself, with no key and no gas:

```bash
cd spike && npm install && node spike.mjs      # Sepolia tx -> proof -> verified on CC3
cd contracts && forge test                     # 28 forge tests; 22 of them reject a forged or invalid input
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
| source contract address | otherwise any contract's call is posted as a repayment to this lender |
| function selector + decoded args | otherwise a different call on the right contract passes |
| `msg.sender` of the source tx | the credit belongs to the borrower who paid, not the relayer |
| freshness / deadline | an attested repayment is provable forever; the right to post it should not be |
| tx-hash consumption | otherwise one repayment is posted again and again, inflating the history |

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
| `MockUSD` (Sepolia) | [`0xCFd5E8e697A1956F063B9Bb71E9E33fd78F3d0ef`](https://sepolia.etherscan.io/address/0xCFd5E8e697A1956F063B9Bb71E9E33fd78F3d0ef) |
| `LoanRepayment` (Sepolia) | [`0x08F8b91A9d447C309F1788002BF51BF0BEE69021`](https://sepolia.etherscan.io/address/0x08F8b91A9d447C309F1788002BF51BF0BEE69021) — lender `0x…dEaD`, distinct from the borrower |
| `AttestedLoanBook` (CC3 Testnet) | [`0xe31906a2A7162b865b672a3a51B75813564db5e9`](https://creditcoin-testnet.blockscout.com/address/0xe31906a2A7162b865b672a3a51B75813564db5e9) |

**Demonstrated source fact** (the exact transaction the agent will prove once the book is funded):
a real repayment of 250 mUSD, borrower → lender, `status 1`, emitting
`Repaid(borrower, loanId 7, 250000000, deadline)` —
[`0x00a39800…`](https://sepolia.etherscan.io/tx/0x00a39800110d523b1ec737139b37dc58784fe46e59977ca7d3175324da13267f).
The tokens actually moved (lender balance went to 250 mUSD), so this is an economic fact, not a log line.

Deployed from `0x66F9Bd73c4847584f158c8D19EEd179F21adC169`. An earlier generic build of the source
contract (`0xe31906a2…`) proved the pipeline before the product settled on the loan model above.

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
