// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IBlockProver, IChainInfo} from "./interfaces/IAttestcoin.sol";
import {AttestedTx} from "./lib/AttestedTx.sol";

/// Writes a cross-chain loan repayment history that nobody can lie to.
///
/// Creditcoin exists to make credit history verifiable. This contract is that idea taken literally:
/// repayments happen on Ethereum, where the stablecoin lives; the record of them lives on
/// Creditcoin, where it can be trusted. An off-chain agent watches for repayments and proposes
/// posting them — but it cannot invent a repayment that did not happen, because this book re-derives
/// every one from the proven source transaction and refuses anything that does not check out.
///
/// That refusal is the whole product, because Attestcoin proves LESS than it first appears. It
/// proves a transaction was included in a confirmed block. It does not prove the transaction
/// succeeded (so a reverted repayment does not count), that it called this lender's contract, that
/// it called repay rather than some other function, that the borrower is who the proof claims, that
/// it is recent, or that it has not already been posted. Every one of those is this contract's job,
/// and skipping any single one lets a false entry into someone's credit history:
///
///   status         a reverted repayment is still includable, and therefore provable
///   chain          chainKey is environment-scoped; see IChainInfo.get_chain_by_key
///   source         otherwise any contract's call is posted as a repayment to this lender
///   selector       otherwise a different function on the right contract passes as a repayment
///   sender         the credit belongs to the borrower who paid, not to whoever relays the proof
///   freshness      an attested repayment is provable forever; the right to post it should not be
///   replay         otherwise one repayment is posted again and again, inflating the history
contract AttestedLoanBook {
    IBlockProver public constant PROVER = IBlockProver(0x0000000000000000000000000000000000000FD2);
    IChainInfo public constant CHAIN_INFO = IChainInfo(0x0000000000000000000000000000000000000fD3);

    /// The source chain's OWN id (e.g. 11155111 for Sepolia) — deliberately not a chainKey.
    uint64 public immutable expectedChainId;
    /// The one LoanRepayment contract whose repayments this book records.
    address public immutable expectedSource;
    /// The repay selector — the only function that constitutes a repayment.
    bytes4 public immutable expectedSelector;
    /// The longest window a repayment may still be posted after it happened. The borrower picks the
    /// deadline, so without a ceiling here one repayment carries a permanent right to be posted.
    uint256 public immutable maxAge;

    /// keccak256 of the encoded source transaction -> already posted.
    mapping(bytes32 => bool) public consumed;
    /// keccak256(borrower, loanId) -> total repaid on that loan.
    mapping(bytes32 => uint256) public repaidOnLoan;
    /// borrower -> lifetime repaid across all loans. This is the credit history.
    mapping(address => uint256) public totalRepaid;
    /// borrower -> number of repayments posted.
    mapping(address => uint256) public repaymentCount;

    event RepaymentPosted(
        bytes32 indexed sourceTxKey,
        address indexed borrower,
        uint256 indexed loanId,
        uint256 amount,
        uint256 newLoanTotal,
        uint64 sourceHeight
    );

    error ProofRejected(string reason); // the precompile refused the proof itself
    error WrongChain(uint64 chainKey, uint64 resolvedChainId, uint64 expected);
    error UnsupportedChainKey(uint64 chainKey);
    error SourceReverted();
    error WrongSource(address got, address expected);
    error WrongSelector(bytes4 got, bytes4 expected);
    error Unauthorised(address borrower);
    error Stale(uint256 deadline);
    error Overlong(uint256 deadline);
    error AlreadyPosted(bytes32 sourceTxKey);
    error ZeroAmount();

    constructor(uint64 expectedChainId_, address expectedSource_, bytes4 expectedSelector_, uint256 maxAge_) {
        expectedChainId = expectedChainId_;
        expectedSource = expectedSource_;
        expectedSelector = expectedSelector_;
        maxAge = maxAge_;
    }

    /// Post a proven source-chain repayment to the borrower's history.
    ///
    /// @param chainKey        the source chain's Creditcoin-local key — resolved, never trusted
    /// @param height          the source block height the proof is against
    /// @param encodedTransaction  the proof's txBytes
    function post(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        IBlockProver.MerkleProof calldata merkleProof,
        IBlockProver.ContinuityProof calldata continuityProof
    ) external {
        // 1. CHAIN. Resolve the key to a real chain id before believing anything about it. If the
        //    key names the wrong chain the proof may be perfectly valid and still irrelevant, and we
        //    would rather say so than spend gas proving it.
        IChainInfo.ChainResult memory r = CHAIN_INFO.get_chain_by_key(chainKey);
        if (!r.exists) revert UnsupportedChainKey(chainKey);
        if (r.chain.chainId != expectedChainId) revert WrongChain(chainKey, r.chain.chainId, expectedChainId);

        // 2. PROOF. The precompile reverts rather than returning false, so try is not defensive
        //    styling — it is the only way to tell "this proof is a forgery" apart from "this proof is
        //    fine but the repayment it describes is not one we accept". Those mean different things.
        try PROVER.verify(chainKey, height, encodedTransaction, merkleProof, continuityProof) returns (bool ok) {
            if (!ok) revert ProofRejected("precompile returned false");
        } catch Error(string memory reason) {
            revert ProofRejected(reason);
        } catch {
            revert ProofRejected("precompile reverted without a reason");
        }

        // 3. REPLAY. The encoding carries the signature, so its hash identifies this exact source
        //    transaction. Consume before writing anything, so one repayment cannot be posted twice.
        bytes32 key = keccak256(encodedTransaction);
        if (consumed[key]) revert AlreadyPosted(key);
        consumed[key] = true;

        // 4-7 live in their own frame: above, whether the proof is real; below, what the proven
        // repayment actually was. Only the second half knows the LoanRepayment ABI.
        (address borrower, uint256 loanId, uint256 amount) = _repaymentFrom(encodedTransaction);

        bytes32 loanKey = keccak256(abi.encode(borrower, loanId));
        uint256 newLoanTotal = repaidOnLoan[loanKey] + amount;
        repaidOnLoan[loanKey] = newLoanTotal;
        totalRepaid[borrower] += amount;
        repaymentCount[borrower] += 1;
        emit RepaymentPosted(key, borrower, loanId, amount, newLoanTotal, height);
    }

    /// Read the repayment out of a transaction that has ALREADY been proven genuine. Reverts unless
    /// it succeeded, called repay on the expected LoanRepayment, was sent by the borrower it names,
    /// and is still within its posting window.
    function _repaymentFrom(bytes calldata encodedTransaction)
        internal
        view
        returns (address borrower, uint256 loanId, uint256 amount)
    {
        AttestedTx.Call memory c = AttestedTx.decode(encodedTransaction);

        // 4. STATUS. Inclusion is not success. A repayment whose transfer reverted is still in the
        //    block and still Merkle-provable, and proves only that someone tried to pay.
        if (c.status != 1) revert SourceReverted();

        // 5. SOURCE and 6. SELECTOR.
        if (c.to != expectedSource) revert WrongSource(c.to, expectedSource);
        bytes4 sel = AttestedTx.selector(c);
        if (sel != expectedSelector) revert WrongSelector(sel, expectedSelector);

        // 7. ARGUMENTS, BORROWER and FRESHNESS. The source function is
        //    repay(address borrower, uint256 loanId, uint256 amount, uint256 deadline). The credit
        //    belongs to the account that actually sent the transaction, so a declared borrower that
        //    is not the transaction's sender is an impersonation attempt, not a formatting quirk.
        uint256 deadline;
        (borrower, loanId, amount, deadline) =
            abi.decode(AttestedTx.args(c), (address, uint256, uint256, uint256));
        if (borrower != c.from) revert Unauthorised(borrower);
        // Defence in depth: repaymentCount is incremented per posting, so a zero-amount repayment
        // would inflate a borrower's apparent activity for free. The source contract already refuses
        // this; the book refuses it again so it does not depend on the source to have done so.
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert Stale(deadline);
        if (deadline > block.timestamp + maxAge) revert Overlong(deadline);
    }
}
