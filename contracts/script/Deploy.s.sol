// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {LoanRepayment} from "../src/LoanRepayment.sol";
import {AttestedLoanBook} from "../src/AttestedLoanBook.sol";
import {CreditLine} from "../src/CreditLine.sol";

/// Two deployments, in order, because the book is bound to the source at construction:
///
///   forge script script/Deploy.s.sol:DeploySource  --rpc-url sepolia --broadcast
///   LOAN_REPAYMENT=0x… \
///   forge script script/Deploy.s.sol:DeployBook    --rpc-url cc3     --broadcast
///
/// The binding is immutable on purpose. A book that could be repointed at a different source would
/// only be as trustworthy as whoever holds the key to repoint it — giving back exactly the trust
/// the proof was supposed to remove.

contract DeploySource is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        // Deploy the demo stablecoin and the loan contract; the deployer is the lender who receives
        // repayments. On mainnet this would be a real USDC address and a real lender.
        MockUSD usd = new MockUSD();
        // The lender must differ from the borrower — self-payment is refused, since transferring to
        // yourself moves nothing while recording a repayment. LENDER overrides the demo default.
        address lender = vm.envOr("LENDER", address(0x000000000000000000000000000000000000dEaD));
        LoanRepayment loan = new LoanRepayment(address(usd), lender);
        vm.stopBroadcast();
        console2.log("MockUSD (Sepolia):       ", address(usd));
        console2.log("LoanRepayment (Sepolia): ", address(loan));
        console2.log("  lender: ", lender);
        console2.log("  put LoanRepayment in LOAN_REPAYMENT before deploying the book");
    }
}

contract DeployBook is Script {
    /// Sepolia's own chain id. The book binds to this, not to a chainKey, because a chainKey means
    /// different chains in different Creditcoin environments.
    uint64 constant SOURCE_CHAIN_ID = 11155111;
    /// How long a repayment may still be posted after it happened. A day is generous for a demo and
    /// still bounded — the borrower picks the deadline, so without a ceiling one repayment carries a
    /// permanent right to be posted.
    uint256 constant MAX_AGE = 1 days;

    function run() external {
        address source = vm.envAddress("LOAN_REPAYMENT");
        bytes4 selector = LoanRepayment.repay.selector;

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        AttestedLoanBook book = new AttestedLoanBook(SOURCE_CHAIN_ID, source, selector, MAX_AGE);
        vm.stopBroadcast();

        console2.log("AttestedLoanBook (CC3 Testnet):", address(book));
        console2.log("  bound to source:", source);
        console2.log("  bound to chainId:", SOURCE_CHAIN_ID);
        console2.logBytes4(selector);
    }
}

/// Deploys the credit consumer on CC3: a MockUSD lending pool and a CreditLine bound to the live
/// AttestedLoanBook, then seeds the pool so borrowers can actually draw against their attested history.
///
///   LOAN_BOOK=0x… POOL=1000000000000 ///   forge script script/Deploy.s.sol:DeployCreditLine --rpc-url cc3 --broadcast
contract DeployCreditLine is Script {
    function run() external {
        address book = vm.envAddress("LOAN_BOOK");
        uint256 pool = vm.envOr("POOL", uint256(1_000_000e6)); // 1,000,000 mUSD of lending liquidity

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        MockUSD asset = new MockUSD();
        CreditLine line = new CreditLine(book, address(asset));
        asset.mint(address(line), pool); // seed the pool
        vm.stopBroadcast();

        console2.log("MockUSD pool (CC3):   ", address(asset));
        console2.log("CreditLine (CC3):     ", address(line));
        console2.log("  bound to loan book: ", book);
        console2.log("  seeded liquidity:   ", pool);
    }
}