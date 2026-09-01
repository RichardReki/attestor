# BUIDL CTC 2026 Fall — paste-ready submission

Every heading below is a field on the DoraHacks form, **in the order the form asks for them**, using
the form's own wording. Copy the block under each heading straight in.

- Submit at: **https://dorahacks.io/hackathon/buidl-ctc-2026-fall/buidl**
- Deadline: **2026-09-14 11:59 Beijing** (03:59 UTC). This is the *extended* date — the original
  09-06 was moved. Verify the countdown on the page before you rely on it.
- **One track only.** `isMultiTracksAllowed` is false; you cannot pick a second.
- Bounties are optional and you may apply to up to 10.

Only one field below is still blank: the demo video URL.

---

## Track / Project Sector

```
DeFi
```

**Why not AI, given the field is crowded.** DeFi has 15 of the 40 submissions and contains both of
the strongest rivals; AI has 10 and our autonomous agent would be a plausible-sounding fit. It is
not an honest one — `agent/src/policy.ts` is a deterministic risk engine with no model, no
inference, and no learning anywhere in it, and a judge who opens that file sees so in ten seconds.
This project's entire argument is that it does not overclaim. Being caught overstating on the
*category field* would cost more than a crowded bracket does.

---

## Project Name

```
Attestor
```

---

## Project Logo (Image URL — PNG, SVG, or AI) · optional

```
https://raw.githubusercontent.com/RichardReki/attestor/master/web/logo.png
```

---

## Project Description

```
Attestor is a cross-chain credit history you cannot lie to.

It reads repayments made to Aave V3 on Ethereum — a lending protocol we did not write, used by
people we have never met — and turns them into credit on Creditcoin. The record is written only if
a USC proof shows the repayment really happened, so neither we nor anyone running the agent can
write a false entry into someone's history.

That the source is not ours is the point, and it is worth more than any check in the contract: a
credit history you issue to yourself proves only that you can issue history to yourself. On
2026-08-31, 0x2C56b94f8b27E116C5686B41473bC038a6d86A88 — an address we had never seen — repaid 25
USDC to Aave on Sepolia. We learned it existed by reading the chain, proved it through the
Attestcoin BlockProver precompile, and posted it. A CreditLine bound to that book now reports a
credit limit of 25000000 for them, against 0 for an address with no Aave history. Both are public
view calls. We cannot draw that loan and do not pretend we can — borrow() credits msg.sender and
the key is theirs. The history belongs to the borrower, so the money does too.

A second loan book, proving repayments to a source contract of our own, is kept in the repository
on purpose as the control. Every check passes there too and it proves nothing about anybody's
creditworthiness — which is exactly why the Aave one matters.

Run `node tools/post-aave.mjs --dry` and it selects a different, freshly-attested repayment every
time. A pinned demonstration eventually goes stale and quietly stops meaning anything; fetching a
real one on each run is the evidence.
```

---

## USC Integration Summary — explain how your project uses USC

```
USC is the substrate this project is built out of, not a library it calls. Remove it and there is
no product: the loan book on Creditcoin accepts no trusted input of its own — no owner-submitted
number, no oracle, no signed report. It learns that a repayment happened by verifying a USC proof
of the source transaction, and every write to a credit history is downstream of that one call.

The USC surfaces in use:

- BlockProver precompile 0x…0FD2 — called in-contract, first, before any state is touched, in
  AaveLoanBook.post and AttestedLoanBook.post. It reverts rather than returning false, so the call
  is wrapped in try/catch; `if (!verify(...))` would be dead code.
- ChainInfo precompile 0x…0fD3 — get_chain_by_key resolves a chainKey to a real chainId, and
  get_latest_attestation_height_and_hash supplies the only clock the system has.
- @gluwa/usc-sdk 0.18.0 — proofProvider and chainInfo, in agent/src/attestcoin.ts, spike/*.mjs and
  tools/post-aave.mjs, to build the merkle and continuity proofs against the hosted Proof Builder.

Where the work went is the gap between what USC proves and what a lender needs. USC proves a
transaction was INCLUDED IN A CONFIRMED BLOCK. That is all it proves. It does not prove the
transaction succeeded, that it touched the contract you care about, or that whoever claims it sent
it. A consumer treating "attested" as "happened the way I wanted" is exploitable, so the book
re-derives every property on-chain:

- status == 1 — a reverted repayment is still in the block and still merkle-provable
- the source chainId, resolved through ChainInfo, never a raw chainKey — chainKey is
  environment-scoped, so chainKey 1 is Sepolia on CC3 Testnet and Ethereum on Mainnet, and a
  contract hardcoding it changes which chain it trusts on promotion, silently and with no error
- the emitting contract and the event signature, as a pair — anyone can deploy a contract that
  emits Aave's event, so matching on either alone is not a statement by Aave
- the borrower, read from the event rather than from whoever submitted the proof
- repayer == borrower before credit is granted — Aave permits third-party repayment, and a debt
  someone else paid is evidence about them; crediting it would let one funded account manufacture
  standing for any address it likes. The third-party case is still recorded, separately.
- freshness, measured in SOURCE BLOCKS — no USC attestation carries a timestamp anywhere, so any
  age quoted in seconds is either the Creditcoin block time of the posting transaction, which says
  when the proof was submitted rather than when the repayment happened, or invented
- replay, consumed per LOG rather than per transaction — one transaction can repay several debts;
  a routed repayment on this pool was observed at log index 500

Seven undocumented protocol behaviours we found while building are written up in
docs/ATTESTCOIN-INTEGRATION.md and reported. Two of them make a consumer written from the current
documentation fail outright: the precompile reverts instead of returning false, and the proof
envelope is (uint8 txType, bytes[] chunks) rather than the bytes[] the SDK's own docs specify — so
a decoder written from the documentation cannot read a single real transaction.
```

---

## GitHub Repository URL (must include a README)

```
https://github.com/RichardReki/attestor
```

---

## Project Deck or Whitepaper (PDF URL)

```
https://raw.githubusercontent.com/RichardReki/attestor/master/docs/deck.pdf
```

If the form rejects a raw link or you would rather it opened in a viewer, use
`https://github.com/RichardReki/attestor/blob/master/docs/deck.pdf` instead. Both were checked and
return 200.

---

## Prototype Demo Video URL

```
[ PASTE THE YOUTUBE URL HERE ]
```

**This is the only thing still missing.** Script: `docs/demo-script.md` — six segments, about 3:30,
each one naming the window to open, the command to run and the beat to hit. Record the segments
separately and cut them together; a single take you keep restarting is how the last three projects
stalled.

---

## Deployed contracts, for any address field or for the description

| | |
| --- | --- |
| `AaveLoanBook` (CC3 Testnet) | `0xc3762daB9AB246771a91B764d0E45f03619A61ea` |
| `CreditLine`, Aave-sourced (CC3) | `0xA595C95964efaec78D85Ad18D38a05004440Bbb2` |
| Aave V3 Pool (Sepolia) — **not ours** | `0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951` |
| `AttestedLoanBook`, the control (CC3) | `0xe31906a2A7162b865b672a3a51B75813564db5e9` |
| `CreditLine`, control (CC3) | `0xC45f8594579191b5125B24f721cA4e2f93811A8c` |
| `LoanRepayment`, control source (Sepolia) | `0x08F8b91A9d447C309F1788002BF51BF0BEE69021` |
| `MockUSD`, control token (Sepolia) | `0xCFd5E8e697A1956F063B9Bb71E9E33fd78F3d0ef` |

**The transactions that carry the argument:**

| | |
| --- | --- |
| A stranger repays 25 USDC to Aave (Sepolia, block 11,605,409) | `0x2f8901c49c3702d83bd18ed0012008da025d5275009b0190c44c76badb91f7a8` |
| Its proof posted to `AaveLoanBook` (CC3, 221,790 gas) | `0x7fb71b18453c14538b6e7cd8553a41e184efec1c299bf3ca61a943a0fbe037e4` |

Verify without trusting us: `creditLimit(0x2C56b94f8b27E116C5686B41473bC038a6d86A88)` on the
Aave-sourced CreditLine returns **25000000**; the same call for an address with no Aave history
returns **0**.

---

## Before you press submit

- [ ] Video recorded and its URL pasted above
- [ ] Track set to **DeFi** — you cannot add a second later
- [ ] The GitHub repo is public and its README renders
- [ ] The deck URL opens for someone who is not logged in (test in a private window)
- [ ] Deadline re-read on the page itself — the extension moved it to 09-14, and a page that still
      shows the old date is a page-sync lag, not a shorter window

Nothing else is outstanding. The build is finished, deployed and verified on-chain; the only thing
between this and a submission is a screen recording.
