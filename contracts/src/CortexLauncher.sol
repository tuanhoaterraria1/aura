// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

interface ICortexHookRegistrar {
    function registerPool(PoolKey calldata key, address treasury, address admin, address agent, uint160 sqrtPriceX96)
        external
        returns (int24 tick);
}

/// @title CortexLauncher
/// @notice Initializer target of the Programmable launch graph. In one transaction it:
///           1. registers and initializes the ETH/token pool through the hook,
///           2. seeds the entire token supply as single-sided liquidity below the start price
///              (no ETH needed; the position has no withdraw path, so the liquidity is locked forever),
///           3. optionally performs the launch wallet's initial buy with the transaction value.
///         LP fees earned by the locked position can be pushed to the treasury by anyone via `collectLpFees()`.
contract CortexLauncher is IUnlockCallback, ReentrancyGuardTransient {
    using CurrencySettler for Currency;

    uint24 public constant LP_FEE = 3_000;
    int24 public constant TICK_SPACING = 60;
    bytes32 public constant POSITION_SALT = bytes32(0);
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    address public immutable launchWallet;
    /// @notice Canonical Programmable settlement-fee-vault target bound to this route in the launch graph.
    address public immutable settlementFeeVault;

    bool public launched;
    address public hook;
    address public token;
    address public treasury;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public lockedLiquidity;
    PoolKey private _key;

    enum Action {
        Seed,
        CollectFees
    }

    error AlreadyLaunched();
    error InsufficientInitialBuy(uint256 received, uint256 minimum);
    error InvalidStartTick(int24 startTick);
    error NotLaunched();
    error UnauthorizedLaunch();
    error UnexpectedUnlock();
    error ZeroAddress();

    event Launched(
        address indexed hook,
        address indexed token,
        address indexed treasury,
        int24 startTick,
        uint128 liquidity,
        uint256 tokensSeeded,
        uint256 initialBuyEth,
        uint256 initialBuyTokens
    );
    event LpFeesCollected(uint256 ethAmount, uint256 tokenAmount);

    constructor(IPoolManager poolManager_, address launchWallet_, address settlementFeeVault_) {
        if (address(poolManager_) == address(0) || launchWallet_ == address(0) || settlementFeeVault_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        launchWallet = launchWallet_;
        settlementFeeVault = settlementFeeVault_;
    }

    /// @notice One-shot launch, executed by the Programmable launch transaction signed by `launchWallet`.
    /// @param startTick tick of the opening price (token per ETH), a multiple of TICK_SPACING
    /// @param minInitialBuyTokens slippage floor for the optional initial buy funded by msg.value
    function initialize(
        address hook_,
        address token_,
        address treasury_,
        address agent_,
        int24 startTick,
        uint256 minInitialBuyTokens
    ) external payable nonReentrant {
        // The launch graph is deployed and initialized inside the launch wallet's own transaction.
        if (tx.origin != launchWallet) revert UnauthorizedLaunch();
        if (launched) revert AlreadyLaunched();
        if (hook_ == address(0) || token_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        int24 minTick = TickMath.minUsableTick(TICK_SPACING);
        if (startTick % TICK_SPACING != 0 || startTick <= minTick || startTick >= TickMath.maxUsableTick(TICK_SPACING)) {
            revert InvalidStartTick(startTick);
        }
        launched = true;
        hook = hook_;
        token = token_;
        treasury = treasury_;
        tickLower = minTick;
        tickUpper = startTick;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token_),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook_)
        });
        _key = key;
        ICortexHookRegistrar(hook_).registerPool(key, treasury_, launchWallet, agent_, TickMath.getSqrtPriceAtTick(startTick));

        uint256 supply = IERC20(token_).balanceOf(address(this));
        (uint128 liquidity, uint256 boughtTokens) =
            abi.decode(poolManager.unlock(abi.encode(Action.Seed, supply, msg.value)), (uint128, uint256));
        lockedLiquidity = liquidity;
        if (boughtTokens < minInitialBuyTokens) revert InsufficientInitialBuy(boughtTokens, minInitialBuyTokens);

        // Rounding dust that did not fit the position is burned, never kept.
        uint256 dust = IERC20(token_).balanceOf(address(this));
        if (dust != 0) ERC20Burnable(token_).burn(dust);

        emit Launched(hook_, token_, treasury_, startTick, liquidity, supply - dust, msg.value, boughtTokens);
    }

    /// @notice Sends LP fees earned by the locked position to the treasury (ETH -> buybacks, tokens -> burn).
    function collectLpFees() external nonReentrant returns (uint256 ethAmount, uint256 tokenAmount) {
        if (!launched) revert NotLaunched();
        (ethAmount, tokenAmount) = abi.decode(poolManager.unlock(abi.encode(Action.CollectFees, 0, 0)), (uint256, uint256));
        emit LpFeesCollected(ethAmount, tokenAmount);
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_reentrancyGuardEntered()) revert UnexpectedUnlock();
        (Action action, uint256 supply, uint256 buyEth) = abi.decode(data, (Action, uint256, uint256));
        PoolKey memory key = _key;
        if (action == Action.Seed) return _seed(key, supply, buyEth);
        return _collect(key);
    }

    function _seed(PoolKey memory key, uint256 supply, uint256 buyEth) private returns (bytes memory) {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), supply
        );
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: POSITION_SALT
            }),
            ""
        );
        // The range sits entirely below the start price, so only the token side is owed.
        key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);

        uint256 boughtTokens;
        if (buyEth != 0) {
            BalanceDelta swapDelta = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(buyEth),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            key.currency0.settle(poolManager, address(this), uint256(uint128(-swapDelta.amount0())), false);
            boughtTokens = uint256(uint128(swapDelta.amount1()));
            key.currency1.take(poolManager, launchWallet, boughtTokens, false);
            uint256 unspent = buyEth - uint256(uint128(-swapDelta.amount0()));
            if (unspent != 0) _refund(unspent);
        }
        return abi.encode(liquidity, boughtTokens);
    }

    function _collect(PoolKey memory key) private returns (bytes memory) {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: POSITION_SALT }),
            ""
        );
        uint256 ethAmount = uint256(uint128(delta.amount0()));
        uint256 tokenAmount = uint256(uint128(delta.amount1()));
        if (ethAmount != 0) key.currency0.take(poolManager, treasury, ethAmount, false);
        if (tokenAmount != 0) key.currency1.take(poolManager, treasury, tokenAmount, false);
        return abi.encode(ethAmount, tokenAmount);
    }

    function _refund(uint256 amount) private {
        (bool ok,) = launchWallet.call{ value: amount }("");
        if (!ok) {
            // Never trap ETH: if the wallet cannot receive it, it funds buybacks instead.
            (ok,) = treasury.call{ value: amount }("");
            if (!ok) revert UnexpectedUnlock();
        }
    }
}
