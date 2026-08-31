// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {AaveLoanBook} from "../src/AaveLoanBook.sol";

/// Deploys the loan book that reads Aave V3 — one deployment, on Creditcoin only.
///
/// There is no source-chain half to deploy, and that absence is the whole point. `Deploy.s.sol` has
/// to ship a `LoanRepayment` and a `MockUSD` to Sepolia first, because the repayments it proves do
/// not exist until we create them. This book proves repayments that were already happening before we
/// arrived and will keep happening after; the source contract is Aave's, and nobody needs our
/// permission to produce a fact for it.
///
///   forge script script/DeployAave.s.sol:DeployAave --rpc-url cc3 --broadcast \
///     --gas-estimate-multiplier 400 --skip-simulation
///
/// The gas flags are not superstition: CC3 is Frontier-based and its estimate for a call touching a
/// precompile comes back too low, so a plain broadcast reverts out of gas.
contract DeployAave is Script {
    /// Aave V3 Pool, Ethereum Sepolia. Verified deployed (4,668 bytes of code) rather than copied
    /// from a docs page.
    address constant AAVE_V3_POOL_SEPOLIA = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;

    /// Sepolia's own chain id. `chainKey` is resolved against this at every post and is never
    /// trusted on its own — on CC3 Mainnet, chainKey 1 is Ethereum, not Sepolia.
    uint64 constant SEPOLIA_CHAIN_ID = 11155111;

    /// How far behind the attested tip a repayment may be, in SOURCE blocks. 50,000 Sepolia blocks
    /// is roughly a week. Stated in blocks because an Attestcoin attestation carries no timestamp,
    /// so there is no honest way to say "a week" on-chain.
    uint64 constant MAX_AGE_BLOCKS = 50_000;

    function run() external {
        address pool = vm.envOr("AAVE_POOL", AAVE_V3_POOL_SEPOLIA);
        uint64 chainId = uint64(vm.envOr("SOURCE_CHAIN_ID", uint256(SEPOLIA_CHAIN_ID)));
        uint64 maxAge = uint64(vm.envOr("MAX_AGE_BLOCKS", uint256(MAX_AGE_BLOCKS)));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        AaveLoanBook book = new AaveLoanBook(pool, chainId, maxAge);
        vm.stopBroadcast();

        console2.log("AaveLoanBook:  ", address(book));
        console2.log("  reads pool:  ", pool);
        console2.log("  source chain:", chainId);
        console2.log("  max age:     ", maxAge, "source blocks");
        console2.log("");
        console2.log("Next: node tools/post-aave.mjs  (finds a real repayment, proves it, posts it)");
    }
}
