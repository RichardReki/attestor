# Attested Risk Governor

An autonomous risk agent that can propose cross-chain actions, but **cannot fabricate the
source-chain facts it acts on**.

Built for **BUIDL CTC 2026 Fall** (2026-08-13 → 2026-09-06). Every line of this repository was
written inside the contest window; see `git log` for the first commit. Prior work of ours
(RotorVault, on Flare) is named here as the origin of the *pattern* — an agent proposes, an on-chain
rule disposes — and nothing from it is reused: different chain, different protocol, different code.

## Status

Day 1. The feasibility gate is closed: a real Ethereum Sepolia transaction has been proven on
Creditcoin CC3 Testnet through the Attestcoin BlockProver precompile, and two forged variants were
rejected on-chain. Reproduce it yourself, with no key and no gas:

```bash
cd spike && npm install && node spike.mjs
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

## Three things we found that the documentation does not say

Recorded here as we hit them, with reproductions in `spike/`.

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
detail.** The prover enforces a **32-block reorg-protection window** (visible only in its
`BlockNotOnSourceChain` error text), and we measured an attestation lag of ~39 Sepolia blocks. An
agent built on this cannot act on fresher source facts than that. We state the bound rather than
implying real-time.

**3. `chainKey` is environment-scoped, not a global chain id.**

| Environment | chainKey 1 | chainKey 3 |
| --- | --- | --- |
| CC3 Testnet | Ethereum Sepolia (`chainId 11155111`) | Ethereum mainnet (`chainId 1`) |
| CC3 Mainnet | Ethereum mainnet (`chainId 1`) | — |

A contract that hardcodes `chainKey == 1` and is promoted from testnet to mainnet **silently changes
which chain it trusts**, with no code change and no error. Bind to `chainId` via the ChainInfo
precompile (`0x…0FD3`), not to `chainKey`. This is the sharpest attack in our demo.

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
