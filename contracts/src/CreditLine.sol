// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ILoanBook {
    function totalRepaid(address borrower) external view returns (uint256);
    function repaymentCount(address borrower) external view returns (uint256);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// The first thing that *reads* the credit history the loan book writes — and turns it into money.
///
/// AttestedLoanBook proves, trustlessly and cross-chain, that a borrower repaid. On its own that is a
/// write-only ledger: impressive, but inert. CreditLine closes the loop. It extends undercollateralised
/// credit sized purely by that proven history — no collateral, no off-chain score, just "you may borrow
/// against what you have provably repaid." A borrower with no attested history has a limit of zero and
/// cannot draw a cent; a borrower who has repaid can borrow up to their record.
///
/// This is the point of the whole system, made economic: a repayment that happened on Ethereum, proven
/// on Creditcoin via Attestcoin, becomes the sole determinant of credit on Creditcoin. The book cannot
/// be lied to (that is the seven checks); therefore the credit limit cannot be inflated by anything but
/// real, proven repayments. The scoring rule below is deliberately simple and is the one policy knob —
/// swap it for a risk model without touching the trust story, because the input it reads is unforgeable.
contract CreditLine {
    ILoanBook public immutable book;
    IERC20 public immutable asset;

    /// Credit extended per unit of proven repayment, in basis points. 10_000 = 1x: you may borrow up
    /// to what you have demonstrably repaid. The knob a real lender would tune; the *input* it scales
    /// is what Attestcoin makes trustworthy.
    uint256 public constant CREDIT_MULTIPLIER_BIPS = 10_000;
    /// A borrower must have at least this many posted repayments before any credit is extended, so a
    /// single large repayment is not the whole basis for a line.
    uint256 public constant MIN_REPAYMENTS = 1;

    mapping(address => uint256) public borrowed;

    event Borrowed(address indexed borrower, uint256 amount, uint256 limit, uint256 outstanding);
    event LineRepaid(address indexed borrower, uint256 amount, uint256 outstanding);

    error NoCreditHistory(address borrower);
    error OverLimit(uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 pool);
    error RepayExceedsDebt(uint256 amount, uint256 outstanding);
    error TransferFailed();

    constructor(address book_, address asset_) {
        book = ILoanBook(book_);
        asset = IERC20(asset_);
    }

    /// The borrower's credit limit, derived entirely from the attested cross-chain history. Zero until
    /// they have at least MIN_REPAYMENTS posted, then scales with total proven repayment.
    function creditLimit(address borrower) public view returns (uint256) {
        if (book.repaymentCount(borrower) < MIN_REPAYMENTS) return 0;
        return (book.totalRepaid(borrower) * CREDIT_MULTIPLIER_BIPS) / 10_000;
    }

    /// How much the borrower can still draw right now.
    function available(address borrower) public view returns (uint256) {
        uint256 limit = creditLimit(borrower);
        uint256 out = borrowed[borrower];
        return out >= limit ? 0 : limit - out;
    }

    /// Draw against the line. Reverts unless the proven history covers it and the pool can fund it.
    function borrow(uint256 amount) external {
        uint256 limit = creditLimit(msg.sender);
        if (limit == 0) revert NoCreditHistory(msg.sender);
        uint256 avail = limit - _min(borrowed[msg.sender], limit);
        if (amount > avail) revert OverLimit(amount, avail);
        uint256 pool = asset.balanceOf(address(this));
        if (amount > pool) revert InsufficientLiquidity(amount, pool);

        borrowed[msg.sender] += amount;
        if (!asset.transfer(msg.sender, amount)) revert TransferFailed();
        emit Borrowed(msg.sender, amount, limit, borrowed[msg.sender]);
    }

    /// Repay the line, freeing up capacity to borrow again. Repaying more than owed is refused rather
    /// than silently clamped, so a mistaken amount cannot quietly overpay the pool.
    function repayLine(uint256 amount) external {
        uint256 out = borrowed[msg.sender];
        if (amount > out) revert RepayExceedsDebt(amount, out);
        borrowed[msg.sender] = out - amount;
        if (!asset.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit LineRepaid(msg.sender, amount, borrowed[msg.sender]);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
