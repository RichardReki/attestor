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
**only** if an Attestcoin proof shows the repayment really happened. The agent proposes; the on-chain
loan book disposes. Neither the agent nor its operator can write a false entry into anyone's history.

That is Creditcoin's own reason to exist, made literal: the money moves where the money lives, and the
record of it lives where a record can be trusted. It is deliberately built around what Attestcoin
does **not** prove — inclusion is not success — so the book re-derives and re-checks every property
of the repayment on-chain before it counts.

## Attestcoin Protocol integration summary

Attestcoin is the main flow, not a feature beside it: remove it and there is no product. The loan
book on Creditcoin holds no trusted input of its own — it learns a repayment happened only by
verifying an Attestcoin proof of the source transaction through the BlockProver precompile
(`0x…0FD2`). Every write to a credit history is downstream of that one call.

Because Attestcoin proves only that a transaction was *included in a confirmed block* — not that it
succeeded, called the right contract, or was sent by who it claims — the book enforces seven checks
on-chain that the proof does not: `status == 1`; the source `chainId` (resolved via the ChainInfo
precompile `0x…0FD3`, never a raw chainKey); the source contract; the `repay` selector; the borrower
== the transaction's real sender; freshness; and replay consumption. Plus two economic guards
(zero-amount and self-payment repayments are refused), because a credit entry is only worth something
if real money moved.

A full write-up, including seven undocumented protocol facts we found and reported while building
(e.g. the precompile reverts rather than returning `false`; `chainKey` is environment-scoped; the
proof envelope is `(uint8, bytes[])` not `bytes[]`, which the SDK's own docs get wrong), is in
`docs/ATTESTCOIN-INTEGRATION.md`.

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
  2026-08-13 → 09-06 window; prior work (RotorVault, on Flare) is named as the pattern's origin and
  nothing from it is reused (different chain, protocol, code).
- **Deployed on a testnet:** yes — `MockUSD` `0xCFd5E8e6…` and `LoanRepayment` `0x08F8b91A…` on
  Ethereum Sepolia, with a real 250-mUSD repayment proven on-chain (tx `0x49592b0c…`).
  `AttestedLoanBook` on Creditcoin CC3 Testnet: `0xe31906a2A7162b865b672a3a51B75813564db5e9`.
- **Attestcoin as a core feature:** yes — every write to the credit history is gated on a
  BlockProver-precompile verification; the pipeline is verified end-to-end against the live
  precompiles (`node tools/live-check.mjs`), and 28 contract tests + 20 agent tests pass.

## Encouraged extras

- **Network:** Ethereum Sepolia (source) → Creditcoin CC3 Testnet (target, chainId 102031).
- **What is real vs pending, stated plainly:** the security core is complete, the proof pipeline is
  verified end-to-end against the live precompiles, the source half is deployed with a real
  repayment proven, and the loan book on CC3 has recorded it end to end (Sepolia repay
  `0x49592b0c…` -> CC3 post `0x0f3d4ca0…`, book now reads totalRepaid 250000000 / repaymentCount 1).
  Nothing in the flow is mocked.
- **Ecosystem contribution:** seven undocumented Attestcoin behaviours found and documented, two of
  which make a consumer written from the current docs fail outright — reported for the team's benefit.
