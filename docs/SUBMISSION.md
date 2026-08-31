# BUIDL CTC 2026 Fall — submission copy

Paste-ready, aligned field-by-field to the official Submission Requirements. Fill the two bracketed
items (demo video URL, and the loan-book address once deployed) at the end.

---

## Project name

Attestor

## Project logo

`web/logo` — (optional; a simple wordmark is fine, or reuse the evidence page's monospace title)

## Project sector

DeFi / RWA — verifiable cross-chain credit history

## Project description

Attestor is a cross-chain loan repayment history you cannot lie to.

A borrower repays a loan on Ethereum, where the stablecoin lives. An autonomous off-chain agent
watches for the repayment and posts it to a credit history on Creditcoin — but the record is written
**only** if a USC proof shows the repayment really happened. The agent proposes; the on-chain loan
book disposes. Neither the agent nor its operator can write a false entry into anyone's history.

**The repayments are not ours.** `AaveLoanBook` reads the **Aave V3 Pool on Sepolia** — a lending
protocol we did not write, used by people we have never met, whose `Repay` events we cannot cause,
populate or alter. This matters more than any check in the contract: a history you issue to yourself
proves only that you can issue history to yourself. `0x2C56b94f8b27E116C5686B41473bC038a6d86A88`
repaid 25 USDC to Aave, and that fact is now a credit record on Creditcoin that nobody — including
us — can forge. A second book proving repayments to a source contract of our own is kept alongside
as the control; the contrast is the argument.

That is Creditcoin's own reason to exist, made literal: the money moves where the money lives, and the
record of it lives where a record can be trusted. It is deliberately built around what Attestcoin
does **not** prove — inclusion is not success — so the book re-derives and re-checks every property
of the repayment on-chain before it counts.

## USC Integration Summary

**USC — Universal Smart Contracts — is the substrate this project is built out of, not a library it
calls.** Concretely, the parts of USC in use are the **Attestcoin Protocol** and its two runtime
precompiles, reached from Solidity directly and from TypeScript through `@gluwa/usc-sdk` 0.18.0:

| USC surface | Where | What it does here |
|---|---|---|
| **BlockProver** precompile `0x…0FD2` | `AaveLoanBook.post`, `AttestedLoanBook.post` | Verifies that a source-chain transaction was included in a confirmed block. Called in-contract, first, before any state is touched. |
| **ChainInfo** precompile `0x…0fD3` | same, plus `LiveProbe` | `get_chain_by_key` resolves a `chainKey` to a real `chainId`; `get_latest_attestation_height_and_hash` supplies the only clock the system has. |
| **`@gluwa/usc-sdk`** `proofProvider`, `chainInfo` | `agent/src/attestcoin.ts`, `spike/*.mjs`, `tools/post-aave.mjs` | Builds the merkle + continuity proof against the hosted Proof Builder and waits on attestation. |

Remove USC and there is no product left. The loan book on Creditcoin accepts no trusted input of its
own — no owner-submitted number, no oracle, no signed report. It learns that a repayment happened by
verifying a USC proof of the source transaction, and every write to a credit history is downstream of
that one call. A borrower's undercollateralised credit limit is then computed *entirely* from that
attested record.

**Where the work went is the gap between what USC proves and what a lender needs.** Attestcoin proves
that a transaction was *included in a confirmed block*. That is all it proves. It does not prove the
transaction succeeded, that it touched the contract you care about, or that the person claiming it
sent it. A consumer that treats "attested" as "happened the way I wanted" is exploitable, so the book
re-derives every property on-chain and refuses anything that does not check out:

- `status == 1` — a reverted repayment is still in the block and still merkle-provable
- the source `chainId`, resolved through ChainInfo, never a raw `chainKey` (which is
  environment-scoped: `chainKey 1` is Sepolia on CC3 Testnet and Ethereum on Mainnet, so a contract
  hardcoding it changes which chain it trusts on promotion, silently)
- the emitting contract, and the event signature, as a pair
- the borrower, read from the event rather than from whoever submitted the proof
- freshness, measured in **source blocks** — because no USC attestation carries a timestamp anywhere
- replay, consumed per **log** rather than per transaction

Seven undocumented protocol facts we found and reported while building are written up in
[`docs/ATTESTCOIN-INTEGRATION.md`](ATTESTCOIN-INTEGRATION.md) — among them that the precompile
*reverts* rather than returning `false`, so `if (!verify(...))` is dead code; and that the proof
envelope is `(uint8 txType, bytes[] chunks)` rather than the `bytes[]` the SDK's own documentation
specifies, which means a consumer written from the docs cannot decode a single real transaction.

## GitHub repository

https://github.com/RichardReki/attestor (public; README + full history inside the contest window)

## Deck / Whitepaper (PDF)

`docs/deck.pdf` in the repo — [upload to the submission form or link the raw GitHub URL]

## Prototype demo video

[PASTE YOUTUBE/LOOM URL — script ready at docs/demo-script.md, recordable now]

## Team information

- **Name:** [your name]
- **Email:** richardnorgay@gmail.com
- **Role:** Solo builder — contracts, agent, tests, deck, demo
- **Short bio:** [1–2 lines; prior: RotorEdge (BNB Hack 2nd place), RotorVault (Flare)]
- **Country of residence / citizenship:** [fill in]

## Team size

1

## Project requirements — self-check

- **Original work created during the hackathon:** yes — first commit `84c511a` is inside the
  2026-08-13 → 09-14 window; prior work (RotorVault, on Flare) is named as the pattern's origin and
  nothing from it is reused (different chain, protocol, code).
- **Deployed on a testnet:** yes. `AaveLoanBook` on Creditcoin CC3 Testnet:
  `0xc3762daB9AB246771a91B764d0E45f03619A61ea`, reading the **Aave V3 Pool**
  `0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951` on Ethereum Sepolia — a contract we did not deploy.
  A real third-party repayment of 25 USDC (Sepolia tx `0x2f8901c4…`, block 11,605,409) was proven
  and posted (CC3 tx `0x7fb71b18…`, 221,790 gas); the book now reads `totalRepaid = 25000000` for
  that borrower, and a `CreditLine` bound to it (`0xA595C95964efaec78D85Ad18D38a05004440Bbb2`) reports a **credit limit of 25000000**
  for them — against **0** for an address with no Aave history. The control path is also live: `MockUSD` `0xCFd5E8e6…` + `LoanRepayment`
  `0x08F8b91A…` on Sepolia, `AttestedLoanBook` `0xe31906a2A7162b865b672a3a51B75813564db5e9` and a
  `CreditLine` consumer `0xC45f8594579191b5125B24f721cA4e2f93811A8c` on CC3, where a proven
  repayment funded a real undercollateralised loan (tx `0xb62ffcff…`). Nothing is mocked on either
  path.
- **USC / Attestcoin as a core feature:** yes — every write to the credit history is gated on a
  BlockProver-precompile verification, and the source chain is resolved through the ChainInfo
  precompile rather than trusted as a raw `chainKey`. The pipeline is verified end-to-end against
  the live precompiles (`node tools/live-check.mjs`, `spike/aave-proof.mjs`), and **51 contract
  tests + 20 agent tests pass**, 28 of the contract tests rejecting a forged or invalid input.

## Encouraged extras

- **Network:** Ethereum Sepolia (source) → Creditcoin CC3 Testnet (target, chainId 102031).
- **What is real vs pending, stated plainly:** the security core is complete and the proof pipeline
  is verified end-to-end against the live precompiles. A repayment made by a stranger to Aave V3 has
  been proven and recorded (Sepolia `0x2f8901c4…` → CC3 `0x7fb71b18…`, book reads totalRepaid
  25000000). `spike/aave-proof.mjs` reproduces the whole thing keylessly and picks a *fresh*
  repayment each run, so the demonstration cannot go stale. Not yet done: the agent watches one
  repayment at a time rather than running continuously against Aave, and the Aave-sourced credit
  limit is demonstrated as a read rather than a drawn loan — the borrower is a stranger, so only
  they can draw it, which is the point rather than a gap. Nothing in the flow is mocked.
- **Ecosystem contribution:** seven undocumented Attestcoin behaviours found and documented, two of
  which make a consumer written from the current docs fail outright — reported for the team's benefit.
