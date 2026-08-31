// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// Decodes the `bytes[]` transaction encoding that Attestcoin's BlockProver precompile verifies.
///
/// The envelope is `(uint8 txType, bytes[] chunks)` — NOT `bytes[]`, whatever the SDK says. Its own
/// `encoding/abi/v1` documentation instructs you to decode with "Type: `bytes[]`", and the
/// implementation three lines below that comment encodes `['uint8', 'bytes[]']`. A consumer written
/// from the documentation cannot decode a single real transaction; we only found this by dumping
/// the bytes a live proof actually contained. The leading `uint8` is the transaction type, and it
/// is there deliberately so the type can be read without decoding the rest.
///
/// Inside, the chunks are:
///
///   chunks[0]        common fields, IDENTICAL for every transaction type
///   chunks[1..n-2]   type-specific fields (gas pricing, access list, signature, blob hashes …)
///   chunks[n-1]      the receipt
///
/// Two consequences shape everything below.
///
/// First, a consumer never has to branch on transaction type: every field an authorisation check
/// cares about — sender, callee, calldata, value — lives in chunk 0, and the receipt is always last.
///
/// Second, the chunk *count* is not fixed. Legacy, access-list and EIP-1559 transactions produce
/// three chunks; blob transactions produce four; EIP-7702 more. Reading the receipt as `chunks[2]`
/// works on every transaction you are likely to test with and silently misreads a blob transaction.
/// Always index from the end.
library AttestedTx {
    /// The subset of a proven source transaction an authorisation decision may rest on.
    struct Call {
        address from; // the source-chain actor whose authority this is
        address to; // the source contract that was called
        uint256 value;
        bytes data; // selector ++ arguments
        uint64 nonce;
        uint8 status; // 1 == success. Attestcoin proves inclusion, NOT success.
        uint8 txType; // 0 legacy, 1 access-list, 2 EIP-1559, 3 blob, 4 EIP-7702
        Log[] logs; // the receipt's events — the only readable account of what a foreign contract did
    }

    error NoChunks();
    error NoReceipt();
    error ContractCreation();

    /// Decode the encoded transaction the precompile just verified.
    /// @param encodedTransaction the `txBytes` field of a proof, ABI-encoded as `bytes[]`.
    function decode(bytes calldata encodedTransaction) internal pure returns (Call memory c) {
        bytes[] memory chunks;
        (c.txType, chunks) = abi.decode(encodedTransaction, (uint8, bytes[]));
        // Two chunks is already impossible (common + type-specific + receipt is the minimum), but
        // the arithmetic below underflows on an empty array, so bound it explicitly.
        if (chunks.length < 2) revert NoChunks();

        bool toIsNull;
        uint64 gasLimit;
        (c.nonce, gasLimit, c.from, toIsNull, c.to, c.value, c.data) =
            abi.decode(chunks[0], (uint64, uint64, address, bool, address, uint256, bytes));

        // A contract creation has no callee, so no source-contract binding is possible and every
        // check downstream would compare against address(0). Refuse rather than silently pass.
        if (toIsNull) revert ContractCreation();

        // The receipt is the last chunk, whatever the transaction type. `logsBloom` is decoded but
        // unused; the logs themselves are kept, because for any source contract we did not write
        // ourselves the calldata is not enough to say what happened — see `logs` below.
        bytes memory receiptChunk = chunks[chunks.length - 1];
        if (receiptChunk.length == 0) revert NoReceipt();
        (c.status,, c.logs,) = abi.decode(receiptChunk, (uint8, uint64, Log[], bytes));
    }

    /// Mirrors the receipt-log tuple the encoder emits: `tuple(address, bytes32[], bytes)[]`.
    struct Log {
        address addr;
        bytes32[] topics;
        bytes data;
    }

    /// The 4-byte selector of the source call, or `0x00000000` for a plain transfer.
    function selector(Call memory c) internal pure returns (bytes4 s) {
        if (c.data.length < 4) return bytes4(0);
        bytes memory d = c.data;
        assembly {
            s := mload(add(d, 32))
        }
    }

    /// Arguments following the selector, ready for `abi.decode`.
    function args(Call memory c) internal pure returns (bytes memory a) {
        if (c.data.length < 4) return "";
        a = new bytes(c.data.length - 4);
        for (uint256 i = 0; i < a.length; i++) {
            a[i] = c.data[i + 4];
        }
    }

    /// Find the first log at or after `from` that `emitter` produced with `topic0` as its signature.
    /// Returns the index so the caller can key replay protection on it.
    ///
    /// Both halves of the predicate carry weight. Matching on `topic0` alone would accept an event
    /// with the right shape emitted by *any* contract that happened to be in the same transaction —
    /// anyone can deploy a contract that emits `Repay(address,address,address,uint256,bool)`, call it,
    /// and have that transaction proven. Matching on `emitter` alone would accept a different event
    /// from the right contract. The pair is what makes the log a statement by a specific protocol.
    ///
    /// The index matters as much as the match. One transaction can contain many logs — a routed
    /// repayment on Sepolia's Aave V3 pool has been observed at log index 500 — and several of them
    /// may be genuine repayments for different borrowers. A consumer that keys replay on the
    /// transaction hash records the first and silently drops the rest; keying on the log is what
    /// makes each one a distinct fact.
    function findLog(Call memory c, address emitter, bytes32 topic0, uint256 from)
        internal
        pure
        returns (uint256 index, bool found)
    {
        for (uint256 i = from; i < c.logs.length; i++) {
            Log memory l = c.logs[i];
            if (l.addr == emitter && l.topics.length > 0 && l.topics[0] == topic0) return (i, true);
        }
        return (0, false);
    }

    /// An indexed `address` topic, unpacked. Topics are 32 bytes; an address occupies the low 20.
    function topicAddress(Log memory l, uint256 i) internal pure returns (address) {
        return address(uint160(uint256(l.topics[i])));
    }

    /// The `i`-th 32-byte word of a log's non-indexed data.
    function word(Log memory l, uint256 i) internal pure returns (uint256 v) {
        if (l.data.length < (i + 1) * 32) revert ShortLogData();
        bytes memory d = l.data;
        uint256 off = 32 + i * 32;
        assembly {
            v := mload(add(d, off))
        }
    }

    error ShortLogData();
}
