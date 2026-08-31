// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// Attestcoin's BlockProver precompile.
///
/// Note the name. The `gluwa/usc-sdk` package exposes this as `verifySingle`, but the on-chain function is
/// `verify` — writing `verifySingle` in a Solidity interface produces a selector that does not
/// exist on the precompile, and the call fails for a reason that has nothing to do with the proof.
/// `verify` is also overloaded: the batch form takes arrays.
///
/// Note the return type, and do not trust it. The SDK documents "resolving to true if verification
/// succeeds, false otherwise". In practice the precompile REVERTS on a bad proof — we have observed
/// `"Merkle proof validation failed"` for tampered transaction bytes and
/// `"Continuity proof does not match attestation or checkpoint"` for a wrong chain key. A caller
/// that writes `if (!verify(...))` has written dead code. Wrap the call in `try`.
interface IBlockProver {
    struct MerkleSibling {
        bytes32 hash;
        bool isLeft;
    }

    struct MerkleProof {
        bytes32 root;
        MerkleSibling[] siblings;
    }

    struct ContinuityProof {
        bytes32 lowerEndpointDigest;
        bytes32[] roots;
    }

    function verify(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        MerkleProof calldata merkleProof,
        ContinuityProof calldata continuityProof
    ) external view returns (bool);
}

/// Attestcoin's ChainInfo precompile. Function names are snake_case on-chain even though the SDK
/// presents them camelCased (`getSupportedChainByKey` -> `get_chain_by_key`).
interface IChainInfo {
    struct Chain {
        uint64 chainKey; // identifier ON CREDITCOIN — environment-scoped, see below
        uint64 chainId; // the source chain's own id — globally meaningful
        bytes chainName;
        uint8 chainEncoding;
    }

    /// What `get_chain_by_key` returns: ONE tuple containing the chain and a found flag.
    ///
    /// The distinction is not cosmetic. The precompile's ABI is
    /// `get_chain_by_key(uint64) -> (((uint64,uint64,bytes,uint8),bool))` — note the doubled
    /// parentheses. Declaring it as two return values, `returns (Chain memory, bool)`, is a
    /// different encoding: `Chain` contains a `bytes`, so it is dynamic, and the single-tuple form
    /// carries one extra level of indirection. We had it wrong, and every mocked test still passed
    /// because the mock encoded it the same wrong way; only calling the live precompile exposed it.
    struct ChainResult {
        Chain chain;
        bool exists;
    }

    /// Resolve a chainKey to the chain it actually denotes in THIS environment.
    ///
    /// This lookup is the whole defence against Attestcoin's sharpest footgun: `chainKey` is scoped
    /// to the environment, not global. On CC3 Testnet `chainKey 1` is Ethereum Sepolia
    /// (`chainId 11155111`); on CC3 Mainnet `chainKey 1` is Ethereum mainnet (`chainId 1`). A
    /// contract that hardcodes `chainKey == 1` and is promoted from testnet to mainnet silently
    /// changes which chain it trusts, with no code change, no migration and no error. Bind to
    /// `chainId`; treat `chainKey` as an untrusted input to be resolved.
    function get_chain_by_key(uint64 chainKey) external view returns (ChainResult memory);

    function is_height_attested(uint64 chainKey, uint64 height) external view returns (bool);

    /// What `get_latest_attestation_height_and_hash` returns.
    ///
    /// The field is called `hash`, and it is NOT the source chain's block hash. It is Attestcoin's
    /// own continuity digest for that chain — `LastDigest` in the attestation pallet, the running
    /// `keccak256(blockNumber ++ root ++ prevDigest)` chain. There is no getter anywhere on
    /// `ChainInfo` that returns a source header hash, and nothing in the signed attestation carries
    /// a timestamp either. A consumer that reads this field expecting an Ethereum block hash gets a
    /// value that is the right type, is never null, and never matches. We do not read it; the field
    /// is declared only because the tuple has to be decoded in full to reach `height`.
    ///
    /// Verified against the live precompile on CC3 Testnet rather than inferred: calling this with
    /// `chainKey 1` returns `(11603098, 0x00b2e1cd…, true, true)` — four words, in this order.
    struct HeightHashResult {
        uint64 height;
        bytes32 hash; // continuity digest, NOT a source block hash. See above.
        bool isAttestation; // false when the answer came from a checkpoint rather than an attestation
        bool exists;
    }

    /// The newest source height Attestcoin has attested for this chain.
    ///
    /// This is the only clock a consumer gets. Because the attested data carries no timestamp, "how
    /// old is this repayment" can only be answered in source blocks: `latest - proven`. Anything
    /// phrased in seconds is either using the Creditcoin block time of the posting transaction —
    /// which says when the proof was submitted, not when the repayment happened — or inventing it.
    function get_latest_attestation_height_and_hash(uint64 chainKey)
        external
        view
        returns (HeightHashResult memory);
}
