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
  actor: string;
  amount: bigint;
  at: number;
}

/// Tracks what the agent has already carried, so velocity and exposure can be judged.
///
/// Held in memory on purpose. Restarting the agent forgets its history, which is the safe
/// direction: it can only forget that it *has* forwarded, never that it has not, so a restart
/// makes the agent more permissive about velocity and never more permissive about authenticity —
/// and the on-chain replay guard, which is the one that actually matters, is not in memory at all.
export class Ledger {
  private readonly rows: Forwarded[] = [];

  record(actor: string, amount: bigint, at: number): void {
    this.rows.push({ actor: actor.toLowerCase(), amount, at });
  }

  within(actor: string, now: number, windowSeconds: number): Forwarded[] {
    const key = actor.toLowerCase();
    return this.rows.filter((r) => r.actor === key && now - r.at <= windowSeconds);
  }
}

/// Decide whether to carry an authorisation to Creditcoin.
///
/// Every rejection names the rule that fired. A risk gate whose refusals are indistinguishable is
/// one nobody can operate: the difference between "you are over your hourly limit" and "the
/// attestation pipeline is behind" is the difference between waiting and paging someone.
export function judge(
  auth: Authorisation,
  ledger: Ledger,
  lagBlocks: number,
  now: number,
  limits: PolicyLimits = DEFAULT_LIMITS,
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
