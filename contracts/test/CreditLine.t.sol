// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {CreditLine} from "../src/CreditLine.sol";
import {MockUSD} from "../src/MockUSD.sol";

/// A stand-in for AttestedLoanBook exposing just the two getters CreditLine reads. Using a mock here
/// keeps these tests about the lending logic; the book's own correctness (the seven checks) is proven
/// in Attacks.t.sol, and the real book is what CreditLine binds to on-chain.
contract MockBook {
    mapping(address => uint256) public totalRepaid;
    mapping(address => uint256) public repaymentCount;

    function set(address borrower, uint256 repaid, uint256 count) external {
        totalRepaid[borrower] = repaid;
        repaymentCount[borrower] = count;
    }
}

/// CreditLine turns the attested history into credit. These tests pin the one property that matters:
/// credit is available if and only if the history says so, and never beyond it.
contract CreditLineTest is Test {
    MockBook book;
    MockUSD asset;
    CreditLine line;

    address borrower = address(0xB0B);
    address stranger = address(0x57A);

    function setUp() public {
        book = new MockBook();
        asset = new MockUSD();
        line = new CreditLine(address(book), address(asset));
        // Fund the lending pool.
        asset.mint(address(line), 1_000_000e6);
    }

    function test_provenHistoryUnlocksCredit() public {
        book.set(borrower, 250e6, 1); // 250 repaid, one repayment
        assertEq(line.creditLimit(borrower), 250e6, "limit tracks proven repayment 1:1");
        assertEq(line.available(borrower), 250e6, "all of it available at first");

        vm.prank(borrower);
        line.borrow(200e6);
        assertEq(asset.balanceOf(borrower), 200e6, "borrower received the loan");
        assertEq(line.borrowed(borrower), 200e6, "debt recorded");
        assertEq(line.available(borrower), 50e6, "remaining headroom");
    }

    function test_noHistoryNoCredit() public {
        assertEq(line.creditLimit(stranger), 0, "no history, no limit");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.NoCreditHistory.selector, stranger));
        line.borrow(1);
    }

    /// A single big repayment is not enough on its own if MIN_REPAYMENTS demands more history; here
    /// MIN_REPAYMENTS is 1, so a count of 0 (however large the amount) still yields no credit.
    function test_amountWithoutAnyRepaymentCountGivesNothing() public {
        book.set(borrower, 1_000_000e6, 0); // impossible from the real book, but proves the gate
        assertEq(line.creditLimit(borrower), 0, "count below minimum -> no credit");
    }

    function test_cannotBorrowBeyondTheLimit() public {
        book.set(borrower, 100e6, 2);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.OverLimit.selector, 100e6 + 1, 100e6));
        line.borrow(100e6 + 1);
    }

    function test_limitRisesWithMoreProvenRepayment() public {
        book.set(borrower, 100e6, 1);
        assertEq(line.creditLimit(borrower), 100e6);
        book.set(borrower, 400e6, 3); // more repayments posted over time
        assertEq(line.creditLimit(borrower), 400e6, "credit grows as the history does");
    }

    function test_repayingTheLineFreesCapacity() public {
        book.set(borrower, 300e6, 2);
        vm.startPrank(borrower);
        line.borrow(300e6);
        assertEq(line.available(borrower), 0, "maxed out");
        asset.approve(address(line), 120e6);
        line.repayLine(120e6);
        vm.stopPrank();
        assertEq(line.borrowed(borrower), 180e6, "debt reduced");
        assertEq(line.available(borrower), 120e6, "capacity restored");
    }

    function test_repayingMoreThanOwedIsRefused() public {
        book.set(borrower, 300e6, 2);
        vm.startPrank(borrower);
        line.borrow(100e6);
        asset.approve(address(line), 200e6);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.RepayExceedsDebt.selector, 200e6, 100e6));
        line.repayLine(200e6);
        vm.stopPrank();
    }

    function test_drawIsCappedByPoolLiquidity() public {
        book.set(borrower, 5_000_000e6, 5); // limit far exceeds the 1,000,000 pool
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.InsufficientLiquidity.selector, 2_000_000e6, 1_000_000e6));
        line.borrow(2_000_000e6);
    }
}
