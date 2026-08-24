# Attestcoin integration

How Attestor uses the Attestcoin Protocol, why it is in the product's main flow rather than beside
it, and seven things we learned about the protocol that its documentation does not say. Everything
below is reproducible from this repository with no key and no gas — the commands are in each section.

---

## 1. What the product is, in one sentence

A borrower repays a loan on Ethereum; an unforgeable record of that repayment is written to a credit
history on Creditcoin — and the record can only be written if an Attestcoin proof shows the
repayment really happened.

That is Creditcoin's own reason to exist, made literal: the money moves where the money lives
(Ethereum, where the stablecoin is), and the *record of it* lives where a record can be trusted
(Creditcoin). An off-chain agent proposes each posting; the on-chain book disposes. Neither the
agent nor we can write a false entry into someone's history.

And the history is *used*: `CreditLine` reads it and extends undercollateralised credit sized purely
by the attested record — no collateral, no off-chain score. Because the record cannot be forged,
neither can the credit. Live on CC3 at `0xC45f8594579191b5125B24f721cA4e2f93811A8c`; a borrower with a proven 250 mUSD
repayment drew a real 125 mUSD loan against it (tx `0xb62ffcff…`).

## 2. Attestcoin is the main flow, not a feature beside it

Remove Attestcoin and there is no product. The loan book on Creditcoin holds **no** trusted input of
its own — it learns that a repayment happened *only* by verifying an Attestcoin proof of the source
transaction. Concretely, `AttestedLoanBook.post()` does nothing until:

```
CC3 BlockProver precompile (0x…0FD2) . verify(chainKey, height, txBytes, merkleProof, continuityProof)
```

returns without reverting. Every write to the credit history is downstream of that one call.

```
 Ethereum Sepolia                    off-chain agent                 Creditcoin CC3 Testnet
 ────────────────                    ───────────────                 ──────────────────────
 borrower calls repay()   ── Repaid ─▶ watch, judge (risk gate)
   real USDC transferFrom              wait ~8 min for attestation
   emits Repaid                        hosted prover → proof
                                       post(proof) ───────────────▶  AttestedLoanBook.post()
                                                                       ChainInfo 0x…0FD3 resolve chain
                                                                       BlockProver 0x…0FD2 verify  ◀── the load-bearing call
                                                                       re-derive + 7 checks
                                                                       write totalRepaid / repaidOnLoan
```

## 3. Attestcoin proves *less* than it first appears — the seven checks

A single sentence governs the whole security model: **Attestcoin proves a transaction was included in
a confirmed block on the source chain, and nothing more.** In particular it does not prove the
transaction *succeeded*. A consumer that treats "attested" as "happened the way I wanted" is
exploitable. `AttestedLoanBook` re-derives the repayment from the proven transaction and enforces,
on-chain, every property the proof does not:

| # | Check | If skipped |
| --- | --- | --- |
| 1 | `status == 1` | a repayment whose transfer reverted is still included, and would post as if it paid |
| 2 | `chainKey` resolves to the expected `chainId` | a valid proof from the wrong chain is accepted (see finding 3) |
| 3 | source contract == the bound `LoanRepayment` | any contract's call is posted as a repayment to this lender |
| 4 | selector == `repay` | a different function on the right contract passes as a repayment |
| 5 | decoded `borrower` == the transaction's real sender | the credit is assigned to whoever relays the proof |
| 6 | freshness (`deadline`, and a `maxAge` ceiling) | an attested repayment is provable forever, so posting authority never expires |
| 7 | tx-hash not already consumed | one repayment is posted again and again, inflating the history |

Plus two economic guards at the source, because a credit history is only worth anything if an entry
means real money moved: a **zero-amount** repayment (clears an ERC-20 transfer while moving nothing)
and a **self-payment** (borrower == lender, nets to zero) are both refused — on both chains.

Each of these is a test. `cd contracts && forge test` runs 28 of them; 22 assert a forged or invalid
input is rejected. The suite is adversarial by construction: `test_creditingSomeoneElsesHistory…`,
`test_repaymentToAnImpostorContract…`, `test_provenButRevertedRepayment…`, `test_replayingTheSameProof…`,
and so on.

## 4. Seven things the documentation does not say

We found these by building against the live protocol, not by reading about it. Two of them make a
consumer written from the documentation fail outright; one is a bug we shipped ourselves and caught
only by checking against the live chain. They are our ecosystem contribution as much as the product
is.

1. **The precompile reverts on a bad proof; it does not return `false`.** The SDK types
   `verifySingle(): Promise<boolean>` and documents "false otherwise". A consumer's `if (!verified)`
   branch is therefore dead code — every failure path must be handled as a revert. This shaped the
   `try/catch` in `post()`.
2. **End-to-end latency is ~8 minutes and is a product constraint.** A source fact is not provable
   until attested (~39 Sepolia blocks behind head), and the prover refuses anything inside a 32-block
   reorg-protection window — a number that appears only in the text of a `BlockNotOnSourceChain`
   error, in no documentation. We surface it (the agent states the lag; the evidence page draws it)
   rather than implying real-time.
3. **`chainKey` is environment-scoped, not a global chain id.** Key 1 is Sepolia on CC3 Testnet and
   Ethereum mainnet on CC3 Mainnet. A contract that hardcodes `chainKey == 1` and is promoted from
   testnet to mainnet silently changes which chain it trusts. We bind to `chainId`, resolved through
   the ChainInfo precompile, and treat `chainKey` as untrusted input.
4. **SDK and chain names differ, in both directions.** The BlockProver function is `verify`
   on-chain, not the SDK's `verifySingle`; ChainInfo is snake_case on-chain (`get_chain_by_key`),
   camelCase in the SDK. A Solidity interface transcribed from the SDK calls a selector that does not
   exist.
5. **The proof envelope is `(uint8 txType, bytes[] chunks)`, not `bytes[]` — and the SDK documents
   the wrong one.** Its `encoding/abi/v1` says "To decode it: Type: `bytes[]`", while the `abiEncode`
   in that same file encodes `['uint8', 'bytes[]']`. A consumer written from the docs cannot decode a
   single real transaction. Inside, the receipt is the *last* chunk and the chunk count varies by
   transaction type (3 for legacy/1559, 4 for blob) — reading `chunks[2]` misreads a blob tx.
6. **The precompiles cannot be fork-tested, and the failure is silent.** They are Substrate runtime
   code, so `eth_getCode` at `0x…0FD2` returns `0x`; a forked node has nothing there, and a `CALL`
   to a codeless address *succeeds* and returns no data — a fork test of "a forgery is rejected"
   passes the wrong assertion. Our `LiveProbe` runs the real contracts against the real precompiles
   as `eth_call` creation code instead (no key, no gas).
7. **`get_chain_by_key` returns one tuple `(Chain, bool)`, not two values.** `Chain` holds a `bytes`,
   so the single-tuple form carries an extra level of indirection. We had the interface wrong; every
   mocked test passed because the mock encoded it the same wrong way, and it reverted every time on
   the real chain. This is why our test suite is backed by a live-check layer (finding 6) rather than
   trusted on its own.

## 5. What is verifiable right now

Reproduce the whole proof pipeline with no key and no gas:

```bash
cd spike && npm install && node spike.mjs   # a fresh Sepolia tx → hosted prover → verify() on CC3 → true
cd contracts && forge test                  # 28 tests; 22 reject a forged or invalid input
node tools/live-check.mjs                    # re-checks 6 precompile behaviours against the live chain
```

On-chain, deployed from `0x66F9Bd73c4847584f158c8D19EEd179F21adC169`:

| What | Where |
| --- | --- |
| `MockUSD` (Sepolia) | `0xCFd5E8e697A1956F063B9Bb71E9E33fd78F3d0ef` |
| `LoanRepayment` (Sepolia) | `0x08F8b91A9d447C309F1788002BF51BF0BEE69021` (lender `0x…dEaD`) |
| **A real repayment** — 250 mUSD moved, `status 1`, `Repaid` emitted | tx `0x49592b0cf86b489ab5e456ccf470ae1b444521fc982e04f46cf85ad27ea442d4` |
| BlockProver precompile | `0x0000000000000000000000000000000000000FD2` |
| ChainInfo precompile | `0x0000000000000000000000000000000000000fD3` |

## 6. Honest status

The full loop is live. `AttestedLoanBook` is deployed on CC3 Testnet
(`0xe31906a2A7162b865b672a3a51B75813564db5e9`), and a real Sepolia repayment
([`0x49592b0c…`](https://sepolia.etherscan.io/tx/0x49592b0cf86b489ab5e456ccf470ae1b444521fc982e04f46cf85ad27ea442d4)) has been proven and posted to it
([`0x0f3d4ca0…`](https://creditcoin-testnet.blockscout.com/tx/0x0f3d4ca04af2ce2eac4004a0fddb2f8d26b751ef27c08e04aacf3e2f8ee052f4)), so the book now reads
`totalRepaid = 250000000` and `repaymentCount = 1` for the borrower. Nothing in the flow is mocked;
reproduce it with `node tools/post-once.mjs`.
