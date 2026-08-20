// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {AttestedLoanBook} from "../src/AttestedLoanBook.sol";
import {IBlockProver, IChainInfo} from "../src/interfaces/IAttestcoin.sol";
import {AttestedTx} from "../src/lib/AttestedTx.sol";

/// Every way we know of to make the book record a repayment that should not count.
///
/// The precompiles are mocked here, deliberately. Some of these attacks cannot be staged against a
/// live chain at all — a proof that is genuinely valid for a repayment whose transfer reverted
/// requires finding such a transaction and paying to prove it, and "the precompile said yes but the
/// repayment is worthless" is exactly the case a credit history most needs pinned. Mocking the proof
/// step lets each check be exercised in isolation, so a failure names one defect rather than a
/// tangle.
///
/// The risk of mocking is testing our own assumptions back to ourselves. Two things guard against
/// it. The decoder is validated separately against a real attested transaction and Ethereum's own
/// record of it (`AttestedTx.t.sol`), so the envelopes built below are built to a shape that has
/// been checked against reality. And `tools/live-check.mjs` re-asserts, against the live CC3
/// runtime, every precompile behaviour the mocks below encode — that a refusal is a catchable
/// revert rather than a `false`, and what each chainKey really resolves to. Fork tests cannot do
/// this: the precompiles are Substrate runtime code, so a forked node has no code at 0x0FD2 and
/// calls to it succeed silently.
contract AttacksTest is Test {
    AttestedLoanBook book;

    IBlockProver constant PROVER = IBlockProver(0x0000000000000000000000000000000000000FD2);
    IChainInfo constant CHAIN_INFO = IChainInfo(0x0000000000000000000000000000000000000fD3);

    uint64 constant SEPOLIA_CHAIN_ID = 11155111;
    uint64 constant SEPOLIA_KEY = 1; // on CC3 Testnet. On CC3 Mainnet, key 1 is Ethereum.
    uint64 constant MAINNET_KEY = 3;
    uint64 constant HEIGHT = 11490830;
    uint256 constant MAX_AGE = 1 days;
    uint256 constant LOAN = 7;

    address constant SOURCE = 0xD015239D9E25DDF00C7F855660f25A9360904E15; // the LoanRepayment contract
    address constant BORROWER = 0x349769ac0BeeF5d5A5d46386F10C147761D6C0B6;
    bytes4 constant REPAY = bytes4(keccak256("repay(address,uint256,uint256,uint256)"));

    IBlockProver.MerkleProof mp;
    IBlockProver.ContinuityProof cp;

    function setUp() public {
        book = new AttestedLoanBook(SEPOLIA_CHAIN_ID, SOURCE, REPAY, MAX_AGE);
        mp.root = bytes32(uint256(1));
        cp.lowerEndpointDigest = bytes32(uint256(2));
        _chainResolves(SEPOLIA_KEY, SEPOLIA_CHAIN_ID);
        _proofAccepted();
        vm.warp(1_800_000_000);
    }

    function _loanKey(address borrower, uint256 loanId) internal pure returns (bytes32) {
        return keccak256(abi.encode(borrower, loanId));
    }

    // --- the honest path ------------------------------------------------------------------

    function test_validRepaymentIsPosted() public {
        bytes memory txb = _repayTx(BORROWER, LOAN, 500, block.timestamp + 1 hours);
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
        assertEq(book.totalRepaid(BORROWER), 500, "credit history");
        assertEq(book.repaidOnLoan(_loanKey(BORROWER, LOAN)), 500, "per-loan total");
        assertEq(book.repaymentCount(BORROWER), 1, "count");
        assertTrue(book.consumed(keccak256(txb)), "consumed");
    }

    /// Blob transactions encode four chunks instead of three. A consumer that reads the receipt as
    /// `chunks[2]` would read type-specific fields as a receipt here; the book must not care.
    function test_validRepaymentInABlobTransaction() public {
        bytes memory txb = _tx(BORROWER, SOURCE, 0, _repayCalldata(BORROWER, LOAN, 7, block.timestamp + 1 hours), 1, 3, 4);
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
        assertEq(book.totalRepaid(BORROWER), 7, "posted from a 4-chunk transaction");
    }

    // --- attacks on the proof itself ------------------------------------------------------

    /// The precompile reverts rather than returning false. The book has to surface that as its own
    /// named error, or callers cannot tell a forgery from a rejected repayment.
    function test_forgedProof_isRejectedWithReason() public {
        vm.mockCallRevert(
            address(PROVER),
            abi.encodeWithSelector(IBlockProver.verify.selector),
            abi.encodeWithSignature("Error(string)", "Merkle proof validation failed")
        );
        bytes memory txb = _repayTx(BORROWER, LOAN, 500, block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(AttestedLoanBook.ProofRejected.selector, "Merkle proof validation failed")
        );
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    function test_proofRevertingWithoutReason_isStillRejected() public {
        vm.mockCallRevert(address(PROVER), abi.encodeWithSelector(IBlockProver.verify.selector), "");
        bytes memory txb = _repayTx(BORROWER, LOAN, 500, block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(AttestedLoanBook.ProofRejected.selector, "precompile reverted without a reason")
        );
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// Today the precompile reverts. If a future version honours its documented `false`, the book
    /// must not read that as success.
    function test_proofReturningFalse_isRejected() public {
        vm.mockCall(address(PROVER), abi.encodeWithSelector(IBlockProver.verify.selector), abi.encode(false));
        bytes memory txb = _repayTx(BORROWER, LOAN, 500, block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(AttestedLoanBook.ProofRejected.selector, "precompile returned false")
        );
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    // --- attacks on which chain the fact came from ----------------------------------------

    /// The sharpest one. `chainKey` is environment-scoped: key 3 on CC3 Testnet is Ethereum
    /// mainnet. A perfectly valid mainnet proof must not satisfy a book bound to Sepolia — and a
    /// book that compared `chainKey` instead of `chainId` would accept it after promotion.
    function test_validProofFromTheWrongChain_isRejected() public {
        _chainResolves(MAINNET_KEY, 1);
        bytes memory txb = _repayTx(BORROWER, LOAN, 500, block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(AttestedLoanBook.WrongChain.selector, MAINNET_KEY, uint64(1), SEPOLIA_CHAIN_ID)
        );
        book.post(MAINNET_KEY, HEIGHT, txb, mp, cp);
    }

    function test_unknownChainKey_isRejected() public {
        vm.mockCall(
            address(CHAIN_INFO),
            abi.encodeWithSelector(IChainInfo.get_chain_by_key.selector, uint64(99)),
            abi.encode(IChainInfo.ChainResult(IChainInfo.Chain(0, 0, "", 0), false))
        );
        bytes memory txb = _repayTx(BORROWER, LOAN, 500, block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(AttestedLoanBook.UnsupportedChainKey.selector, uint64(99)));
        book.post(99, HEIGHT, txb, mp, cp);
    }

    // --- attacks on what the proven transaction actually says ------------------------------

    /// Inclusion is not success. A repayment whose transfer reverted sits in the block and proves
    /// perfectly — it must not be posted as if the borrower paid.
    function test_provenButRevertedRepayment_isRejected() public {
        bytes memory txb =
            _tx(BORROWER, SOURCE, 0, _repayCalldata(BORROWER, LOAN, 500, block.timestamp + 1 hours), 0, 2, 3);
        vm.expectRevert(AttestedLoanBook.SourceReverted.selector);
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    function test_repaymentToAnImpostorContract_isRejected() public {
        address evil = address(0xBAD);
        bytes memory txb = _tx(BORROWER, evil, 0, _repayCalldata(BORROWER, LOAN, 500, block.timestamp + 1 hours), 1, 2, 3);
        vm.expectRevert(abi.encodeWithSelector(AttestedLoanBook.WrongSource.selector, evil, SOURCE));
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// The right contract, the wrong function. Everything else about this transaction is genuine.
    function test_differentFunctionOnTheRightContract_isRejected() public {
        bytes4 other = bytes4(keccak256("draw(uint256)"));
        bytes memory data = abi.encodeWithSelector(other, BORROWER, LOAN, uint256(500), block.timestamp + 1 hours);
        bytes memory txb = _tx(BORROWER, SOURCE, 0, data, 1, 2, 3);
        vm.expectRevert(abi.encodeWithSelector(AttestedLoanBook.WrongSelector.selector, other, REPAY));
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// Impersonation: a real repayment transaction, sent by an attacker, naming someone else as the
    /// borrower to credit their history. Only the transaction's own sender earns the credit.
    function test_creditingSomeoneElsesHistory_isRejected() public {
        address attacker = address(0xA77ACC);
        bytes memory txb =
            _tx(attacker, SOURCE, 0, _repayCalldata(BORROWER, LOAN, 500, block.timestamp + 1 hours), 1, 2, 3);
        vm.expectRevert(abi.encodeWithSelector(AttestedLoanBook.Unauthorised.selector, BORROWER));
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// Defence in depth: even a genuinely-proven repay of zero must not be posted, because the book
    /// increments repaymentCount per posting and a free zero would inflate a borrower's activity.
    function test_zeroAmountRepayment_isRejected() public {
        bytes memory txb = _repayTx(BORROWER, LOAN, 0, block.timestamp + 1 hours);
        vm.expectRevert(AttestedLoanBook.ZeroAmount.selector);
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    // --- attacks on time and repetition ----------------------------------------------------

    /// An attested repayment stays provable forever. The right to post it must not.
    function test_expiredRepayment_isRejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory txb = _repayTx(BORROWER, LOAN, 500, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(AttestedLoanBook.Stale.selector, deadline));
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// The borrower picks the deadline, so the borrower can pick forever. The book bounds it.
    function test_repaymentPostableForeverIsRefused() public {
        uint256 deadline = type(uint256).max;
        bytes memory txb = _repayTx(BORROWER, LOAN, 500, deadline);
        vm.expectRevert(abi.encodeWithSelector(AttestedLoanBook.Overlong.selector, deadline));
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// Post the same proof twice and the history would double-count. The replay guard forbids it.
    function test_replayingTheSameProof_isRejected() public {
        bytes memory txb = _repayTx(BORROWER, LOAN, 500, block.timestamp + 1 hours);
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
        vm.expectRevert(abi.encodeWithSelector(AttestedLoanBook.AlreadyPosted.selector, keccak256(txb)));
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// Replay is keyed on the transaction, not the borrower: the same borrower may make a second
    /// distinct repayment, and a book that keyed on the borrower would silently drop it.
    function test_aSecondDistinctRepaymentIsPosted() public {
        book.post(SEPOLIA_KEY, HEIGHT, _repayTx(BORROWER, LOAN, 500, block.timestamp + 1 hours), mp, cp);
        // Different nonce -> different transaction -> different key.
        bytes memory second =
            _tx(BORROWER, SOURCE, 0, _repayCalldata(BORROWER, LOAN, 250, block.timestamp + 1 hours), 1, 2, 3, 99);
        book.post(SEPOLIA_KEY, HEIGHT, second, mp, cp);
        assertEq(book.totalRepaid(BORROWER), 750, "both repayments credited");
        assertEq(book.repaidOnLoan(_loanKey(BORROWER, LOAN)), 750, "both on the same loan");
        assertEq(book.repaymentCount(BORROWER), 2, "two repayments");
    }

    /// Contract creations have no callee, so no source binding is possible.
    function test_contractCreation_isRejected() public {
        bytes memory txb = _tx(BORROWER, address(0), 0, _repayCalldata(BORROWER, LOAN, 1, block.timestamp + 1 hours), 1, 2, 3);
        vm.expectRevert(AttestedTx.ContractCreation.selector);
        book.post(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    // --- helpers ---------------------------------------------------------------------------

    function _chainResolves(uint64 key, uint64 chainId) internal {
        vm.mockCall(
            address(CHAIN_INFO),
            abi.encodeWithSelector(IChainInfo.get_chain_by_key.selector, key),
            abi.encode(IChainInfo.ChainResult(IChainInfo.Chain(key, chainId, "", 1), true))
        );
    }

    function _proofAccepted() internal {
        vm.mockCall(address(PROVER), abi.encodeWithSelector(IBlockProver.verify.selector), abi.encode(true));
    }

    function _repayCalldata(address borrower, uint256 loanId, uint256 amount, uint256 deadline)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(REPAY, borrower, loanId, amount, deadline);
    }

    function _repayTx(address borrower, uint256 loanId, uint256 amount, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _tx(borrower, SOURCE, 0, _repayCalldata(borrower, loanId, amount, deadline), 1, 2, 3);
    }

    function _tx(
        address from,
        address to,
        uint256 value,
        bytes memory data,
        uint8 status,
        uint8 txType,
        uint256 chunkCount
    ) internal pure returns (bytes memory) {
        return _tx(from, to, value, data, status, txType, chunkCount, 42);
    }

    /// Build the `(uint8 txType, bytes[] chunks)` envelope the precompile verifies.
    /// The middle chunks are type-specific fields the book never reads; only their presence and
    /// count matter, which is precisely what makes indexing the receipt from the end necessary.
    function _tx(
        address from,
        address to,
        uint256 value,
        bytes memory data,
        uint8 status,
        uint8 txType,
        uint256 chunkCount,
        uint64 nonce
    ) internal pure returns (bytes memory) {
        require(chunkCount >= 3, "an envelope has at least common + type-specific + receipt");
        bytes[] memory chunks = new bytes[](chunkCount);
        chunks[0] = abi.encode(nonce, uint64(21000), from, to == address(0), to, value, data);
        for (uint256 i = 1; i < chunkCount - 1; i++) {
            chunks[i] = abi.encode(uint64(11155111), uint128(1 gwei), uint128(2 gwei), bytes32(0));
        }
        chunks[chunkCount - 1] = abi.encode(status, uint64(21000), new AttestedTx.Log[](0), bytes(hex"00"));
        return abi.encode(txType, chunks);
    }
}
