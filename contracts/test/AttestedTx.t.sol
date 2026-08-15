// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {AttestedTx} from "../src/lib/AttestedTx.sol";

/// Checks the decoder against a real attested Sepolia transaction.
///
/// The fixture is captured by `tools/capture-fixture.mjs`, and the `expected` fields in it come
/// from a Sepolia RPC rather than from the encoder. That independence is the whole point: this
/// library was written by reading the encoder's source, so agreement with data the same source
/// produced would prove only that we are self-consistent. Agreement with what Ethereum says the
/// transaction was is the claim worth making.
///
/// Regenerate with `node tools/capture-fixture.mjs` (no key, no gas).
contract AttestedTxTest is Test {
    using AttestedTx for AttestedTx.Call;

    string constant FIXTURE = "test/fixtures/sepolia-call.json";

    bytes txBytes;
    address expFrom;
    address expTo;
    uint256 expValue;
    uint256 expNonce;
    uint256 expStatus;
    uint256 expTxType;
    uint256 expChunks;
    bytes4 expSelector;

    function setUp() public {
        string memory j = vm.readFile(FIXTURE);
        txBytes = vm.parseJsonBytes(j, ".txBytes");
        expFrom = vm.parseJsonAddress(j, ".expected.from");
        expTo = vm.parseJsonAddress(j, ".expected.to");
        expValue = vm.parseJsonUint(j, ".expected.value");
        expNonce = vm.parseJsonUint(j, ".expected.nonce");
        expStatus = vm.parseJsonUint(j, ".expected.status");
        expTxType = vm.parseJsonUint(j, ".envelopeTxType");
        expChunks = vm.parseJsonUint(j, ".chunkCount");
        expSelector = bytes4(vm.parseJsonBytes(j, ".expected.selector"));
    }

    /// Exposes the internal library to `this.` so expectRevert can catch its errors.
    function decode(bytes calldata b) external pure returns (AttestedTx.Call memory) {
        return AttestedTx.decode(b);
    }

    function test_decodesRealTransactionMatchingEthereum() public view {
        AttestedTx.Call memory c = this.decode(txBytes);
        assertEq(c.from, expFrom, "from");
        assertEq(c.to, expTo, "to");
        assertEq(c.value, expValue, "value");
        assertEq(uint256(c.nonce), expNonce, "nonce");
        assertEq(uint256(c.status), expStatus, "status");
        assertEq(uint256(c.txType), expTxType, "txType");
    }

    function test_extractsSelectorOfRealTransaction() public view {
        AttestedTx.Call memory c = this.decode(txBytes);
        assertEq(c.selector(), expSelector, "selector");
        // Arguments are whatever follows the selector; the decoder must not lose or pad them.
        assertEq(c.args().length, c.data.length - 4, "args length");
    }

    /// The envelope is `(uint8, bytes[])`. Decoding it as `bytes[]` — which is exactly what the
    /// SDK's own documentation tells you to do — fails on real data. Pinned so that if a future
    /// encoder version changes the envelope, this test is what tells us.
    function test_envelopeIsNotBareBytesArray() public {
        vm.expectRevert();
        this.decodeAsBareArray(txBytes);
    }

    function decodeAsBareArray(bytes calldata b) external pure returns (uint256) {
        return abi.decode(b, (bytes[])).length;
    }

    /// Legacy, access-list and EIP-1559 transactions produce three chunks; blob transactions
    /// produce four. A consumer that reads the receipt as `chunks[2]` passes every test written
    /// against an ordinary transaction and misreads a blob one, so the decoder indexes from the end.
    function test_chunkCountIsNotFixedAtThree() public view {
        (, bytes[] memory chunks) = abi.decode(txBytes, (uint8, bytes[]));
        assertEq(chunks.length, expChunks, "chunk count");
        assertGe(chunks.length, 3, "at least common + type-specific + receipt");
    }

    function test_rejectsTruncatedEnvelope() public {
        vm.expectRevert();
        this.decode(hex"deadbeef");
    }
}
