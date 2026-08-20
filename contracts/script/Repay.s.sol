// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {LoanRepayment} from "../src/LoanRepayment.sol";

/// Makes the repayment the whole system exists to react to — the entire borrower flow in one
/// transaction batch:
///
///   MOCK_USD=0x… LOAN_REPAYMENT=0x… LOAN_ID=7 AMOUNT=250000000 \
///   forge script script/Repay.s.sol:Repay --rpc-url sepolia --broadcast
///
/// The borrower is the broadcasting account, because it must be: repay requires
/// borrower == msg.sender, and the book on Creditcoin independently checks the proven transaction's
/// sender against the borrower named in its calldata. Crediting someone else's history fails on
/// Sepolia; claiming it in a forged proof fails on Creditcoin.
contract Repay is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address borrower = vm.addr(pk);
        MockUSD usd = MockUSD(vm.envAddress("MOCK_USD"));
        LoanRepayment loan = LoanRepayment(vm.envAddress("LOAN_REPAYMENT"));

        uint256 loanId = vm.envOr("LOAN_ID", uint256(7));
        uint256 amount = vm.envOr("AMOUNT", uint256(250_000_000)); // 250 mUSD, 6 decimals
        uint256 deadline = block.timestamp + vm.envOr("VALID_FOR", uint256(2 hours));

        vm.startBroadcast(pk);
        usd.mint(borrower, amount); // open faucet, so the demo is reproducible
        usd.approve(address(loan), amount);
        loan.repay(borrower, loanId, amount, deadline);
        vm.stopBroadcast();

        console2.log("repay() sent");
        console2.log("  borrower", borrower);
        console2.log("  loanId  ", loanId);
        console2.log("  amount  ", amount);
        console2.log("The agent should pick this up, wait for attestation, then post it to the book on CC3.");
    }
}
