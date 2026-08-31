// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {AaveLoanBook} from "../src/AaveLoanBook.sol";
import {IBlockProver, IChainInfo} from "../src/interfaces/IAttestcoin.sol";
import {AttestedTx} from "../src/lib/AttestedTx.sol";

/// The precompiles are Substrate runtime code, so no local or forked EVM has anything at 0x0FD2 or
/// 0x0fD3. Everything here mocks them, which means these tests can say what the BOOK does with a
/// verdict and cannot say anything about the verdict itself — `tools/live-check.mjs` is what checks
/// the precompile assumptions against the real runtime.
///
/// What the tests are NOT mocking is the repayment. Every fixture below is a real `Repay` event
/// emitted by the real Aave V3 Pool on Ethereum Sepolia, captured from the chain: the addresses,
/// amounts and log positions are theirs, not ours. That includes the third-party repayment — one of
/// 81 in the sampled window happened to have `repayer != user`, so the case the book has to get
/// right is not hypothetical.
contract AaveLoanBookTest is Test {
    IBlockProver constant PROVER = IBlockProver(0x0000000000000000000000000000000000000FD2);
    IChainInfo constant CHAIN_INFO = IChainInfo(0x0000000000000000000000000000000000000fD3);

    /// Aave V3 Pool, Ethereum Sepolia.
    address constant POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    uint64 constant SEPOLIA = 11155111;
    uint64 constant CHAIN_KEY = 1; // Sepolia's key on CC3 Testnet — resolved, never assumed
    uint64 constant MAX_AGE_BLOCKS = 50_000;

    bytes32 constant REPAY_TOPIC = 0xa534c8dbe71f871f9f3530e97a74601fea17b426cae02e1c5aee42c96c784051;

    // --- real capture #1: a self-repayment ------------------------------------------------------
    // tx 0x459771511239c999298f0e4c9391cdcf6737977ed6f803f6e5b831eb0bc64b44, block 11565014, log 102
    address constant R1_RESERVE = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // USDC
    address constant R1_USER = 0x3beA90602EaAeC1AFC2500Fb20ba68B72934812e;
    uint256 constant R1_AMOUNT = 30000000; // 30 USDC, 6dp

    // --- real capture #2: someone else paid this borrower's debt --------------------------------
    // tx 0x4b2f5c617939589ec65c4f54460097bad24ca6a79be67934372bd2a1ec7fa0c1
    address constant R2_USER = 0x845E42041aCF2c303914006522E41492c483BF23;
    address constant R2_REPAYER = 0xD2827a89910bC9d7F7687F9350Bb85E2d981B2Bc;
    uint256 constant R2_AMOUNT = 5_000_000;

    uint64 constant TIP = 11603098; // the height CC3 had attested for chainKey 1 when this was written
    uint64 constant H1 = 11565014;

    AaveLoanBook book;

    function setUp() public {
        book = new AaveLoanBook(POOL, SEPOLIA, MAX_AGE_BLOCKS);
        _chainResolves(CHAIN_KEY, SEPOLIA);
        _tipIs(TIP);
        _proofAccepted();
    }

    // =============================================================================================
    // The fact the book is built to act on
    // =============================================================================================

    function test_realSelfRepayment_isCredited() public {
        bytes memory txBytes = _txWithRepay(R1_USER, R1_USER, R1_RESERVE, R1_AMOUNT, 0);
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);

        assertEq(book.totalRepaid(R1_USER), R1_AMOUNT, "credit follows a self-repayment");
        assertEq(book.repaymentCount(R1_USER), 1);
        assertEq(book.repaidByOthers(R1_USER), 0);
    }

    /// The reason `user` and `repayer` are read as two different questions. Aave lets anyone repay
    /// anyone's debt, and in the sampled window someone did. Crediting the borrower for it would let
    /// one funded account manufacture standing for any address it likes.
    function test_thirdPartyRepayment_isRecordedButNotCredited() public {
        bytes memory txBytes = _txWithRepay(R2_USER, R2_REPAYER, R1_RESERVE, R2_AMOUNT, 0);
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);

        assertEq(book.totalRepaid(R2_USER), 0, "a debt someone else paid is not your credit");
        assertEq(book.repaymentCount(R2_USER), 0);
        assertEq(book.repaidByOthers(R2_USER), R2_AMOUNT, "but the proven fact is not discarded");
        assertEq(book.totalRepaid(R2_REPAYER), 0, "nor does the payer get credit for another's debt");
    }

    // =============================================================================================
    // What the book refuses
    // =============================================================================================

    /// Anyone can deploy a contract that emits an event with Aave's signature and have a transaction
    /// calling it proven. The emitter is the binding, not the topic.
    function test_impostorContractEmittingRepay_isRejected() public {
        address impostor = address(0xBAD);
        bytes memory txBytes = _txWithRepayFrom(impostor, R1_USER, R1_USER, R1_RESERVE, R1_AMOUNT, 0);
        vm.expectRevert(abi.encodeWithSelector(AaveLoanBook.WrongEmitter.selector, impostor, POOL));
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);
    }

    /// The right contract, the wrong event.
    function test_differentEventFromThePool_isRejected() public {
        AttestedTx.Log[] memory logs = new AttestedTx.Log[](1);
        logs[0] = _log(POOL, keccak256("Supply(address,address,address,uint256,uint16)"), R1_RESERVE, R1_USER, R1_USER, R1_AMOUNT);
        bytes memory txBytes = _tx(R1_USER, POOL, 1, logs);
        vm.expectRevert(abi.encodeWithSelector(AaveLoanBook.NotARepayEvent.selector, uint256(0)));
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);
    }

    function test_forgedProof_isRejected() public {
        vm.mockCallRevert(
            address(PROVER),
            abi.encodeWithSelector(IBlockProver.verify.selector),
            abi.encodeWithSignature("Error(string)", "Merkle proof validation failed")
        );
        bytes memory txBytes = _txWithRepay(R1_USER, R1_USER, R1_RESERVE, R1_AMOUNT, 0);
        vm.expectRevert(
            abi.encodeWithSelector(AaveLoanBook.ProofRejected.selector, "Merkle proof validation failed")
        );
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);
    }

    function test_revertedSourceTransaction_isRejected() public {
        AttestedTx.Log[] memory logs = new AttestedTx.Log[](1);
        logs[0] = _log(POOL, REPAY_TOPIC, R1_RESERVE, R1_USER, R1_USER, R1_AMOUNT);
        bytes memory txBytes = _tx(R1_USER, POOL, 0 /* status: reverted */, logs);
        vm.expectRevert(AaveLoanBook.SourceReverted.selector);
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);
    }

    function test_proofForTheWrongChain_isRejected() public {
        _chainResolves(CHAIN_KEY, 1); // key 1 resolves to Ethereum mainnet, not Sepolia
        bytes memory txBytes = _txWithRepay(R1_USER, R1_USER, R1_RESERVE, R1_AMOUNT, 0);
        vm.expectRevert(abi.encodeWithSelector(AaveLoanBook.WrongChain.selector, CHAIN_KEY, uint64(1), SEPOLIA));
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);
    }

    function test_zeroAmountRepayment_isRejected() public {
        bytes memory txBytes = _txWithRepay(R1_USER, R1_USER, R1_RESERVE, 0, 0);
        vm.expectRevert(AaveLoanBook.ZeroAmount.selector);
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);
    }

    // =============================================================================================
    // Freshness, in source blocks — there is no timestamp anywhere in an attestation
    // =============================================================================================

    function test_repaymentOlderThanTheWindow_isRejected() public {
        uint64 tooOld = TIP - MAX_AGE_BLOCKS - 1;
        bytes memory txBytes = _txWithRepay(R1_USER, R1_USER, R1_RESERVE, R1_AMOUNT, 0);
        vm.expectRevert(
            abi.encodeWithSelector(AaveLoanBook.TooOld.selector, MAX_AGE_BLOCKS + 1, MAX_AGE_BLOCKS)
        );
        book.post(CHAIN_KEY, tooOld, txBytes, _mp(), _cp(), 0);
    }

    function test_heightAboveTheAttestedTip_isRejected() public {
        bytes memory txBytes = _txWithRepay(R1_USER, R1_USER, R1_RESERVE, R1_AMOUNT, 0);
        vm.expectRevert(abi.encodeWithSelector(AaveLoanBook.FromTheFuture.selector, TIP + 1, TIP));
        book.post(CHAIN_KEY, TIP + 1, txBytes, _mp(), _cp(), 0);
    }

    function test_chainWithNoAttestationYet_isRejected() public {
        vm.mockCall(
            address(CHAIN_INFO),
            abi.encodeWithSelector(IChainInfo.get_latest_attestation_height_and_hash.selector),
            abi.encode(IChainInfo.HeightHashResult(0, bytes32(0), false, false))
        );
        bytes memory txBytes = _txWithRepay(R1_USER, R1_USER, R1_RESERVE, R1_AMOUNT, 0);
        vm.expectRevert(abi.encodeWithSelector(AaveLoanBook.NotYetAttested.selector, CHAIN_KEY));
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);
    }

    // =============================================================================================
    // Replay, keyed per LOG — the change a foreign source forces
    // =============================================================================================

    /// One transaction, two borrowers. A book keyed on the transaction hash records the first and
    /// silently loses the second.
    function test_twoRepaymentsInOneTransaction_areBothPosted() public {
        AttestedTx.Log[] memory logs = new AttestedTx.Log[](2);
        logs[0] = _log(POOL, REPAY_TOPIC, R1_RESERVE, R1_USER, R1_USER, R1_AMOUNT);
        logs[1] = _log(POOL, REPAY_TOPIC, R1_RESERVE, R2_USER, R2_USER, R2_AMOUNT);
        bytes memory txBytes = _tx(R1_USER, POOL, 1, logs);

        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 1);

        assertEq(book.totalRepaid(R1_USER), R1_AMOUNT);
        assertEq(book.totalRepaid(R2_USER), R2_AMOUNT, "the second repayment is not lost");
    }

    function test_sameLogPostedTwice_isRejected() public {
        bytes memory txBytes = _txWithRepay(R1_USER, R1_USER, R1_RESERVE, R1_AMOUNT, 0);
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);

        bytes32 key = keccak256(abi.encode(CHAIN_KEY, H1, keccak256(txBytes), uint256(0)));
        vm.expectRevert(abi.encodeWithSelector(AaveLoanBook.AlreadyPosted.selector, key));
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 0);

        assertEq(book.totalRepaid(R1_USER), R1_AMOUNT, "and the total did not double");
    }

    function test_logIndexPastTheEnd_isRejected() public {
        bytes memory txBytes = _txWithRepay(R1_USER, R1_USER, R1_RESERVE, R1_AMOUNT, 0);
        vm.expectRevert(abi.encodeWithSelector(AaveLoanBook.NoSuchLog.selector, uint256(7)));
        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 7);
    }

    /// A repayment routed through an aggregator has some other contract as the transaction's callee.
    /// The book accepts it, because the Pool still emitted the event and nothing else can.
    function test_repaymentRoutedThroughAnAggregator_isAccepted() public {
        AttestedTx.Log[] memory logs = new AttestedTx.Log[](3);
        logs[0] = _log(address(0xF00D), keccak256("Swap(address,uint256)"), R1_RESERVE, R1_USER, R1_USER, 1);
        logs[1] = _log(POOL, REPAY_TOPIC, R1_RESERVE, R1_USER, R1_USER, R1_AMOUNT);
        logs[2] = _log(address(0xF00D), keccak256("Done()"), R1_RESERVE, R1_USER, R1_USER, 1);
        bytes memory txBytes = _tx(R1_USER, address(0xF00D) /* callee is NOT the pool */, 1, logs);

        book.post(CHAIN_KEY, H1, txBytes, _mp(), _cp(), 1);
        assertEq(book.totalRepaid(R1_USER), R1_AMOUNT);
    }

    // =============================================================================================
    // helpers
    // =============================================================================================

    function _proofAccepted() internal {
        vm.mockCall(address(PROVER), abi.encodeWithSelector(IBlockProver.verify.selector), abi.encode(true));
    }

    function _chainResolves(uint64 key, uint64 chainId) internal {
        vm.mockCall(
            address(CHAIN_INFO),
            abi.encodeWithSelector(IChainInfo.get_chain_by_key.selector, key),
            abi.encode(IChainInfo.ChainResult(IChainInfo.Chain(key, chainId, "sepolia", 0), true))
        );
    }

    function _tipIs(uint64 height) internal {
        vm.mockCall(
            address(CHAIN_INFO),
            abi.encodeWithSelector(IChainInfo.get_latest_attestation_height_and_hash.selector),
            abi.encode(IChainInfo.HeightHashResult(height, bytes32(uint256(1)), true, true))
        );
    }

    function _log(address emitter, bytes32 topic0, address reserve, address user, address repayer, uint256 amount)
        internal
        pure
        returns (AttestedTx.Log memory l)
    {
        l.addr = emitter;
        l.topics = new bytes32[](4);
        l.topics[0] = topic0;
        l.topics[1] = bytes32(uint256(uint160(reserve)));
        l.topics[2] = bytes32(uint256(uint160(user)));
        l.topics[3] = bytes32(uint256(uint160(repayer)));
        l.data = abi.encode(amount, false); // (uint256 amount, bool useATokens)
    }

    function _txWithRepay(address user, address repayer, address reserve, uint256 amount, uint256 pad)
        internal
        pure
        returns (bytes memory)
    {
        AttestedTx.Log[] memory logs = new AttestedTx.Log[](1 + pad);
        logs[pad] = _log(POOL, REPAY_TOPIC, reserve, user, repayer, amount);
        return _tx(user, POOL, 1, logs);
    }

    function _txWithRepayFrom(
        address emitter,
        address user,
        address repayer,
        address reserve,
        uint256 amount,
        uint256 pad
    ) internal pure returns (bytes memory) {
        AttestedTx.Log[] memory logs = new AttestedTx.Log[](1 + pad);
        logs[pad] = _log(emitter, REPAY_TOPIC, reserve, user, repayer, amount);
        return _tx(user, emitter, 1, logs);
    }

    /// The `(uint8 txType, bytes[] chunks)` envelope the precompile verifies. Four chunks, so the
    /// receipt is not at index 2 — indexing from the end is the only thing that works across types.
    function _tx(address from, address to, uint8 status, AttestedTx.Log[] memory logs)
        internal
        pure
        returns (bytes memory)
    {
        bytes[] memory chunks = new bytes[](4);
        chunks[0] = abi.encode(uint64(42), uint64(21000), from, false, to, uint256(0), bytes(""));
        chunks[1] = abi.encode(uint64(11155111), uint128(1 gwei), uint128(2 gwei), bytes32(0));
        chunks[2] = abi.encode(uint64(0), bytes32(0));
        chunks[3] = abi.encode(status, uint64(21000), logs, bytes(hex"00"));
        return abi.encode(uint8(2), chunks);
    }

    function _mp() internal pure returns (IBlockProver.MerkleProof memory p) {
        p.root = bytes32(uint256(1));
        p.siblings = new IBlockProver.MerkleSibling[](0);
    }

    function _cp() internal pure returns (IBlockProver.ContinuityProof memory p) {
        p.lowerEndpointDigest = bytes32(uint256(2));
        p.roots = new bytes32[](0);
    }
}
