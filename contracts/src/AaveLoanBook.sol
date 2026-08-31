// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IBlockProver, IChainInfo} from "./interfaces/IAttestcoin.sol";
import {AttestedTx} from "./lib/AttestedTx.sol";

/// A credit history built from repayments made to **Aave V3** — a lending protocol we did not write,
/// used by people we have never met.
///
/// This contract exists because of a weakness in its sibling. `AttestedLoanBook` proves repayments
/// made to `LoanRepayment`, which is *our* contract, moving *our* mock stablecoin, sent by *our*
/// borrower. Every one of its seven checks is real and every one of them passes, and none of that is
/// evidence of anything: a history you issue to yourself proves only that you can issue history to
/// yourself. The proof machinery was never the weak link — the *source fact* was.
///
/// So this book points the same machinery at a source we control no part of. The Aave V3 Pool on
/// Ethereum Sepolia (`0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951`) emits `Repay` when a borrower
/// pays down a debt. We cannot cause those events, cannot choose who appears in them, and cannot
/// change what they say. What Attestcoin brings back is a fact about a stranger's behaviour in a
/// protocol with real liquidity behind it, and the whole point of the exercise is that the contract
/// below can act on it without anyone vouching for it.
///
/// Three things differ from the sibling, and each is forced by reading a contract we did not write:
///
///   1. **The fact lives in a log, not in calldata.** `Pool.repay(asset, amount, rateMode, onBehalfOf)`
///      accepts `amount = type(uint256).max` to mean "all of it", so the calldata does not say how
///      much was repaid — only the emitted `Repay` event does. Reading arguments works when you wrote
///      the source function and put the number there yourself. It does not generalise.
///   2. **Replay is keyed per LOG.** One transaction can repay several debts; a routed repayment on
///      this pool has been observed at log index 500. Keying on the transaction would record the
///      first repayment in it and silently discard the others.
///   3. **Freshness is measured in blocks.** The sibling reads a `deadline` argument that our own
///      source contract puts in its calldata. Aave has no such field, and Attestcoin's attestation
///      carries no timestamp anywhere — so age is `latestAttestedHeight - provenHeight`, in source
///      blocks, and cannot honestly be stated in seconds.
contract AaveLoanBook {
    using AttestedTx for AttestedTx.Call;
    using AttestedTx for AttestedTx.Log;

    IBlockProver internal constant PROVER = IBlockProver(0x0000000000000000000000000000000000000FD2);
    IChainInfo internal constant CHAIN_INFO = IChainInfo(0x0000000000000000000000000000000000000fD3);

    /// `Repay(address indexed reserve, address indexed user, address indexed repayer, uint256 amount, bool useATokens)`
    /// Computed from the signature, not copied from a block explorer.
    bytes32 public constant REPAY_TOPIC = 0xa534c8dbe71f871f9f3530e97a74601fea17b426cae02e1c5aee42c96c784051;

    /// The Aave V3 Pool whose logs are believed. Bound at construction, never settable: a book whose
    /// notion of "the lending protocol" can be repointed is a book whose history can be rewritten.
    address public immutable pool;

    /// The source chain's own id (11155111 for Sepolia). `chainKey` is resolved against this and is
    /// never trusted on its own — see `IChainInfo.get_chain_by_key`.
    uint64 public immutable expectedChainId;

    /// How far behind the newest attested height a repayment may be and still be posted, in SOURCE
    /// blocks. Bounds how much history can be swept in at once; it does not make old repayments
    /// false, only unwelcome.
    uint64 public immutable maxAgeBlocks;

    /// One consumed key per (chain, height, transaction, log).
    mapping(bytes32 => bool) public consumed;

    /// Repayments a borrower made for their OWN debt. This is the credit history.
    mapping(address => uint256) public totalRepaid;
    mapping(address => uint256) public repaymentCount;

    /// Repayments someone ELSE made against this borrower's debt. Recorded, deliberately not
    /// credited — see `post`.
    mapping(address => uint256) public repaidByOthers;

    event RepaymentPosted(
        bytes32 indexed key,
        address indexed borrower,
        address indexed reserve,
        address repayer,
        uint256 amount,
        bool selfRepaid,
        uint64 height
    );

    error UnsupportedChainKey(uint64 chainKey);
    error WrongChain(uint64 chainKey, uint64 got, uint64 expected);
    error ProofRejected(string reason);
    error SourceReverted();
    error NoSuchLog(uint256 logIndex);
    error NotARepayEvent(uint256 logIndex);
    error WrongEmitter(address got, address expected);
    error MalformedEvent(uint256 logIndex);
    error AlreadyPosted(bytes32 key);
    error ZeroAmount();
    error NotYetAttested(uint64 chainKey);
    error FromTheFuture(uint64 height, uint64 latest);
    error TooOld(uint64 age, uint64 maxAge);

    constructor(address pool_, uint64 expectedChainId_, uint64 maxAgeBlocks_) {
        pool = pool_;
        expectedChainId = expectedChainId_;
        maxAgeBlocks = maxAgeBlocks_;
    }

    /// Post one proven Aave repayment to the borrower's history.
    ///
    /// @param chainKey  the source chain's Creditcoin-local key — resolved, never trusted
    /// @param height    the source block height the proof is against
    /// @param logIndex  which log in the receipt is the repayment being claimed. Named by the caller
    ///                  and then checked, because a transaction may contain several and each is a
    ///                  separate fact that must be posted separately.
    function post(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        IBlockProver.MerkleProof calldata merkleProof,
        IBlockProver.ContinuityProof calldata continuityProof,
        uint256 logIndex
    ) external {
        // 1. CHAIN. Resolve the key to a real chain id before believing anything about it. On CC3
        //    Testnet chainKey 1 is Sepolia; on Mainnet the same key is Ethereum. Binding to chainId
        //    is what stops a promotion from silently changing which chain this book trusts.
        IChainInfo.ChainResult memory r = CHAIN_INFO.get_chain_by_key(chainKey);
        if (!r.exists) revert UnsupportedChainKey(chainKey);
        if (r.chain.chainId != expectedChainId) revert WrongChain(chainKey, r.chain.chainId, expectedChainId);

        // 2. PROOF. The precompile reverts rather than returning false, so the try is not defensive
        //    styling — it is the only way to distinguish "this proof is a forgery" from "this proof
        //    is fine but describes a repayment we do not accept".
        try PROVER.verify(chainKey, height, encodedTransaction, merkleProof, continuityProof) returns (bool ok) {
            if (!ok) revert ProofRejected("precompile returned false");
        } catch Error(string memory reason) {
            revert ProofRejected(reason);
        } catch {
            revert ProofRejected("precompile reverted without a reason");
        }

        // 3. FRESHNESS. Measured against Attestcoin's own view of the source chain, in blocks,
        //    because the attestation carries no timestamp. A height above the newest attested one
        //    should be unreachable — the proof just verified against it — so treat it as a bug in an
        //    assumption rather than a merely stale submission, and say which.
        IChainInfo.HeightHashResult memory tip = CHAIN_INFO.get_latest_attestation_height_and_hash(chainKey);
        if (!tip.exists) revert NotYetAttested(chainKey);
        if (height > tip.height) revert FromTheFuture(height, tip.height);
        uint64 age = tip.height - height;
        if (age > maxAgeBlocks) revert TooOld(age, maxAgeBlocks);

        // 4. REPLAY, keyed per log. The encoded transaction carries its signature, so its hash
        //    identifies the transaction; the log index identifies which fact inside it. Consume
        //    before writing anything.
        bytes32 key = keccak256(abi.encode(chainKey, height, keccak256(encodedTransaction), logIndex));
        if (consumed[key]) revert AlreadyPosted(key);
        consumed[key] = true;

        (address borrower, address reserve, address repayer, uint256 amount) =
            _repaymentFrom(encodedTransaction, logIndex);

        // 5. WHOSE CREDIT THIS IS. Aave lets anybody repay anybody's debt, so `user` and `repayer`
        //    are different questions and the event answers both. The debt reduced belongs to `user`;
        //    the money came from `repayer`.
        //
        //    Only a self-repayment counts toward credit. "Someone paid my debt for me" is evidence
        //    about them, not about me, and a book that credited it would let anyone mint standing
        //    for an address they do not control — or, worse, let one funded account manufacture
        //    histories for a hundred others. It is still recorded, under `repaidByOthers`, because
        //    discarding a proven fact to keep a number tidy is its own kind of dishonesty.
        bool selfRepaid = repayer == borrower;
        if (selfRepaid) {
            totalRepaid[borrower] += amount;
            repaymentCount[borrower] += 1;
        } else {
            repaidByOthers[borrower] += amount;
        }

        emit RepaymentPosted(key, borrower, reserve, repayer, amount, selfRepaid, height);
    }

    /// Read the repayment out of a transaction that has ALREADY been proven genuine.
    function _repaymentFrom(bytes calldata encodedTransaction, uint256 logIndex)
        internal
        view
        returns (address borrower, address reserve, address repayer, uint256 amount)
    {
        AttestedTx.Call memory c = AttestedTx.decode(encodedTransaction);

        // 6. STATUS. Inclusion is not success. A reverted transaction is still in the block and
        //    still Merkle-provable; its logs, however, are not in the receipt — so this check is
        //    belt and braces rather than the only thing standing between us and a phantom repayment.
        if (c.status != 1) revert SourceReverted();

        // 7. THE EVENT. Note what is NOT checked: the transaction's `to`. A repayment routed through
        //    an aggregator or a gateway has some other contract as its callee, and rejecting those
        //    would discard perfectly real repayments. What matters is that the Aave Pool itself
        //    emitted the event — no other contract can produce a log bearing the Pool's address —
        //    so the emitter is the binding, and the callee is irrelevant.
        if (logIndex >= c.logs.length) revert NoSuchLog(logIndex);
        AttestedTx.Log memory l = c.logs[logIndex];
        if (l.addr != pool) revert WrongEmitter(l.addr, pool);
        if (l.topics.length != 4 || l.topics[0] != REPAY_TOPIC) revert NotARepayEvent(logIndex);

        // `Repay(address indexed reserve, address indexed user, address indexed repayer, uint256 amount, bool useATokens)`
        reserve = l.topicAddress(1);
        borrower = l.topicAddress(2);
        repayer = l.topicAddress(3);
        if (l.data.length < 64) revert MalformedEvent(logIndex);
        amount = l.word(0);

        // A zero-amount repayment would inflate `repaymentCount` for free. Aave should not emit one;
        // this book does not depend on Aave to have been careful on our behalf.
        if (amount == 0) revert ZeroAmount();
    }
}
