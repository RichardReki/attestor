// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// The source-chain half, deployed on Ethereum Sepolia: a borrower repays a loan.
///
/// This is where the economically-meaningful fact happens. `repay` pulls real (mock) stablecoin
/// from the borrower to the lender — a transfer that reverts unless it clears — and emits `Repaid`.
/// Because the transfer is inside the same transaction, a *successful* repayment and a *failed* one
/// are two different on-chain facts, and Attestcoin can prove which occurred. That is the point of
/// putting the money movement here rather than trusting an off-chain claim that it happened.
///
/// The `borrower` is passed explicitly and required to equal `msg.sender`, so the loan book on
/// Creditcoin has something to check the proven transaction's real sender against: a proof whose
/// declared borrower is not the account that actually sent it is an impersonation the book rejects.
/// Enforcing it on both chains means neither half is load-bearing alone.
contract LoanRepayment {
    IERC20 public immutable usd;
    address public immutable lender;

    event Repaid(address indexed borrower, uint256 indexed loanId, uint256 amount, uint256 deadline);

    error NotBorrower(address borrower, address sender);
    error DeadlineInPast(uint256 deadline);
    error ZeroAmount();
    error SelfPayment();
    error TransferFailed();

    constructor(address usd_, address lender_) {
        usd = IERC20(usd_);
        lender = lender_;
    }

    /// Repay `amount` toward `loanId`. `deadline` bounds how long the resulting proof may still be
    /// posted by the loan book — an attested fact is provable forever, so the right to post it must
    /// expire.
    ///
    /// The two guards below exist because the whole product is a credit history, and a history is
    /// only worth anything if an entry means real money moved. A zero `amount` would clear the
    /// transfer (moving nothing) and still emit `Repaid`, letting anyone manufacture repayment
    /// events for gas alone. And if the borrower were also the lender, `transferFrom(self, self)`
    /// nets to nothing while recording the full amount — a way to fabricate one's own good history.
    /// Both are refused here, and the book on Creditcoin refuses a zero amount again as defence in
    /// depth, so neither check is load-bearing alone.
    function repay(address borrower, uint256 loanId, uint256 amount, uint256 deadline) external {
        if (borrower != msg.sender) revert NotBorrower(borrower, msg.sender);
        if (msg.sender == lender) revert SelfPayment();
        if (amount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert DeadlineInPast(deadline);
        if (!usd.transferFrom(msg.sender, lender, amount)) revert TransferFailed();
        emit Repaid(borrower, loanId, amount, deadline);
    }
}
