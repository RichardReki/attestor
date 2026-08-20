// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IBlockProver, IChainInfo} from "./interfaces/IAttestcoin.sol";

/// Checks, against the live runtime, every assumption about the precompiles that the mocked unit
/// tests encode. Those tests can only prove the governor behaves correctly *given* a prover verdict;
/// this proves the verdicts themselves look the way we claim.
///
/// The load-bearing one is catchability. `AttestedGovernor` wraps the call in `try/catch` so a forged
/// proof can be reported as its own named error rather than as an anonymous revert. That design
/// only works if the failure is an ordinary EVM revert. Attestcoin's precompiles are Substrate
/// runtime code, and a Frontier precompile can fail with an `ExitError` that is not a revert at
/// all — such a failure unwinds the whole call frame and no `catch` block ever runs.
///
/// This has to run against a real node. The precompiles are Substrate runtime code — `eth_getCode`
/// at `0x0FD2` returns `0x` — so a Foundry fork has nothing there, and a `CALL` to a codeless
/// address succeeds silently and returns no data. Fork tests of these claims do not fail loudly;
/// they pass the wrong assertions. Running as creation code under `eth_call` costs nothing, needs
/// no key, and asks the real runtime.
contract LiveProbe {
    IBlockProver constant PROVER = IBlockProver(0x0000000000000000000000000000000000000FD2);
    IChainInfo constant CHAIN_INFO = IChainInfo(0x0000000000000000000000000000000000000fD3);

    // Returns (sepoliaChainId, ethereumChainId, validVerifies, tamperedCaught, tamperedReason,
    //          wrongKeyCaught, wrongKeyReason).
    //
    // "Caught" is the interesting word. A precompile that failed with a Frontier ExitError rather
    // than a revert would unwind this whole frame and the eth_call would return nothing at all —
    // so a decoded answer is itself the evidence that try/catch is a sound way to call it.
    constructor(
        uint64 chainKey,
        uint64 height,
        bytes memory txBytes,
        IBlockProver.MerkleProof memory mp,
        IBlockProver.ContinuityProof memory cp
    ) {
        IChainInfo.ChainResult memory sep = CHAIN_INFO.get_chain_by_key(1);
        IChainInfo.ChainResult memory eth = CHAIN_INFO.get_chain_by_key(3);

        // The happy path, from inside the EVM. This is also what confirms the interface: the
        // on-chain function is `verify`, and the SDK's `verifySingle` would be a selector that
        // does not exist here.
        bool validVerifies = PROVER.verify(chainKey, height, txBytes, mp, cp);

        // bytes.concat copies; a plain `= txBytes` would alias the same memory, and mutating the
        // copy would corrupt txBytes for the wrong-key check below — conflating two distinct attacks
        // and mislabelling which error each produces.
        bytes memory tampered = bytes.concat(txBytes);
        tampered[tampered.length - 1] = tampered[tampered.length - 1] ^ bytes1(0x01);
        (bool tamperedCaught, string memory tamperedReason) = _reject(chainKey, height, tampered, mp, cp);

        // A genuine proof replayed under a different source chain's key.
        (bool wrongKeyCaught, string memory wrongKeyReason) =
            _reject(chainKey == 1 ? 3 : 1, height, txBytes, mp, cp);

        bytes memory out = abi.encode(
            sep.chain.chainId, eth.chain.chainId, validVerifies, tamperedCaught, tamperedReason, wrongKeyCaught, wrongKeyReason
        );
        assembly {
            return(add(out, 32), mload(out))
        }
    }

    /// Call the precompile expecting refusal, and report whether Solidity could catch it.
    function _reject(
        uint64 chainKey,
        uint64 height,
        bytes memory txBytes,
        IBlockProver.MerkleProof memory mp,
        IBlockProver.ContinuityProof memory cp
    ) internal view returns (bool caught, string memory reason) {
        try PROVER.verify(chainKey, height, txBytes, mp, cp) returns (bool r) {
            return (false, r ? "ACCEPTED A PROOF IT SHOULD HAVE REFUSED" : "returned false");
        } catch Error(string memory e) {
            return (true, e);
        } catch (bytes memory) {
            return (true, "(caught, no reason string)");
        }
    }
}
