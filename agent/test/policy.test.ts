import { describe, it, expect } from 'vitest';
import { judge, Ledger, DEFAULT_LIMITS, type Authorisation } from '../src/policy.js';

const NOW = 1_800_000_000;
const auth = (over: Partial<Authorisation> = {}): Authorisation => ({
  actor: '0x349769ac0BeeF5d5A5d46386F10C147761D6C0B6',
  amount: 500n,
  deadline: NOW + 3600,
  txHash: '0xabc',
  sourceHeight: 11_490_830,
  observedAt: NOW,
  ...over,
});

describe('what the agent forwards', () => {
  it('forwards an ordinary authorisation, and says the chain decides', () => {
    const v = judge(auth(), new Ledger(), 40, NOW);
    expect(v.forward).toBe(true);
    expect(v.reason).toMatch(/chain decides/);
  });

  it('holds everything when attestation falls behind, because the age of the fact is unknown', () => {
    const v = judge(auth(), new Ledger(), DEFAULT_LIMITS.maxLagBlocks + 1, NOW);
    expect(v.forward).toBe(false);
    expect(v.reason).toMatch(/blocks behind/);
  });

  it('refuses an expired authorisation without paying to learn what the chain thinks', () => {
    expect(judge(auth({ deadline: NOW - 1 }), new Ledger(), 40, NOW).forward).toBe(false);
  });

  it('refuses an authority window longer than the governor would honour anyway', () => {
    const v = judge(auth({ deadline: NOW + 400_000 }), new Ledger(), 40, NOW);
    expect(v.forward).toBe(false);
    expect(v.reason).toMatch(/only burn gas/);
  });

  it('refuses a single authorisation above the operator cap', () => {
    expect(judge(auth({ amount: DEFAULT_LIMITS.maxAmount + 1n }), new Ledger(), 40, NOW).forward).toBe(false);
  });

  it('refuses a zero amount', () => {
    expect(judge(auth({ amount: 0n }), new Ledger(), 40, NOW).forward).toBe(false);
  });
});

describe('velocity and exposure', () => {
  it('stops an actor once they hit the hourly count', () => {
    const l = new Ledger();
    for (let i = 0; i < DEFAULT_LIMITS.maxCountPerActorInWindow; i++) l.record(auth().actor, 1n, NOW - 60);
    const v = judge(auth(), l, 40, NOW);
    expect(v.forward).toBe(false);
    expect(v.reason).toMatch(/already forwarded/);
  });

  it('stops an actor once the window total would be exceeded', () => {
    const l = new Ledger();
    l.record(auth().actor, DEFAULT_LIMITS.maxPerActorInWindow, NOW - 60);
    const v = judge(auth({ amount: 1n }), l, 40, NOW);
    expect(v.forward).toBe(false);
    expect(v.reason).toMatch(/inside/);
  });

  it('lets history age out of the window', () => {
    const l = new Ledger();
    for (let i = 0; i < 10; i++) l.record(auth().actor, 5_000n, NOW - DEFAULT_LIMITS.windowSeconds - 1);
    expect(judge(auth(), l, 40, NOW).forward).toBe(true);
  });

  it('keeps actors separate, so one busy account cannot starve another', () => {
    const l = new Ledger();
    for (let i = 0; i < DEFAULT_LIMITS.maxCountPerActorInWindow; i++) l.record(auth().actor, 1n, NOW);
    expect(judge(auth({ actor: '0x000000000000000000000000000000000000dEaD' }), l, 40, NOW).forward).toBe(true);
  });

  it('matches actors case-insensitively, so a checksum difference is not a way around a limit', () => {
    const l = new Ledger();
    for (let i = 0; i < DEFAULT_LIMITS.maxCountPerActorInWindow; i++) l.record(auth().actor.toLowerCase(), 1n, NOW);
    expect(judge(auth({ actor: auth().actor.toUpperCase().replace('0X', '0x') }), l, 40, NOW).forward).toBe(false);
  });
});

describe('the shape of the agent’s authority', () => {
  it('has no way to express an approval that changes the amount', () => {
    // A Verdict carries `forward` and `reason` and nothing else. If a future change adds a field
    // that alters what gets executed, this test is where it should be argued for — the whole
    // security story is that the agent chooses *whether*, never *what*.
    const v = judge(auth(), new Ledger(), 40, NOW);
    expect(Object.keys(v).sort()).toEqual(['forward', 'reason']);
  });

  it('every refusal names the rule that fired', () => {
    const cases: Authorisation[] = [
      auth({ deadline: NOW - 1 }),
      auth({ amount: 0n }),
      auth({ amount: DEFAULT_LIMITS.maxAmount + 1n }),
      auth({ deadline: NOW + 400_000 }),
    ];
    for (const c of cases) {
      const v = judge(c, new Ledger(), 40, NOW);
      expect(v.forward).toBe(false);
      expect(v.reason.length).toBeGreaterThan(10);
    }
  });
});
