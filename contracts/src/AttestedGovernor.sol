// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IBlockProver, IChainInfo} from "./interfaces/IAttestcoin.sol";
import {AttestedTx} from "./lib/AttestedTx.sol";

/// Executes an action on Creditcoin only when a matching authorisation was really made on the
/// source chain — and refuses when it was not.
///
/// An agent may *propose* anything. What it cannot do is invent the source-chain fact it claims to
/// be acting on. Attestcoin supplies the fact; this contract decides whether the fact says what the
/// caller claims it says.
///
/// That distinction is the entire product, because Attestcoin proves LESS than it first appears.
/// It proves a transaction was *included in a confirmed block*. It does not prove the transaction
/// succeeded, that it called the contract you care about, that it called the function you care
/// about, that the caller was authorised, that it was recent, or that you have not already acted on
/// it. Every one of those is this contract's job, and skipping any single one is exploitable:
///
///   status         a reverted transaction is still perfectly includable, and therefore provable
///   chain          `chainKey` is environment-scoped; see IChainInfo.get_chain_by_key
///   source         otherwise any contract's call impersonates the one you trust
///   selector       otherwise a different function on the right contract passes
///   sender         authority belongs to the source actor, not to whoever relays the proof
///   freshness      an attested fact stays provable forever; authority should not
///   replay         otherwise one authorisation executes without limit
contract AttestedGovernor {
    IBlockProver public constant PROVER = IBlockProver(0x0000000000000000000000000000000000000FD2);
    IChainInfo public constant CHAIN_INFO = IChainInfo(0x0000000000000000000000000000000000000fD3);

    /// The source chain's OWN id (e.g. 11155111 for Sepolia) — deliberately not a chainKey.
    uint64 public immutable expectedChainId;
    /// The one source contract whose calls this governor will act on.
    address public immutable expectedSource;
    /// The one function on it that constitutes an authorisation.
    bytes4 public immutable expectedSelector;
    /// The longest window of authority this governor will honour. The source actor picks its own
    /// deadline, so without this a single authorisation carrying `deadline = type(uint256).max` is
    /// a permanent key. Freshness has to be bounded by the consumer, not by the grantor.
    uint256 public immutable maxAge;

    /// keccak256 of the encoded source transaction -> already acted upon.
    mapping(bytes32 => bool) public consumed;

    event Executed(bytes32 indexed sourceTxKey, address indexed actor, uint256 amount, uint64 sourceHeight);

    error ProofRejected(string reason); // the precompile refused the proof itself
    error WrongChain(uint64 chainKey, uint64 resolvedChainId, uint64 expected);
    error UnsupportedChainKey(uint64 chainKey);
    error SourceReverted();
    error WrongSource(address got, address expected);
    error WrongSelector(bytes4 got, bytes4 expected);
    error Unauthorised(address actor);
    error Stale(uint256 deadline);
    error Overlong(uint256 deadline);
    error AlreadyConsumed(bytes32 sourceTxKey);

    constructor(uint64 expectedChainId_, address expectedSource_, bytes4 expectedSelector_, uint256 maxAge_) {
        expectedChainId = expectedChainId_;
        expectedSource = expectedSource_;
        expectedSelector = expectedSelector_;
        maxAge = maxAge_;
    }

    /// Act on a source-chain authorisation.
    ///
    /// @param chainKey        the source chain's Creditcoin-local key — resolved, never trusted
    /// @param height          the source block height the proof is against
    /// @param encodedTransaction  the proof's `txBytes`
    function execute(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        IBlockProver.MerkleProof calldata merkleProof,
        IBlockProver.ContinuityProof calldata continuityProof
    ) external {
        // 1. CHAIN. Resolve the key to a real chain id before believing anything about it. This runs
        //    first: if the key names the wrong chain, the proof may be perfectly valid and still
        //    irrelevant, and we would rather say so than spend gas proving it.
        IChainInfo.ChainResult memory r = CHAIN_INFO.get_chain_by_key(chainKey);
        if (!r.exists) revert UnsupportedChainKey(chainKey);
        if (r.chain.chainId != expectedChainId) revert WrongChain(chainKey, r.chain.chainId, expectedChainId);

        // 2. PROOF. The precompile reverts rather than returning false, so `try` is not defensive
        //    styling here — it is the only way to tell "this proof is a forgery" apart from "this
        //    proof is fine but the authorisation does not permit what you asked". Those two answers
        //    mean very different things to whoever is looking at the failure.
        try PROVER.verify(chainKey, height, encodedTransaction, merkleProof, continuityProof) returns (bool ok) {
            // Documented as returning false on failure. It does not, in our testing — but if a
            // future version starts to, honour it rather than silently accepting.
            if (!ok) revert ProofRejected("precompile returned false");
        } catch Error(string memory reason) {
            revert ProofRejected(reason);
        } catch {
            revert ProofRejected("precompile reverted without a reason");
        }

        // 3. REPLAY. The encoding carries the signature, so its hash identifies this exact source
        //    transaction. Consume before doing anything observable.
        bytes32 key = keccak256(encodedTransaction);
        if (consumed[key]) revert AlreadyConsumed(key);
        consumed[key] = true;

        // 4-7 live in their own frame. Splitting them out keeps this function off the stack limit,
        // but it also draws the right line: above, whether the proof is real; below, what the
        // proven transaction actually authorises. Only the second half knows the source ABI.
        (address actor, uint256 amount) = _authorisationFrom(encodedTransaction);

        credited[actor] += amount;
        emit Executed(key, actor, amount, height);
    }

    /// Read the authorisation out of a transaction that has ALREADY been proven genuine.
    /// Reverts unless the transaction succeeded, called the expected function on the expected
    /// contract, was sent by the account it claims to authorise, and is currently in force.
    function _authorisationFrom(bytes calldata encodedTransaction)
        internal
        view
        returns (address actor, uint256 amount)
    {
        AttestedTx.Call memory c = AttestedTx.decode(encodedTransaction);

        // 4. STATUS. Inclusion is not success. A transaction that reverted on the source chain is
        //    still in the block, still Merkle-provable, and proves only that someone tried.
        if (c.status != 1) revert SourceReverted();

        // 5. SOURCE and 6. SELECTOR.
        if (c.to != expectedSource) revert WrongSource(c.to, expectedSource);
        bytes4 sel = AttestedTx.selector(c);
        if (sel != expectedSelector) revert WrongSelector(sel, expectedSelector);

        // 7. ARGUMENTS, SENDER and FRESHNESS. The source function is
        //    `authorise(address actor, uint256 amount, uint256 deadline)`; authority belongs to the
        //    account that actually sent that transaction, so a mismatch between the declared actor
        //    and the transaction's sender is an impersonation attempt, not a formatting quirk.
        uint256 deadline;
        (actor, amount, deadline) = abi.decode(AttestedTx.args(c), (address, uint256, uint256));
        if (actor != c.from) revert Unauthorised(actor);
        if (block.timestamp > deadline) revert Stale(deadline);
        if (deadline > block.timestamp + maxAge) revert Overlong(deadline);
    }

    /// The business action, such as it is. Deliberately trivial: every interesting decision was
    /// made before this line, and a bigger action here would only obscure that.
    mapping(address => uint256) public credited;
}
