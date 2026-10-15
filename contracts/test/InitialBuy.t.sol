// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console } from "forge-std/Test.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";

import { CortexHook } from "../src/CortexHook.sol";
import { CortexLauncher } from "../src/CortexLauncher.sol";
import { CortexToken } from "../src/CortexToken.sol";
import { CortexTreasury } from "../src/CortexTreasury.sol";

/// @notice Quotes the launch-time initial buy with the production parameters (1B supply, start tick 195180).
///         Run: forge test --match-contract InitialBuyQuote -vv
contract InitialBuyQuote is Test {
    function test_QuoteInitialBuy() public {
        uint256 buyWei = vm.envOr("CORTEX_INITIAL_BUY_WEI", uint256(0.05 ether));
        address launchWallet = makeAddr("launchWallet");
        PoolManager manager = new PoolManager(address(this));
        CortexLauncher launcher = new CortexLauncher(manager, launchWallet, makeAddr("vault"));
        CortexToken token = new CortexToken("Aura coin 404", "AURA", 1_000_000_000 ether, address(launcher));
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo("CortexHook.sol:CortexHook", abi.encode(manager, address(launcher)), hookAddress);
        CortexTreasury treasury = new CortexTreasury(manager, hookAddress, address(token));

        vm.deal(launchWallet, buyWei);
        vm.prank(launchWallet, launchWallet);
        launcher.initialize{ value: buyWei }(hookAddress, address(token), address(treasury), makeAddr("agent"), 195_180, 1);

        uint256 received = token.balanceOf(launchWallet);
        console.log("initial buy wei     ", buyWei);
        console.log("tokens received     ", received);
        console.log("share of supply bps ", received * 10_000 / token.totalSupply());
        console.log("platform fee wei    ", CortexHook(hookAddress).platformFeesAccrued());
        console.log("treasury fee wei    ", CortexHook(hookAddress).treasuryFeesAccrued());
        assertGt(received, 0);
    }
}
