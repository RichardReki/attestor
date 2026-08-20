// What the agent is allowed to decide, and what it is structurally incapable of deciding.
//
// The agent watches authorisations appear on Sepolia and chooses which ones to carry to Creditcoin.
// That is the whole of its power. It cannot invent an authorisation, raise an amount, extend a
// deadline, or act for an actor who did not sign — not because we ask it not to, but because
// `AttestedGovernor` re-derives every one of those from the proven transaction and would reject a
// forgery from us exactly as it would from anyone else.
//
// So the interesting question is not "can the agent be trusted", it is "what is left for the agent
// to be wrong about". The answer is: it can withhold service, and it can waste gas. Everything
// below is judgement about those two, and nothing below can widen its authority. `Verdict` has no
// variant that carries an amount, and that absence is deliberate — an approval here is a decision
// to *forward*, never a decision to *grant*.

export interface Authorisation {
  actor: string;
  amount: bigint;
  deadline: number; // unix seconds, chosen by the actor on the source chain
  txHash: string;
  sourceHeight: number;
  observedAt: number; // unix seconds, when the agent saw it
}

export interface Verdict {
  forward: boolean;
  reason: string;
}

export interface PolicyLimits {
  /// Largest single authorisation the agent will carry. The chain does not cap amounts — the actor
  /// authorises what they like — so this is purely the operator's own appetite.
  maxAmount: bigint;
  /// Ceiling on everything one actor has had forwarded inside `windowSeconds`.
  maxPerActorInWindow: bigint;
  /// Ceiling on how many authorisations one actor may have forwarded inside `windowSeconds`.
  maxCountPerActorInWindow: number;
  windowSeconds: number;
  /// Attestation lag beyond which the agent stops acting. Normal is around 40 blocks; a lag far
  /// above that means the pipeline is degraded, and the honest response to "I do not know how old
  /// this fact is" is to stop, not to guess.
  maxLagBlocks: number;
  /// Authority windows longer than this are refused here as well as on-chain, so an obviously
  /// wrong grant is caught before anyone pays gas for it.
  maxAuthorityWindowSeconds: number;
}

export const DEFAULT_LIMITS: PolicyLimits = {
  maxAmount: 10_000n,
  maxPerActorInWindow: 25_000n,
  maxCountPerActorInWindow: 5,
  windowSeconds: 3600,
  maxLagBlocks: 200,
  maxAuthorityWindowSeconds: 86_400,
};

interface Forwarded {
  id: number;
  actor: string;
  amount: bigint;
  at: number;
}

/// Tracks what the agent has carried — or is *committed to carrying* — so velocity and exposure can
/// be judged.
///
/// The word "committed" is the whole point, and it is why `reserve` exists alongside `record`.
/// Carrying an authorisation takes about eight minutes (attestation, then the proof round trip),
/// and the event handler is fully re-entrant. If the ledger only learned about an authorisation
/// *after* it landed, then a burst of authorisations from one actor would all be judged against an
/// empty ledger — every one would see zero prior volume, and the per-actor limits would enforce
/// nothing at all under exactly the load they exist for. So the moment an authorisation clears the
/// admission check we `reserve` it: concurrent handlers see the reservation immediately, and it is
/// rolled back with `release` if the carry later fails. `record` is just a reservation that will
/// never be released.
///
/// Still in memory on purpose. A restart forgets reservations, which is the safe direction — it can
/// only forget that the agent *has* forwarded, never that it has not, so a restart is more
/// permissive about velocity and never about authenticity. The replay guard that actually protects
/// funds is on-chain, not here.
export class Ledger {
  private rows: Forwarded[] = [];
  private seq = 0;

  /// @param retentionSeconds rows older than this are dropped on write; must be >= the largest
  ///   window ever queried, or a live entry could be pruned. Defaults to the policy window.
  constructor(private readonly retentionSeconds: number = DEFAULT_LIMITS.windowSeconds) {}

  /// Count an authorisation the agent has decided to carry but has not yet landed. Returns an id to
  /// `release` if the carry fails.
  reserve(actor: string, amount: bigint, at: number): number {
    this.prune(at);
    const id = ++this.seq;
    this.rows.push({ id, actor: actor.toLowerCase(), amount, at });
    return id;
  }

  /// Undo a reservation whose carry did not complete.
  release(id: number): void {
    this.rows = this.rows.filter((r) => r.id !== id);
  }

  /// A reservation that is never released — the agent has landed this one for good.
  record(actor: string, amount: bigint, at: number): number {
    return this.reserve(actor, amount, at);
  }

  within(actor: string, now: number, windowSeconds: number): Forwarded[] {
    const key = actor.toLowerCase();
    return this.rows.filter((r) => r.actor === key && now - r.at <= windowSeconds);
  }

  /// Expired rows are unreachable by `within` (it filters on the window), so dropping anything older
  /// than the retention is safe and keeps the array from growing without bound over a long run.
  private prune(now: number): void {
    this.rows = this.rows.filter((r) => now - r.at <= this.retentionSeconds);
  }
}

/// Decide whether to carry an authorisation to Creditcoin.
///
/// Every rejection names the rule that fired. A risk gate whose refusals are indistinguishable is
/// one nobody can operate: the difference between "you are over your hourly limit" and "the
/// attestation pipeline is behind" is the difference between waiting and paging someone.
///
/// `recheckOnly` re-runs an authorisation that was ALREADY admitted and reserved, after the ~8
/// minute wait, to catch what can have changed in the meantime — the deadline may have passed, the
/// attestation may have fallen behind. It deliberately skips the per-actor velocity and exposure
/// checks, because this authorisation's own reservation is now in the ledger and re-counting it
/// against itself would reject every admitted authorisation on the second pass.
export function judge(
  auth: Authorisation,
  ledger: Ledger,
  lagBlocks: number,
  now: number,
  limits: PolicyLimits = DEFAULT_LIMITS,
  opts: { recheckOnly?: boolean } = {},
): Verdict {
  if (lagBlocks > limits.maxLagBlocks) {
    return {
      forward: false,
      reason: `attestation is ${lagBlocks} blocks behind (limit ${limits.maxLagBlocks}); holding until it recovers`,
    };
  }

  if (auth.deadline <= now) {
    return { forward: false, reason: `authority expired at ${auth.deadline}` };
  }

  if (auth.deadline - now > limits.maxAuthorityWindowSeconds) {
    return {
      forward: false,
      reason:
        `authority runs for ${auth.deadline - now}s (limit ${limits.maxAuthorityWindowSeconds}s); ` +
        `a grant this long is refused on-chain too, so forwarding it would only burn gas`,
    };
  }

  if (auth.amount <= 0n) {
    return { forward: false, reason: 'amount is zero' };
  }

  if (auth.amount > limits.maxAmount) {
    return { forward: false, reason: `amount ${auth.amount} exceeds the per-authorisation cap ${limits.maxAmount}` };
  }

  if (opts.recheckOnly) {
    return { forward: true, reason: 'still within the time-sensitive limits; the chain decides' };
  }

  const recent = ledger.within(auth.actor, now, limits.windowSeconds);
  if (recent.length >= limits.maxCountPerActorInWindow) {
    return {
      forward: false,
      reason:
        `${recent.length} authorisations already forwarded for this actor in the last ` +
        `${limits.windowSeconds}s (limit ${limits.maxCountPerActorInWindow})`,
    };
  }

  const exposure = recent.reduce((sum, r) => sum + r.amount, 0n);
  if (exposure + auth.amount > limits.maxPerActorInWindow) {
    return {
      forward: false,
      reason:
        `would take this actor to ${exposure + auth.amount} inside ${limits.windowSeconds}s ` +
        `(limit ${limits.maxPerActorInWindow})`,
    };
  }

  return { forward: true, reason: `within limits; the chain decides` };
}
