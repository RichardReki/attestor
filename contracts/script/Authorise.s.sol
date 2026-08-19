// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {SourceAuthorization} from "../src/SourceAuthorization.sol";

/// Sends the source-chain transaction that the whole system exists to react to.
///
///   AMOUNT=500 forge script script/Authorise.s.sol:Authorise --rpc-url sepolia --broadcast
///
/// The actor is the broadcasting account, because it has to be: `authorise` requires
/// `actor == msg.sender`, and the governor on Creditcoin independently checks the proven
/// transaction's sender against the actor named in its calldata. Naming someone else here fails on
/// Sepolia; naming someone else in a forged proof fails on Creditcoin. Both halves refuse
/// separately, which is the point.
contract Authorise is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address actor = vm.addr(pk);
        SourceAuthorization src = SourceAuthorization(vm.envAddress("SOURCE_AUTHORIZATION"));

        uint256 amount = vm.envOr("AMOUNT", uint256(500));
        // Comfortably inside the governor's one-day ceiling, and long enough to survive the ~8
        // minutes of attestation lag plus a retry or two.
        uint256 deadline = block.timestamp + vm.envOr("VALID_FOR", uint256(2 hours));

        vm.startBroadcast(pk);
        src.authorise(actor, amount, deadline);
        vm.stopBroadcast();

        console2.log("authorise() sent");
        console2.log("  actor   ", actor);
        console2.log("  amount  ", amount);
        console2.log("  deadline", deadline);
        console2.log("The agent should pick this up, wait for attestation, then execute on CC3.");
    }
}
