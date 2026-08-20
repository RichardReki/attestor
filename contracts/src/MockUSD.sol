// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// A minimal, mint-anyone stablecoin so the demo's repayments are real token movements a judge can
/// reproduce without asking us for funds. Six decimals, like USDC. Nothing here is novel; it exists
/// only so `LoanRepayment.repay` can perform a genuine `transferFrom` that reverts unless it clears
/// — which is what makes "this repayment succeeded" a fact worth attesting rather than a log line.
contract MockUSD {
    string public constant name = "Mock USD";
    string public constant symbol = "mUSD";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// Open faucet: anyone can mint themselves test dollars, so the whole flow is reproducible.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "mUSD: allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "mUSD: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
