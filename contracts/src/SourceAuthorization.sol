// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// The source-chain half, deployed on Ethereum Sepolia.
///
/// Deliberately minimal. Everything that matters to the governor on Creditcoin is already in the
/// transaction envelope — who sent it, what it called, whether it succeeded — so this contract does
/// not need to be clever, and being clever here would be a mistake: any state it kept would be
/// state the governor cannot see and must not depend on.
///
/// It emits an event for humans and indexers. The governor ignores the event entirely and reads the
/// calldata, because the calldata is what the transaction encoding proves.
contract SourceAuthorization {
    event Authorised(address indexed actor, uint256 amount, uint256 deadline);

    error DeadlineInPast(uint256 deadline);
    error ActorMismatch(address actor, address sender);

    /// Grant `actor` authority to have `amount` credited on Creditcoin, until `deadline`.
    ///
    /// `actor` is passed explicitly rather than taken from `msg.sender` so that the governor has
    /// something to *check it against*: the proven transaction carries the real sender, and a
    /// mismatch is a forgery attempt the governor can name. Enforcing equality here too means the
    /// two halves fail closed independently — neither is load-bearing alone.
    function authorise(address actor, uint256 amount, uint256 deadline) external {
        if (actor != msg.sender) revert ActorMismatch(actor, msg.sender);
        if (deadline <= block.timestamp) revert DeadlineInPast(deadline);
        emit Authorised(actor, amount, deadline);
    }
}
