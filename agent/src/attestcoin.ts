// The proof pipeline: a Sepolia transaction hash in, a Creditcoin-verifiable proof out.
//
// The one thing to understand before using it is that this is not fast and cannot be made fast.
// A source block is not provable until it is attested, and attestation trails the chain head by
// roughly 40 blocks — the prover additionally refuses anything inside a 32-block reorg-protection
// window, which is the only place that number is written down at all (it appears in the text of a
// `BlockNotOnSourceChain` error and nowhere in the documentation). End to end, expect ~8 minutes.
//
// That bound is a product constraint, not an implementation detail, so it is surfaced here rather
// than hidden behind a spinner. An agent built on Attestcoin acts on facts that are minutes old,
// and a design that pretends otherwise is lying to whoever depends on it.
import { JsonRpcProvider } from 'ethers';
import { chainInfo, proofProvider } from '@gluwa/usc-sdk';
import type { Config } from './config.js';

export interface Proof {
  chainKey: number;
  headerNumber: number;
  txHash: string;
  txBytes: string;
  merkleProof: { root: string; siblings: { hash: string; isLeft: boolean }[] };
  continuityProof: { lowerEndpointDigest: string; roots: string[] };
}

export interface Lag {
  attestedHeight: number;
  sourceHead: number;
  blocks: number;
}

export class Attestcoin {
  private readonly info: chainInfo.PrecompileChainInfoProvider;
  private readonly builder: proofProvider.service.ProofBuilder;

  constructor(
    private readonly cfg: Config,
    private readonly source: JsonRpcProvider,
    target: JsonRpcProvider,
  ) {
    this.info = new chainInfo.PrecompileChainInfoProvider(target);
    this.builder = new proofProvider.service.ProofBuilder(cfg.chainKey, cfg.proverUrl);
  }

  /// Resolve the configured chainKey to the chain it actually denotes here.
  ///
  /// Worth doing at startup even though `AttestedLoanBook` re-checks it on every call, because the
  /// failure this guards against is silent: `chainKey` is scoped to the environment, so the same
  /// constant names Sepolia on CC3 Testnet and Ethereum mainnet on CC3 Mainnet. An agent pointed at
  /// the wrong environment would otherwise run for hours, submitting proofs that are perfectly
  /// genuine and always rejected, with nothing in the logs to say why.
  async assertChainKeyIsWhatWeThink(): Promise<void> {
    const chain = await this.info.getSupportedChainByKey(this.cfg.chainKey);
    if (!chain) throw new Error(`chainKey ${this.cfg.chainKey} is not supported on this network`);
    if (chain.chainId !== this.cfg.sourceChainId) {
      throw new Error(
        `chainKey ${this.cfg.chainKey} resolves to chainId ${chain.chainId} here, but this agent is ` +
          `configured for ${this.cfg.sourceChainId}. Refusing to run: every proof would be rejected.`,
      );
    }
  }

  /// How far behind the source chain head attestation currently is.
  ///
  /// Reported rather than merely waited on: a lag that suddenly grows is the earliest visible sign
  /// that the attestation pipeline is degraded, and it is something the risk policy should be
  /// allowed to act on. Acting confidently on facts of unknown age is worse than not acting.
  async lag(): Promise<Lag> {
    const [attested, head] = await Promise.all([
      this.info.getLatestAttestedHeightAndHash(this.cfg.chainKey),
      this.source.getBlockNumber(),
    ]);
    const attestedHeight = Number(attested.height);
    return { attestedHeight, sourceHead: head, blocks: head - attestedHeight };
  }

  /// Wait until `height` is attested, then build the proof for `txHash`.
  ///
  /// Polls `is_height_attested` on the ChainInfo precompile rather than the SDK's own waiter: the
  /// SDK's `waitUntilHeightAttested` is marked legacy in its own source, and reading the state we
  /// actually depend on keeps the failure modes ours.
  async proveWhenReady(
    txHash: string,
    height: number,
    opts: { pollMs?: number; timeoutMs?: number; onWait?: (lag: Lag) => void } = {},
  ): Promise<Proof> {
    const pollMs = opts.pollMs ?? 20_000;
    // Size the timeout to the actual distance to cover, not a fixed number. A fixed 20 minutes is
    // shorter than the wait the lag policy is willing to admit (maxLagBlocks of 200 is ~40 minutes
    // of Sepolia), so a legitimately-behind-but-acceptable attestation would time out and the
    // authorisation would be dropped. Sepolia is ~12s/block; double it for headroom, add a floor.
    let deadline = Date.now() + (opts.timeoutMs ?? 20 * 60_000);
    let sized = false;

    for (;;) {
      const { height: attested } = await this.info.getLatestAttestedHeightAndHash(this.cfg.chainKey);
      if (Number(attested) >= height) break;
      if (!sized) {
        const gapBlocks = height - Number(attested);
        const needMs = gapBlocks * 12_000 * 2 + 5 * 60_000;
        deadline = Date.now() + Math.max(opts.timeoutMs ?? 0, needMs);
        sized = true;
      }
      if (Date.now() > deadline) {
        throw new Error(
          `block ${height} was still unattested after the sized wait (attestation is at ${attested}). ` +
            `The source chain or the attestation pipeline is behind — this is retriable once it recovers.`,
        );
      }
      opts.onWait?.(await this.lag());
      await new Promise((r) => setTimeout(r, pollMs));
    }

    const res = await this.builder.getProof(txHash);
    if (!res.success || !res.data) {
      // The prover distinguishes retriable conditions from permanent ones; surface which.
      const e = res as unknown as { error?: { code?: string; message?: string; retriable?: boolean } };
      throw new Error(
        `proof generation failed${e.error?.code ? ` (${e.error.code})` : ''}: ${e.error?.message ?? 'unknown'}`,
      );
    }
    return res.data as unknown as Proof;
  }
}
