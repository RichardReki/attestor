# Attestor — a cross-chain loan book you cannot lie to

An autonomous agent watches loan repayments happen on Ethereum and posts them to a credit history on
Creditcoin — but it **cannot fabricate a repayment that did not happen**, because the on-chain book
re-derives every one from a **USC (Universal Smart Contracts)** proof of the source transaction,
through the Attestcoin BlockProver precompile, and refuses anything that does not check out.

That is Creditcoin's own thesis made literal: the money moves where the money lives (Ethereum), and
the *record of it* lives where a record can be trusted (Creditcoin). The agent proposes; the chain
disposes; neither the agent nor we can write a false entry into someone's history.

**The repayments are not ours.** `AaveLoanBook` reads the **Aave V3 Pool on Sepolia**
(`0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951`) — a lending protocol we did not write, used by people
we have never met, whose `Repay` events we cannot cause, populate or alter. This matters more than
any check in the contract. A history you issue to yourself proves only that you can issue history to
yourself; the proof machinery was never the weak link, the *source fact* was. `AttestedLoanBook`
proves repayments to a source contract of our own and is kept alongside deliberately, as the control:
same seven checks, same precompile, evidence worth far less. The contrast is the argument.

And the history is not write-only. `CreditLine` reads it and lends against it: a borrower's
undercollateralised credit limit is set *entirely* by their attested, cross-chain repayment record —
no collateral, no off-chain score. Because the record cannot be forged, neither can the credit. A
repayment that happened on Ethereum becomes the sole determinant of credit on Creditcoin — proven,
drawn, and closed on-chain, both sides.

Built for **BUIDL CTC 2026 Fall** (2026-08-13 → 2026-09-14). Every line of this repository was
written inside the contest window; see `git log` for the first commit. Prior work of ours
(RotorVault, on Flare) is named here as the origin of the *pattern* — an agent proposes, an on-chain
rule disposes — and nothing from it is reused: different chain, different protocol, different code.

**Live evidence page:** https://richardreki.github.io/attestor/ — the attestation gap and the attack/refusal table, read live from both chains in your browser.

## Reading a protocol you did not write

Pointing the same proof machinery at somebody else's contract changes three things, and each was
settled against the live chain rather than assumed:

1. **The fact lives in a log, not in calldata.** `Pool.repay(asset, amount, rateMode, onBehalfOf)`
   accepts `amount = type(uint256).max` to mean "all of it", so the calldata does not say how much
   was repaid — only the emitted `Repay` event does. Reading function arguments works when you wrote
   the source function and put the number there yourself. It does not generalise.
2. **Replay is keyed per LOG, not per transaction.** One transaction can repay several debts; a
   routed repayment on this pool was observed at log index 500. A book keyed on the transaction
   records the first repayment in it and silently discards the rest.
3. **Freshness is measured in source blocks.** A USC attestation carries no timestamp anywhere, so
   age is `latestAttestedHeight - provenHeight`. Any figure quoted in seconds is either the
   Creditcoin block time of the *posting* transaction — which says when the proof was submitted, not
   when the repayment happened — or invented.

And one that is a judgement call rather than a mechanic: **Aave lets anyone repay anyone's debt**, so
the event's `user` and `repayer` are different questions. Only a self-repayment earns credit here. A
debt someone else paid is evidence about *them*, and crediting it would let one funded account
manufacture standing for any address it likes. The third-party case is still recorded, under
`repaidByOthers`, because discarding a proven fact to keep a number tidy is its own dishonesty. One
of the 81 repayments in the sampled window is genuinely third-party — it is the test fixture.

## Status

**The full loop is live.** A real repayment has been proven and posted to a loan book on Creditcoin,
which now records the borrower's credit history on-chain — end to end, nothing mocked (transactions
below). **71 tests pass — 51 on the contracts, 20 on the agent** — and six claims about the
precompiles are re-checked against the live CC3 runtime on every run (via `tools/live-check.mjs`),
because mocked tests cannot make claims about a precompile they are mocking.

Reproduce the whole proof pipeline yourself, with no key and no gas:

```bash
cd spike && npm install
node spike.mjs                 # any Sepolia tx -> proof -> verified on CC3, plus two negative controls
node aave-proof.mjs            # a REAL Aave V3 repayment by a stranger, proven, with the Repay event
                               # recovered from the attested receipt and matched against Sepolia's RPC
cd ../contracts && forge test  # 51 forge tests; 28 of them reject a forged or invalid input
node ../tools/live-check.mjs   # the precompile assumptions, against the real chain
```

`aave-proof.mjs` is the one to run if you only run one. It is keyless, takes about twenty seconds,
and answers the only question that matters about this design: whether a repayment made by somebody
we have never met, to a protocol we did not write, survives the trip intact.

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
| **`AaveLoanBook`** (CC3 Testnet) | [`0xc3762daB9AB246771a91B764d0E45f03619A61ea`](https://creditcoin-testnet.blockscout.com/address/0xc3762daB9AB246771a91B764d0E45f03619A61ea) — **reads Aave V3, a protocol we did not write** |
| Aave V3 Pool (Sepolia) | [`0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951`](https://sepolia.etherscan.io/address/0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951) — not ours, not deployed by us |
| `CreditLine` (CC3 Testnet) | [`0xC45f8594579191b5125B24f721cA4e2f93811A8c`](https://creditcoin-testnet.blockscout.com/address/0xC45f8594579191b5125B24f721cA4e2f93811A8c) — reads the history, lends against it |
| `AttestedLoanBook` (CC3 Testnet) | [`0xe31906a2A7162b865b672a3a51B75813564db5e9`](https://creditcoin-testnet.blockscout.com/address/0xe31906a2A7162b865b672a3a51B75813564db5e9) — the control: same checks, source we wrote |
| `MockUSD` (Sepolia) | [`0xCFd5E8e697A1956F063B9Bb71E9E33fd78F3d0ef`](https://sepolia.etherscan.io/address/0xCFd5E8e697A1956F063B9Bb71E9E33fd78F3d0ef) — the control's token |
| `LoanRepayment` (Sepolia) | [`0x08F8b91A9d447C309F1788002BF51BF0BEE69021`](https://sepolia.etherscan.io/address/0x08F8b91A9d447C309F1788002BF51BF0BEE69021) — the control's source contract |

### A stranger's repayment, now credit history on Creditcoin

This is the evidence the project stands on. Nobody involved is us.

1. **`0x2C56b94f8b27E116C5686B41473bC038a6d86A88` repaid 25 USDC to Aave V3 on Sepolia** —
   [`0x2f8901c4…`](https://sepolia.etherscan.io/tx/0x2f8901c49c3702d83bd18ed0012008da025d5275009b0190c44c76badb91f7a8),
   block 11,605,409. We did not send it, did not fund it, and found out it existed by reading the
   chain. That account has its own history on Sepolia and no connection to any address in this
   repository.
2. **The proof was posted to `AaveLoanBook` on Creditcoin** —
   [`0x7fb71b18…`](https://creditcoin-testnet.blockscout.com/tx/0x7fb71b18453c14538b6e7cd8553a41e184efec1c299bf3ca61a943a0fbe037e4),
   block 5,406,133, 221,790 gas. The book now reads `totalRepaid = 25000000`,
   `repaymentCount = 1`, `repaidByOthers = 0` for that borrower — read it yourself, it is a public
   view call.

Run it again and it will pick a *different* repayment, because people keep making them:

```bash
AAVE_BOOK=0xc3762daB9AB246771a91B764d0E45f03619A61ea node tools/post-aave.mjs --dry
```

A pinned fixture would eventually go stale and quietly stop meaning anything. Fetching a fresh
repayment on every run is the demonstration.

### The control, for comparison

The same machinery against a source contract of our own — which is why the section above matters:

1. Borrower repays 250 mUSD on Sepolia (real transfer, `status 1`, emits `Repaid`) —
   [`0x49592b0c…`](https://sepolia.etherscan.io/tx/0x49592b0cf86b489ab5e456ccf470ae1b444521fc982e04f46cf85ad27ea442d4).
2. The agent proves it and posts it to `AttestedLoanBook` —
   [`0x0f3d4ca0…`](https://creditcoin-testnet.blockscout.com/tx/0x0f3d4ca04af2ce2eac4004a0fddb2f8d26b751ef27c08e04aacf3e2f8ee052f4).
3. `CreditLine` reads that attested history and the borrower draws a **real 125 mUSD
   undercollateralised loan** against it —
   [`0xb62ffcff…`](https://creditcoin-testnet.blockscout.com/tx/0xb62ffcffdb485e60a282f95e06bc007fe71064e55c6caa8a8d91d92fa55b4b77).
   A borrower with no attested history has a limit of zero and cannot draw a cent.

Every check passes on both paths. Only one of them is evidence about anybody's creditworthiness,
and it is not this one — we wrote the borrower, the token and the contract it paid. Keeping the
weaker demonstration visible next to the stronger one is the honest way to show what changed.

All deployed from `0x66F9Bd73c4847584f158c8D19EEd179F21adC169`. (The CC3 book and an earlier,
now-superseded Sepolia contract share the address string `0xe31906a2…` only because both were the
first deployment from this account on their respective chains — they are different contracts on
different chains.)

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
