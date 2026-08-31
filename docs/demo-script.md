# Demo video script — Attestor

**Target: 3:30. Hard ceiling 5:00.** Six segments. Everything below is a real command against a live
chain; nothing is staged and nothing needs a private key except the one optional segment marked so.

The whole video exists to land one sentence, and every segment is either setting it up or paying it
off:

> **This person has never heard of us. We proved what they did on Aave, and now they have credit on
> Creditcoin that nobody — including us — can forge.**

Say that sentence out loud at 0:20 and again at 3:00. Judges watch forty of these; one clear claim
they can repeat back is worth more than six features they cannot.

---

## Before you hit record

Open these and nothing else. Close Slack, mail, notifications.

| Window | What |
|---|---|
| **A** Terminal | `cd f:\Hacks\attestor`, font size up to ~18pt so it reads on a phone |
| **B** Browser tab 1 | https://sepolia.etherscan.io/address/0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951 (Aave V3 Pool) |
| **C** Browser tab 2 | https://creditcoin-testnet.blockscout.com/address/0xc3762daB9AB246771a91B764d0E45f03619A61ea (AaveLoanBook) |
| **D** Browser tab 3 | `contracts/src/AaveLoanBook.sol` on GitHub |

Set these once in terminal A so the later segments are one command each:

```powershell
$env:AAVE_BOOK="0xc3762daB9AB246771a91B764d0E45f03619A61ea"
```

Do a full dry run first. `tools/post-aave.mjs --dry` picks a *fresh* repayment each time, so the
addresses you rehearse with will not be the ones you record — that is the point, but check it runs.

---

## Segment 1 — the claim (0:00–0:25)

**Screen:** slide 1 of `docs/deck.pdf`, or just the README top in the browser.

**Say:**

> Creditcoin exists so credit history can be verified. But the lending happens on Ethereum. Bridging
> that record usually means trusting a relayer's word — and a credit history you can forge is worth
> nothing.
>
> So we built a loan book on Creditcoin that reads repayments made to **Aave** — a protocol we did
> not write, used by people we have never met. **We cannot fabricate an entry in it.** Let me show
> you.

Do not explain the architecture yet. Claim first.

---

## Segment 2 — the source is not ours (0:25–1:00)

**Screen:** window B, the Aave V3 Pool on Etherscan. Scroll the Events tab so real `Repay` events
scroll past.

**Say:**

> This is the Aave V3 pool on Sepolia. We did not deploy it. These repayments are strangers paying
> down their own debts — dozens a day, none of them ours.
>
> Everything you are about to see starts here, and that matters more than anything in our contracts.
> A credit history you issue to yourself proves only that you can issue history to yourself.

**Beat.** Let that sentence sit for a second before moving.

---

## Segment 3 — prove one, live (1:00–2:00)

**Screen:** window A, full screen.

```bash
node tools/post-aave.mjs --dry
```

**While it runs, say:**

> This picks a repayment that Aave logged and Creditcoin has already attested, then asks the
> Attestcoin proof builder for a merkle and continuity proof of that transaction.

**When it prints, point at the screen and read the actual values aloud:**

> There. Address `0x…` repaid `…` USDC. I have never seen that address before this command ran —
> and if I run it again I will get a different one, because people keep repaying.

**Then point at the log index line specifically:**

> This line is worth ten seconds. `eth_getLogs` numbers logs per *block*; the attested receipt
> numbers them per *transaction*. Here that is 6 and 40. Use the wrong one and on a short receipt you
> revert — but on a long one you silently credit the wrong borrower. We found that by checking
> instead of assuming.

That last beat is the single most convincing thing in the video for a technical judge. Do not rush it.

---

## Segment 4 — the chain refuses forgeries (2:00–2:40)

**Screen:** window A.

```bash
cd spike && node aave-proof.mjs
```

**Say, over the output:**

> Same pipeline, keyless, plus two negative controls. It proves a real Aave repayment, recovers the
> `Repay` event out of the attested payload, and checks every field against what Sepolia's own RPC
> reports.

**When the tamper control prints:**

> Then it flips one byte of the transaction and asks the precompile again — *"Merkle proof validation
> failed."* Not our check. Creditcoin's.

**Optional 10 seconds, screen D:** scroll `AaveLoanBook.sol` to the checks.

> Attestcoin proves a transaction was *included in a block*. Not that it succeeded, not that it
> touched Aave, not that the person claiming it sent it. Everything the proof does not say, the book
> checks itself.

---

## Segment 5 — the payoff (2:40–3:15)

**Screen:** window C, the AaveLoanBook on Blockscout. Use Read Contract → `totalRepaid` with the
borrower address from segment 3, then the CreditLine.

**Say:**

> Here is the book on Creditcoin. `totalRepaid` for that borrower — the one I met sixty seconds ago —
> is real, and it got there through one precompile call that either verified or reverted.
>
> And a credit line reading this book gives them a limit. **Twenty-five USDC of credit, sized
> entirely by what they did on Ethereum.** An address with no Aave history gets zero.
>
> I cannot draw that loan. `borrow` credits `msg.sender`, and the key is theirs. That is the honest
> version — the history belongs to them, so the money does too.

**Then the sentence again, slowly:**

> This person has never heard of us. We proved what they did on Aave, and now they have credit on
> Creditcoin that nobody, including us, can forge.

---

## Segment 6 — what we are not claiming (3:15–3:30)

**Screen:** the honest-status box of the deck, or just your face.

**Say:**

> Two things I am not claiming. We also built the same book against a contract we wrote ourselves —
> it is still in the repo, deliberately, as the control. Every check passes there too, and it proves
> nothing, which is exactly why the Aave one matters.
>
> And Attestcoin proves inclusion, not success. We found seven things about the protocol its
> documentation does not say, including two that make a consumer written from the docs fail outright.
> They are written up and reported.
>
> Repository, addresses and every transaction hash are in the README. Thanks for watching.

---

## Optional segment — post it live (+40s)

Only if the video is running short and you are comfortable using the key on camera. **Blank the
terminal history first** and set `PRIVATE_KEY` in a window that is not being recorded.

```bash
node tools/post-aave.mjs
```

Then show the transaction on Blockscout. It is stronger than a read, but a live send that fails on
camera costs more than it gains — the `--dry` run plus the already-landed transaction
(`0x7fb71b18…`) makes the same point with none of the risk.

---

## Recording notes

- **One take per segment**, not one take for the video. Six short recordings cut together beat one
  long take you keep restarting.
- **Terminal font ~18pt.** Judges watch on laptops and phones. If the log-index line is unreadable,
  segment 3 is wasted.
- **Do not read this script aloud.** Know the beat of each segment and say it in your own words. The
  sentence at 0:20 and 3:00 is the only one worth memorising.
- **Silence is fine** while a command runs. Do not fill it with "so basically".
- If a live command fails on camera, say so and move on. This project's whole argument is that it
  reports what actually happened.
