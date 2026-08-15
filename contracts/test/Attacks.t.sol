// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {AttestedGovernor} from "../src/AttestedGovernor.sol";
import {IBlockProver, IChainInfo} from "../src/interfaces/IAttestcoin.sol";
import {AttestedTx} from "../src/lib/AttestedTx.sol";

/// Every way we know of to make the governor act on something it should refuse.
///
/// The precompiles are mocked here, deliberately. Some of these attacks cannot be staged against a
/// live chain at all — a proof that is genuinely valid *for a transaction that reverted* requires
/// finding such a transaction and paying to prove it, and "the precompile said yes but the
/// authorisation is worthless" is exactly the case a consumer most needs pinned. Mocking the proof
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
    AttestedGovernor gov;

    IBlockProver constant PROVER = IBlockProver(0x0000000000000000000000000000000000000FD2);
    IChainInfo constant CHAIN_INFO = IChainInfo(0x0000000000000000000000000000000000000fD3);

    uint64 constant SEPOLIA_CHAIN_ID = 11155111;
    uint64 constant SEPOLIA_KEY = 1; // on CC3 Testnet. On CC3 Mainnet, key 1 is Ethereum.
    uint64 constant MAINNET_KEY = 3;
    uint64 constant HEIGHT = 11490830;
    uint256 constant MAX_AGE = 1 days;

    address constant SOURCE = 0xD015239D9E25DDF00C7F855660f25A9360904E15;
    address constant ACTOR = 0x349769ac0BeeF5d5A5d46386F10C147761D6C0B6;
    bytes4 constant AUTHORISE = bytes4(keccak256("authorise(address,uint256,uint256)"));

    // Proof structs. Their contents are irrelevant while the prover is mocked — what is being
    // tested is what the governor does with the *decoded transaction*, given a prover verdict.
    IBlockProver.MerkleProof mp;
    IBlockProver.ContinuityProof cp;

    function setUp() public {
        gov = new AttestedGovernor(SEPOLIA_CHAIN_ID, SOURCE, AUTHORISE, MAX_AGE);
        mp.root = bytes32(uint256(1));
        cp.lowerEndpointDigest = bytes32(uint256(2));
        _chainResolves(SEPOLIA_KEY, SEPOLIA_CHAIN_ID);
        _proofAccepted();
        vm.warp(1_800_000_000);
    }

    // --- the honest path ------------------------------------------------------------------

    function test_validAuthorisationIsExecuted() public {
        bytes memory txb = _authTx(ACTOR, 500, block.timestamp + 1 hours);
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
        assertEq(gov.credited(ACTOR), 500, "credited");
        assertTrue(gov.consumed(keccak256(txb)), "consumed");
    }

    /// Blob transactions encode four chunks instead of three. A consumer that reads the receipt as
    /// `chunks[2]` would read type-specific fields as a receipt here; the governor must not care.
    function test_validAuthorisationInABlobTransaction() public {
        bytes memory txb = _tx(ACTOR, SOURCE, 0, _authCalldata(ACTOR, 7, block.timestamp + 1 hours), 1, 3, 4);
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
        assertEq(gov.credited(ACTOR), 7, "credited from a 4-chunk transaction");
    }

    // --- attacks on the proof itself ------------------------------------------------------

    /// The precompile reverts rather than returning false. The governor has to surface that as its
    /// own named error, or callers cannot tell a forgery from a rejected authorisation.
    function test_forgedProof_isRejectedWithReason() public {
        vm.mockCallRevert(
            address(PROVER),
            abi.encodeWithSelector(IBlockProver.verify.selector),
            abi.encodeWithSignature("Error(string)", "Merkle proof validation failed")
        );
        bytes memory txb = _authTx(ACTOR, 500, block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(AttestedGovernor.ProofRejected.selector, "Merkle proof validation failed")
        );
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    function test_proofRevertingWithoutReason_isStillRejected() public {
        vm.mockCallRevert(address(PROVER), abi.encodeWithSelector(IBlockProver.verify.selector), "");
        bytes memory txb = _authTx(ACTOR, 500, block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                AttestedGovernor.ProofRejected.selector, "precompile reverted without a reason"
            )
        );
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// Today the precompile reverts. If a future version honours its documented `false`, the
    /// governor must not read that as success.
    function test_proofReturningFalse_isRejected() public {
        vm.mockCall(address(PROVER), abi.encodeWithSelector(IBlockProver.verify.selector), abi.encode(false));
        bytes memory txb = _authTx(ACTOR, 500, block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(AttestedGovernor.ProofRejected.selector, "precompile returned false")
        );
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    // --- attacks on which chain the fact came from ----------------------------------------

    /// The sharpest one. `chainKey` is environment-scoped: key 3 on CC3 Testnet is Ethereum
    /// mainnet. A perfectly valid mainnet proof must not satisfy a governor bound to Sepolia — and
    /// a governor that compared `chainKey` instead of `chainId` would accept it after promotion.
    function test_validProofFromTheWrongChain_isRejected() public {
        _chainResolves(MAINNET_KEY, 1);
        bytes memory txb = _authTx(ACTOR, 500, block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(AttestedGovernor.WrongChain.selector, MAINNET_KEY, uint64(1), SEPOLIA_CHAIN_ID)
        );
        gov.execute(MAINNET_KEY, HEIGHT, txb, mp, cp);
    }

    function test_unknownChainKey_isRejected() public {
        vm.mockCall(
            address(CHAIN_INFO),
            abi.encodeWithSelector(IChainInfo.get_chain_by_key.selector, uint64(99)),
            abi.encode(IChainInfo.ChainResult(IChainInfo.Chain(0, 0, "", 0), false))
        );
        bytes memory txb = _authTx(ACTOR, 500, block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(AttestedGovernor.UnsupportedChainKey.selector, uint64(99)));
        gov.execute(99, HEIGHT, txb, mp, cp);
    }

    // --- attacks on what the proven transaction actually says ------------------------------

    /// Inclusion is not success. A reverted transaction sits in the block and proves perfectly.
    function test_provenButRevertedSourceTransaction_isRejected() public {
        bytes memory txb =
            _tx(ACTOR, SOURCE, 0, _authCalldata(ACTOR, 500, block.timestamp + 1 hours), 0, 2, 3);
        vm.expectRevert(AttestedGovernor.SourceReverted.selector);
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    function test_authorisationFromAnImpostorContract_isRejected() public {
        address evil = address(0xBAD);
        bytes memory txb = _tx(ACTOR, evil, 0, _authCalldata(ACTOR, 500, block.timestamp + 1 hours), 1, 2, 3);
        vm.expectRevert(abi.encodeWithSelector(AttestedGovernor.WrongSource.selector, evil, SOURCE));
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// The right contract, the wrong function. Everything else about this transaction is genuine.
    function test_differentFunctionOnTheRightContract_isRejected() public {
        bytes4 other = bytes4(keccak256("revoke(address)"));
        bytes memory data = abi.encodeWithSelector(other, ACTOR, uint256(500), block.timestamp + 1 hours);
        bytes memory txb = _tx(ACTOR, SOURCE, 0, data, 1, 2, 3);
        vm.expectRevert(abi.encodeWithSelector(AttestedGovernor.WrongSelector.selector, other, AUTHORISE));
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// Impersonation: a real transaction, sent by an attacker, naming someone else as the actor.
    /// Only the transaction's own sender carries authority.
    function test_authorisingSomeoneElse_isRejected() public {
        address attacker = address(0xA77ACC);
        bytes memory txb =
            _tx(attacker, SOURCE, 0, _authCalldata(ACTOR, 500, block.timestamp + 1 hours), 1, 2, 3);
        vm.expectRevert(abi.encodeWithSelector(AttestedGovernor.Unauthorised.selector, ACTOR));
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    // --- attacks on time and repetition ----------------------------------------------------

    /// An attested fact stays provable forever. Authority must not.
    function test_expiredAuthorisation_isRejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory txb = _authTx(ACTOR, 500, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(AttestedGovernor.Stale.selector, deadline));
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// The grantor picks the deadline, so the grantor can pick forever. The consumer bounds it.
    function test_authorisationValidForeverIsRefused() public {
        uint256 deadline = type(uint256).max;
        bytes memory txb = _authTx(ACTOR, 500, deadline);
        vm.expectRevert(abi.encodeWithSelector(AttestedGovernor.Overlong.selector, deadline));
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    function test_replayingTheSameProof_isRejected() public {
        bytes memory txb = _authTx(ACTOR, 500, block.timestamp + 1 hours);
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
        vm.expectRevert(abi.encodeWithSelector(AttestedGovernor.AlreadyConsumed.selector, keccak256(txb)));
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
    }

    /// Replay is keyed on the transaction, not the actor: the same actor may authorise twice, and
    /// a consumer that keyed on the sender would silently drop the second grant.
    function test_aSecondDistinctAuthorisationFromTheSameActorIsAccepted() public {
        gov.execute(SEPOLIA_KEY, HEIGHT, _authTx(ACTOR, 500, block.timestamp + 1 hours), mp, cp);
        // Different nonce -> different transaction -> different key.
        bytes memory second =
            _tx(ACTOR, SOURCE, 0, _authCalldata(ACTOR, 250, block.timestamp + 1 hours), 1, 2, 3, 99);
        gov.execute(SEPOLIA_KEY, HEIGHT, second, mp, cp);
        assertEq(gov.credited(ACTOR), 750, "both grants credited");
    }

    /// Contract creations have no callee, so no source binding is possible.
    function test_contractCreation_isRejected() public {
        bytes memory txb = _tx(ACTOR, address(0), 0, _authCalldata(ACTOR, 1, block.timestamp + 1 hours), 1, 2, 3);
        vm.expectRevert(AttestedTx.ContractCreation.selector);
        gov.execute(SEPOLIA_KEY, HEIGHT, txb, mp, cp);
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

    function _authCalldata(address actor, uint256 amount, uint256 deadline) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(AUTHORISE, actor, amount, deadline);
    }

    function _authTx(address actor, uint256 amount, uint256 deadline) internal view returns (bytes memory) {
        return _tx(actor, SOURCE, 0, _authCalldata(actor, amount, deadline), 1, 2, 3);
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
    /// The middle chunks are type-specific fields the governor never reads; only their presence and
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
        chunks[chunkCount - 1] =
            abi.encode(status, uint64(21000), new AttestedTx.Log[](0), bytes(hex"00"));
        return abi.encode(txType, chunks);
    }
}
