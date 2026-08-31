// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {CreditLine} from "../src/CreditLine.sol";

/// Wire the credit line to the Aave-sourced history, and read what it says about a stranger.
///
/// `CreditLine` binds to an `ILoanBook` — `totalRepaid` and `repaymentCount`. `AaveLoanBook` has
/// exactly those, so pointing credit at a foreign protocol's repayment record needs no new code at
/// all, which is the useful part: the interesting work was proving the fact, not scoring it.
///
///   AAVE_BOOK=0x… ASSET=0x… BORROWER=0x… \
///   forge script script/DeployAaveCredit.s.sol:DeployAaveCredit --rpc-url cc3 --broadcast \
///     --gas-estimate-multiplier 400 --skip-simulation
///
/// A note on what this can and cannot show. The borrower here is somebody we have never met, so we
/// cannot draw their loan — `borrow()` credits `msg.sender` and we do not have their key. That is a
/// property of doing this honestly, not a gap: the whole point is that the history belongs to them.
/// What is demonstrable, and enough, is that a credit limit computed *entirely* from their behaviour
/// in a protocol we did not write now exists on Creditcoin, readable by anyone.
contract DeployAaveCredit is Script {
    function run() external {
        address book = vm.envAddress("AAVE_BOOK");
        // Only used by borrow(); the limit itself is a pure function of the attested history.
        address asset = vm.envAddress("ASSET");
        address borrower = vm.envOr("BORROWER", address(0));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        CreditLine line = new CreditLine(book, asset);
        vm.stopBroadcast();

        console2.log("CreditLine (Aave-sourced):", address(line));
        console2.log("  reads book:             ", book);

        if (borrower != address(0)) {
            console2.log("");
            console2.log("borrower (a stranger):  ", borrower);
            console2.log("  credit limit:         ", line.creditLimit(borrower));
            console2.log("  drawn so far:         ", line.borrowed(borrower));
            console2.log("");
            console2.log("That limit came from their repayments to Aave V3 on Ethereum, proven via USC.");
            console2.log("Nobody set it, nobody can raise it, and only they can draw it.");
        }
    }
}
