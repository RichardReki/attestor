// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {SourceAuthorization} from "../src/SourceAuthorization.sol";
import {AttestedGovernor} from "../src/AttestedGovernor.sol";

/// Two deployments, in this order, because the governor is bound to the source at construction:
///
///   forge script script/Deploy.s.sol:DeploySource   --rpc-url sepolia --broadcast
///   SOURCE_AUTHORIZATION=0x… \
///   forge script script/Deploy.s.sol:DeployGovernor --rpc-url cc3     --broadcast
///
/// The binding is immutable on purpose. A governor that could be repointed at a different source
/// contract would only be as trustworthy as whoever holds the key to repoint it, which would give
/// back exactly the trust the proof was supposed to remove.

contract DeploySource is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        SourceAuthorization s = new SourceAuthorization();
        vm.stopBroadcast();
        console2.log("SourceAuthorization (Sepolia):", address(s));
        console2.log("  put this in SOURCE_AUTHORIZATION before deploying the governor");
    }
}

contract DeployGovernor is Script {
    /// Sepolia's own chain id. The governor binds to this rather than to a chainKey, because a
    /// chainKey means different chains in different Creditcoin environments.
    uint64 constant SOURCE_CHAIN_ID = 11155111;
    /// How long an authorisation may remain executable. A day is generous for a demo and still
    /// bounded — the actor picks the deadline, so without a ceiling here one grant is a permanent key.
    uint256 constant MAX_AGE = 1 days;

    function run() external {
        address source = vm.envAddress("SOURCE_AUTHORIZATION");
        bytes4 selector = SourceAuthorization.authorise.selector;

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        AttestedGovernor g = new AttestedGovernor(SOURCE_CHAIN_ID, source, selector, MAX_AGE);
        vm.stopBroadcast();

        console2.log("AttestedGovernor (CC3 Testnet):", address(g));
        console2.log("  bound to source:", source);
        console2.log("  bound to chainId:", SOURCE_CHAIN_ID);
        console2.logBytes4(selector);
    }
}
