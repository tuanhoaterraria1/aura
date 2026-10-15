// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { CortexHook } from "../src/CortexHook.sol";
import { CortexLauncher } from "../src/CortexLauncher.sol";
import { CortexToken } from "../src/CortexToken.sol";
import { CortexTreasury } from "../src/CortexTreasury.sol";

contract TestSwapRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable { }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        external
        payable
        returns (BalanceDelta delta)
    {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
        if (address(this).balance != 0) payable(msg.sender).transfer(address(this).balance);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (address payer, PoolKey memory key, SwapParams memory params) = abi.decode(data, (address, PoolKey, SwapParams));
        BalanceDelta delta = manager.swap(key, params, "");
        if (delta.amount0() < 0) key.currency0.settle(manager, address(this), uint128(-delta.amount0()), false);
        if (delta.amount1() < 0) key.currency1.settle(manager, payer, uint128(-delta.amount1()), false);
        if (delta.amount0() > 0) key.currency0.take(manager, payer, uint128(delta.amount0()), false);
        if (delta.amount1() > 0) key.currency1.take(manager, payer, uint128(delta.amount1()), false);
        return abi.encode(delta);
    }
}

contract CortexTest is Test {
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    int24 constant START_TICK = 195_180; // ~300M tokens per ETH
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant PPM = 1_000_000;

    PoolManager manager;
    CortexLauncher launcher;
    CortexToken token;
    CortexHook hook;
    CortexTreasury treasury;
    TestSwapRouter router;
    PoolKey key;

    address launchWallet = makeAddr("launchWallet");
    address agent = makeAddr("agent");
    address vault = makeAddr("settlementFeeVault");
    address trader = makeAddr("trader");
    address stranger = makeAddr("stranger");

    function setUp() public {
        manager = new PoolManager(address(this));
        launcher = new CortexLauncher(manager, launchWallet, vault);
        token = new CortexToken("Cortex", "CTX", SUPPLY, address(launcher));

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo("CortexHook.sol:CortexHook", abi.encode(manager, address(launcher)), hookAddress);
        hook = CortexHook(hookAddress);
        treasury = new CortexTreasury(manager, hookAddress, address(token));
        router = new TestSwapRouter(manager);

        vm.deal(launchWallet, 10 ether);
        vm.deal(trader, 100 ether);
        vm.prank(launchWallet, launchWallet);
        launcher.initialize{ value: 1 ether }(hookAddress, address(token), address(treasury), agent, START_TICK, 1);
        key = hook.poolKey();

        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    // ------------------------------------------------------------ launch

    function test_LaunchLocksSupplyAndChargesInitialBuy() public view {
        assertTrue(hook.poolRegistered());
        assertGt(launcher.lockedLiquidity(), 0);
        assertEq(token.balanceOf(address(launcher)), 0, "no supply left in launcher");
        assertGt(token.balanceOf(launchWallet), 0, "initial buy delivered");
        // Launcher pays the platform fee and base treasury fee, but no anti-sniper fee.
        assertEq(hook.platformFeesAccrued(), 0.003 ether);
        assertEq(hook.treasuryFeesAccrued(), 0.007 ether);
    }

    function test_LaunchIsOneShotAndWalletBound() public {
        vm.prank(launchWallet, launchWallet);
        vm.expectRevert(CortexLauncher.AlreadyLaunched.selector);
        launcher.initialize(address(hook), address(token), address(treasury), agent, START_TICK, 0);
    }

    function test_OnlyLauncherRegistersAndNoForeignPools() public {
        vm.expectRevert(CortexHook.Unauthorized.selector);
        hook.registerPool(key, address(treasury), stranger, stranger, TickMath.getSqrtPriceAtTick(0));

        CortexToken other = new CortexToken("Other", "OTH", 1 ether, address(this));
        PoolKey memory foreign = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(other)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(foreign, TickMath.getSqrtPriceAtTick(0));
    }

    // ------------------------------------------------------------ fees

    function test_SnipeFeeDecays() public {
        assertEq(hook.treasuryFeePpmFor(trader), 100_000);
        assertEq(hook.treasuryFeePpmFor(address(launcher)), 7_000);
        vm.roll(vm.getBlockNumber() + 15);
        assertEq(hook.treasuryFeePpmFor(trader), 50_000);
        vm.roll(vm.getBlockNumber() + 15);
        assertEq(hook.treasuryFeePpmFor(trader), 7_000);
    }

    function test_ExactInputBuyChargesGrossEthInput() public {
        _pastSnipeWindow();
        (uint256 platformBefore, uint256 treasuryBefore) = _accrued();
        uint256 ethBefore = trader.balance;
        vm.prank(trader);
        router.swap{ value: 1 ether }(key, true, -1 ether);
        assertEq(ethBefore - trader.balance, 1 ether);
        (uint256 platformAfter, uint256 treasuryAfter) = _accrued();
        assertEq(platformAfter - platformBefore, 0.003 ether);
        assertEq(treasuryAfter - treasuryBefore, 0.007 ether);
    }

    function test_ExactInputSellChargesGrossEthOutput() public {
        _pastSnipeWindow();
        _buy(2 ether);
        uint256 tokens = token.balanceOf(trader);
        (uint256 platformBefore, uint256 treasuryBefore) = _accrued();
        uint256 ethBefore = trader.balance;
        vm.prank(trader);
        router.swap(key, false, -int256(tokens));
        uint256 received = trader.balance - ethBefore;
        (uint256 platformAfter, uint256 treasuryAfter) = _accrued();
        uint256 platformFee = platformAfter - platformBefore;
        uint256 gross = received + platformFee + (treasuryAfter - treasuryBefore);
        assertEq(platformFee, _ceil(gross, 3_000));
        assertEq(treasuryAfter - treasuryBefore, _ceil(gross, 7_000));
    }

    function test_ExactOutputBuyCoversRateOnGrossInput() public {
        _pastSnipeWindow();
        (uint256 platformBefore,) = _accrued();
        uint256 ethBefore = trader.balance;
        vm.prank(trader);
        router.swap{ value: 5 ether }(key, true, int256(1_000_000 ether));
        assertEq(token.balanceOf(trader), 1_000_000 ether);
        uint256 grossPaid = ethBefore - trader.balance;
        (uint256 platformAfter,) = _accrued();
        assertGe((platformAfter - platformBefore) * PPM, grossPaid * 3_000);
    }

    function test_ExactOutputSellCoversRateOnGrossOutput() public {
        _pastSnipeWindow();
        _buy(2 ether);
        (uint256 platformBefore, uint256 treasuryBefore) = _accrued();
        uint256 ethBefore = trader.balance;
        vm.prank(trader);
        router.swap(key, false, int256(0.5 ether));
        assertEq(trader.balance - ethBefore, 0.5 ether);
        (uint256 platformAfter, uint256 treasuryAfter) = _accrued();
        uint256 platformFee = platformAfter - platformBefore;
        uint256 gross = 0.5 ether + platformFee + (treasuryAfter - treasuryBefore);
        assertGe(platformFee * PPM, gross * 3_000);
    }

    function test_DistributePaysFixedRecipients() public {
        (uint256 platformAccrued, uint256 treasuryAccrued) = _accrued();
        uint256 platformBefore = PLATFORM.balance;
        vm.prank(stranger);
        hook.distribute();
        assertEq(PLATFORM.balance - platformBefore, platformAccrued);
        assertEq(address(treasury).balance, treasuryAccrued);
        (platformAccrued, treasuryAccrued) = _accrued();
        assertEq(platformAccrued + treasuryAccrued, 0);
        vm.expectRevert(CortexHook.NothingToDistribute.selector);
        hook.distribute();
    }

    function testFuzz_FeesForNetCoverGross(uint96 net, uint24 treasuryPpm) public view {
        treasuryPpm = uint24(bound(treasuryPpm, 0, 100_000));
        (uint256 platformFee, uint256 treasuryFee) = hook.feesForNet(net, treasuryPpm);
        uint256 gross = uint256(net) + platformFee + treasuryFee;
        assertGe(platformFee * PPM, gross * 3_000);
        assertGe((platformFee + treasuryFee) * PPM, gross * (3_000 + uint256(treasuryPpm)));
    }

    // ------------------------------------------------------------ agent guardrails

    function test_AgentUpdatesWithinGuardrails() public {
        vm.prank(agent);
        hook.setAgentFee(12_000, 1 hours, keccak256("r1"), "ipfs://r1");
        assertEq(hook.currentAgentFeePpm(), 12_000);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(CortexHook.AgentUpdateTooSoon.selector, uint64(block.timestamp + 15 minutes)));
        hook.setAgentFee(10_000, 1 hours, bytes32(0), "");

        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(CortexHook.AgentStepTooLarge.selector, uint24(12_000), uint24(18_000)));
        hook.setAgentFee(18_000, 1 hours, bytes32(0), "");

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(hook.currentAgentFeePpm(), 7_000, "expired regime falls back to base");
    }

    function test_AgentCannotExceedCapOrTtl() public {
        for (uint256 i; i < 5; ++i) {
            vm.warp(vm.getBlockTimestamp() + 15 minutes);
            vm.prank(agent);
            hook.setAgentFee(uint24(7_000 + 5_000 * (i + 1) > 30_000 ? 30_000 : 7_000 + 5_000 * (i + 1)), 1 hours, 0, "");
        }
        assertEq(hook.currentAgentFeePpm(), 30_000);
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(CortexHook.AgentFeeAboveCap.selector, uint24(30_001)));
        hook.setAgentFee(30_001, 1 hours, 0, "");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(CortexHook.InvalidTtl.selector, uint32(24 hours + 1)));
        hook.setAgentFee(30_000, 24 hours + 1, 0, "");
    }

    function test_OnlyAgentAndAdminControls() public {
        vm.prank(stranger);
        vm.expectRevert(CortexHook.Unauthorized.selector);
        hook.setAgentFee(8_000, 1 hours, 0, "");

        vm.prank(stranger);
        vm.expectRevert(CortexHook.Unauthorized.selector);
        hook.setAgent(stranger);

        vm.prank(agent);
        hook.setAgentFee(12_000, 1 hours, 0, "");
        vm.prank(launchWallet);
        hook.setAgent(address(0));
        assertEq(hook.currentAgentFeePpm(), 7_000, "revoking the agent resets the fee");
    }

    // ------------------------------------------------------------ treasury

    function test_BuybackBurnsAndIsBounded() public {
        _pastSnipeWindow();
        _buy(10 ether);
        hook.distribute();
        uint256 balance = address(treasury).balance;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(stranger);
        vm.expectRevert(CortexTreasury.Unauthorized.selector);
        treasury.buyback(balance / 10, 0, 0);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(CortexTreasury.BuybackTooLarge.selector, balance, balance / 5));
        treasury.buyback(balance, 0, 0);

        vm.prank(agent);
        uint256 burned = treasury.buyback(balance / 5, 1, keccak256("why"));
        assertGt(burned, 0);
        assertEq(token.totalSupply(), supplyBefore - burned);

        vm.prank(agent);
        vm.expectRevert();
        treasury.buyback(1, 0, 0);

        vm.prank(launchWallet);
        hook.setAgent(address(0));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(stranger);
        treasury.buyback(address(treasury).balance / 5, 1, 0);
    }

    function test_LpFeesFlowToTreasuryAndBurn() public {
        _pastSnipeWindow();
        _buy(5 ether);
        uint256 tokens = token.balanceOf(trader);
        vm.prank(trader);
        router.swap(key, false, -int256(tokens / 2));

        (uint256 ethFees, uint256 tokenFees) = launcher.collectLpFees();
        assertGt(ethFees, 0);
        assertGt(tokenFees, 0);
        assertEq(address(treasury).balance, ethFees);
        uint256 supplyBefore = token.totalSupply();
        treasury.burnHeldTokens();
        assertEq(token.totalSupply(), supplyBefore - tokenFees);
    }

    // ------------------------------------------------------------ helpers

    function _pastSnipeWindow() private {
        vm.roll(vm.getBlockNumber() + hook.SNIPE_DECAY_BLOCKS());
    }

    function _buy(uint256 ethIn) private {
        vm.prank(trader);
        router.swap{ value: ethIn }(key, true, -int256(ethIn));
    }

    function _accrued() private view returns (uint256, uint256) {
        return (hook.platformFeesAccrued(), hook.treasuryFeesAccrued());
    }

    function _ceil(uint256 amount, uint256 ppm) private pure returns (uint256) {
        return (amount * ppm + PPM - 1) / PPM;
    }
}
