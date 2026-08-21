# Attestor — demo video script (~2:40)

The one idea to leave a judge with: **an agent can propose anything, but it cannot fabricate the
fact it acts on.** Every step below is real and on-chain — the repayment on Sepolia and the posting
on Creditcoin both have transaction hashes. Nothing is mocked.

Recorded assets: a terminal, the Sepolia explorer, the CC3 explorer, and `web/index.html`.

---

## 0:00 — Cold open (the thesis, said plainly)

> "This is a credit history you cannot lie to. Loan repayments happen on Ethereum, where the money
> is. The record of them lives on Creditcoin — and it can only be written if the repayment provably
> happened. Not claimed. Proven."

Screen: the evidence page (`web/index.html`) at the top — the two-line thesis and the honest-status
line under it.

## 0:18 — The real repayment (Sepolia explorer)

Open the repay transaction:
`https://sepolia.etherscan.io/tx/0x49592b0cf86b489ab5e456ccf470ae1b444521fc982e04f46cf85ad27ea442d4`

> "A borrower repays 250 dollars toward loan seven. This is a real transaction — the tokens actually
> moved to the lender, and it emitted a Repaid event. Status: success."

Point at: the `Repaid` log, and the ERC-20 transfer of 250 mUSD to the lender.

> "That last part matters. A repayment that *reverted* would still be in the block, still provable.
> So proving it happened is not the same as proving it succeeded — and the difference is the whole
> product."

## 0:45 — The proof pipeline, live (terminal)

```
cd spike && node spike.mjs
```

> "Here is the pipeline, end to end, against the live chain. It takes a real Sepolia transaction,
> gets an Attestcoin proof from the hosted prover, and verifies that proof on Creditcoin through the
> BlockProver precompile."

Point at: `verifySingle -> true`, then the two rejected forgeries.

> "And two forgeries — a tampered transaction, a wrong source chain — rejected on-chain. No key, no
> gas. You can run this yourself."

## 1:15 — The seven checks (evidence page)

Scroll to "What a proof settles" and "What the loan book refuses".

> "Attestcoin proves one thing: a transaction was included in a confirmed block. It does not prove
> it succeeded, that it called the right contract, the right function, that the sender is who the
> proof claims, that it's recent, or that you haven't already posted it. Every one of those is the
> book's job."

Point down the refusal table.

> "Crediting a borrower who didn't sign. An impostor loan contract. A repayment that reverted.
> Posting the same one twice. Every row is a test that passes."

## 1:40 — It's tested against reality, not against itself (terminal)

```
cd contracts && forge test
```

> "Twenty-eight contract tests. Twenty-two of them reject a forgery."

```
node tools/live-check.mjs
```

> "And because a mocked test can only tell you the contract is self-consistent, this last one
> re-checks six assumptions about the precompiles against the live chain — every run, with a fresh
> proof. That layer caught a bug we shipped: our chain-info interface was wrong, every mocked test
> passed, and it reverted every time on the real chain. We fixed it and kept the check."

## 2:10 — The posting on Creditcoin

> "The agent watches for repayments, waits about eight minutes for attestation — that delay is a real
> constraint, not a bug, and we show exactly why — then posts to the book on Creditcoin, which
> re-derives everything and writes the borrower's history."

Open the CC3 `post` transaction (`0x0f3d4ca0…`) and its `RepaymentPosted` event; show the book's
`totalRepaid` for the borrower reading 250000000 and `repaymentCount` 1.

> "And here it is on Creditcoin. The agent proved that repayment and posted it — the book re-derived
> every field and wrote it to the borrower's history. 250 dollars, loan seven, from a transaction
> that provably happened. A real Ethereum repayment, now an entry in a Creditcoin credit history that
> no one can forge."

## 2:30 — Close

> "Attestor. A record of real economic facts, on the chain built to hold them — where the agent
> proposes, and the chain decides. Even we can't write a lie into it."

Screen: the deployed addresses on the evidence page.

---

### Recording notes
- Everything at 0:18, 0:45, 1:40 is real and runnable **now**; record those first.
- `spike.mjs` and `live-check.mjs` each take a minute or two (they wait on the live prover) — record,
  then speed the wait in the edit.
- The CC3 posting is live (tx `0x0f3d4ca0…`); the whole loop can be re-run with `node tools/post-once.mjs`.
