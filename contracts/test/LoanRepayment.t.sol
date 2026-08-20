// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {LoanRepayment} from "../src/LoanRepayment.sol";

/// The source half's own guarantees, tested directly on Sepolia-equivalent logic. The book on
/// Creditcoin trusts that a `Repaid` event means real money moved to the lender; these tests are
/// what make that true at the source, so a credit history cannot be manufactured for free.
contract LoanRepaymentTest is Test {
    MockUSD usd;
    LoanRepayment loan;
    address lender = address(0xA11CE);
    address borrower = address(0xB0B);

    function setUp() public {
        usd = new MockUSD();
        loan = new LoanRepayment(address(usd), lender);
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(who);
        usd.mint(who, amount);
        vm.prank(who);
        usd.approve(address(loan), amount);
    }

    function test_realRepaymentMovesTokensAndEmits() public {
        _fund(borrower, 250e6);
        vm.expectEmit(true, true, false, true);
        emit LoanRepayment.Repaid(borrower, 7, 250e6, block.timestamp + 1 hours);
        vm.prank(borrower);
        loan.repay(borrower, 7, 250e6, block.timestamp + 1 hours);
        assertEq(usd.balanceOf(lender), 250e6, "lender received the repayment");
        assertEq(usd.balanceOf(borrower), 0, "borrower paid");
    }

    /// A zero-amount repayment clears an ERC20 transfer while moving nothing — it must not be able
    /// to emit a Repaid the book would count.
    function test_zeroAmountIsRejected() public {
        vm.prank(borrower);
        vm.expectRevert(LoanRepayment.ZeroAmount.selector);
        loan.repay(borrower, 7, 0, block.timestamp + 1 hours);
    }

    /// If the borrower were also the lender, transferFrom(self, self) nets to nothing yet records
    /// the full amount — a way to fabricate one's own good history. Refused.
    function test_selfPaymentIsRejected() public {
        _fund(lender, 100e6);
        vm.prank(lender);
        vm.expectRevert(LoanRepayment.SelfPayment.selector);
        loan.repay(lender, 7, 100e6, block.timestamp + 1 hours);
    }

    /// The borrower named must be the account that actually sends the transaction, so the book can
    /// check the proven sender against it.
    function test_borrowerMustBeSender() public {
        _fund(borrower, 100e6);
        address attacker = address(0xA77ACC);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(LoanRepayment.NotBorrower.selector, borrower, attacker));
        loan.repay(borrower, 7, 100e6, block.timestamp + 1 hours);
    }

    function test_pastDeadlineIsRejected() public {
        _fund(borrower, 100e6);
        vm.warp(1_000_000);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(LoanRepayment.DeadlineInPast.selector, uint256(999_999)));
        loan.repay(borrower, 7, 100e6, 999_999);
    }

    /// Without enough balance the transfer reverts inside MockUSD, so no Repaid is emitted — the
    /// on-chain fact and the economic fact cannot diverge.
    function test_insufficientBalanceReverts() public {
        vm.prank(borrower);
        usd.approve(address(loan), 100e6); // approved but not funded
        vm.prank(borrower);
        vm.expectRevert(bytes("mUSD: balance"));
        loan.repay(borrower, 7, 100e6, block.timestamp + 1 hours);
    }
}
