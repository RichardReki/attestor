// Runtime configuration, and the one invariant that has to be checked before anything else runs.
import 'dotenv/config';

export interface Config {
  sourceRpc: string;
  targetRpc: string;
  proverUrl: string;
  /// The source chain's own id. Everything binds to this, never to `chainKey`.
  sourceChainId: number;
  /// Creditcoin's local handle for that chain — an input to be resolved, not a fact to be trusted.
  chainKey: number;
  sourceAuthorization: string;
  governor: string;
  /// Blocks to leave between the source head and anything we try to prove. The prover refuses
  /// inside a 32-block reorg-protection window; a little more than that saves a doomed round trip.
  confirmations: number;
}

const need = (k: string): string => {
  const v = process.env[k];
  if (!v) throw new Error(`missing ${k} — see agent/.env.example`);
  return v;
};

export function load(): Config {
  return {
    sourceRpc: process.env.SEPOLIA_RPC ?? 'https://ethereum-sepolia-rpc.publicnode.com',
    targetRpc: process.env.CC3_RPC ?? 'https://rpc.cc3-testnet.creditcoin.network',
    proverUrl: process.env.PROVER_URL ?? 'https://prover.cc3-testnet.creditcoin.network',
    sourceChainId: Number(process.env.SOURCE_CHAIN_ID ?? 11155111),
    chainKey: Number(process.env.CHAIN_KEY ?? 1),
    sourceAuthorization: need('SOURCE_AUTHORIZATION'),
    governor: need('GOVERNOR'),
    confirmations: Number(process.env.CONFIRMATIONS ?? 40),
  };
}
