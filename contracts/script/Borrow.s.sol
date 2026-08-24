// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {CreditLine} from "../src/CreditLine.sol";

/// Draws an undercollateralised loan sized by the borrower's attested cross-chain repayment history.
/// This is the payoff of the whole system: a repayment that happened on Ethereum, proven on Creditcoin
/// via Attestcoin, is the *sole* reason this borrow succeeds — and a borrower with no attested history
/// would revert with NoCreditHistory.
///
///   CREDIT_LINE=0x… AMOUNT=200000000 \
///   forge script script/Borrow.s.sol:Borrow --rpc-url cc3 --broadcast
contract Borrow is Script {
    function run() external {
        CreditLine line = CreditLine(vm.envAddress("CREDIT_LINE"));
        address me = vm.addr(vm.envUint("PRIVATE_KEY"));
        uint256 limit = line.creditLimit(me);
        uint256 amount = vm.envOr("AMOUNT", limit == 0 ? uint256(0) : limit / 2);

        console2.log("borrower:            ", me);
        console2.log("attested credit limit:", limit);
        console2.log("drawing:             ", amount);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        line.borrow(amount);
        vm.stopBroadcast();

        console2.log("outstanding now:     ", line.borrowed(me));
        console2.log("A cross-chain repayment history, proven via Attestcoin, just funded a real loan.");
    }
}
