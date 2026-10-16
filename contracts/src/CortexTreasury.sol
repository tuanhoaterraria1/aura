// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface ICortexHookView {
    function agent() external view returns (address);
    function admin() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
    function treasuryFeesAccrued() external view returns (uint256);
    function platformFeesAccrued() external view returns (uint256);
    function distribute() external returns (uint256, uint256, uint256);
}

/// @title CortexTreasury
/// @notice Receives the AI-steered treasury fee and the locked LP's fees. Its only spending path is
///         buyback-and-burn, and only an authorized executor can trigger it: the hook's agent, or the hook's
///         admin while no agent is set. Nobody else can call it; if both roles are renounced, buybacks stop.
///         Each buyback: at most 20% of the ETH balance, at least 1 hour apart, a mandatory nonzero
///         minTokensOut, and a hard price-impact bound (the swap reverts if it would move the price more than
///         ~2% from the pre-trade pool price). There is no owner and no withdraw function.
contract CortexTreasury is IUnlockCallback, ReentrancyGuardTransient {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    uint256 public constant MAX_BUYBACK_BPS = 2_000;
    uint32 public constant BUYBACK_COOLDOWN = 1 hours;
    /// @dev sqrt(0.98) in parts per million: the buyback may move the price by at most ~2%.
    uint256 public constant MAX_IMPACT_SQRT_PRICE_PPM = 989_949;

    IPoolManager public immutable poolManager;
    address public immutable hook;
    address public immutable token;

    uint64 public lastBuybackAt;
    uint256 public totalEthSpent;
    uint256 public totalTokensBurned;

    error BuybackTooLarge(uint256 ethIn, uint256 maxEthIn);
    error BuybackTooSoon(uint64 nextAllowedAt);
    error InsufficientOutput(uint256 received, uint256 minimum);
    error NotPoolManager();
    error Unauthorized();
    error UnexpectedUnlock();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroMinimumOutput();

    event Buyback(address indexed caller, uint256 ethIn, uint256 tokensBurned, bytes32 indexed reasoningHash);
    event TokensBurned(uint256 amount);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address hook_, address token_) {
        if (address(poolManager_) == address(0) || hook_ == address(0) || token_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        hook = hook_;
        token = token_;
    }

    receive() external payable { }

    function maxBuybackEth() public view returns (uint256) {
        return address(this).balance * MAX_BUYBACK_BPS / 10_000;
    }

    /// @notice Buys the token with treasury ETH and burns everything bought.
    /// @param reasoningHash keccak256 of the agent's published reasoning for this buyback (0 if none)
    function buyback(uint256 ethIn, uint256 minTokensOut, bytes32 reasoningHash)
        external
        nonReentrant
        returns (uint256 tokensBurned)
    {
        if (msg.sender != authorizedExecutor() || msg.sender == address(0)) revert Unauthorized();
        if (ethIn == 0) revert ZeroAmount();
        if (minTokensOut == 0) revert ZeroMinimumOutput();
        uint64 nextAllowedAt = lastBuybackAt + BUYBACK_COOLDOWN;
        if (lastBuybackAt != 0 && block.timestamp < nextAllowedAt) revert BuybackTooSoon(nextAllowedAt);
        uint256 maxEthIn = maxBuybackEth();
        if (ethIn > maxEthIn) revert BuybackTooLarge(ethIn, maxEthIn);

        lastBuybackAt = uint64(block.timestamp);
        totalEthSpent += ethIn;
        uint256 bought = abi.decode(poolManager.unlock(abi.encode(ethIn)), (uint256));
        if (bought < minTokensOut) revert InsufficientOutput(bought, minTokensOut);

        tokensBurned = burnHeldTokens();
        emit Buyback(msg.sender, ethIn, tokensBurned, reasoningHash);
    }

    /// @notice The only address allowed to trigger buybacks: the hook's agent, or its admin while no agent is set.
    function authorizedExecutor() public view returns (address) {
        address agent = ICortexHookView(hook).agent();
        return agent != address(0) ? agent : ICortexHookView(hook).admin();
    }

    /// @notice Burns every token the treasury holds (bought back, or received as LP fees). Permissionless.
    function burnHeldTokens() public returns (uint256 amount) {
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return 0;
        totalTokensBurned += amount;
        ERC20Burnable(token).burn(amount);
        emit TokensBurned(amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_reentrancyGuardEntered()) revert UnexpectedUnlock();
        uint256 ethIn = abi.decode(data, (uint256));
        PoolKey memory key = ICortexHookView(hook).poolKey();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        // Buying the token lowers sqrtPrice (token per ETH). Stopping at this limit makes the hook revert the whole
        // buyback (partial fills are rejected), so a buyback never executes beyond the ~2% impact bound.
        uint160 limit = uint160(uint256(sqrtPriceX96) * MAX_IMPACT_SQRT_PRICE_PPM / 1_000_000);
        BalanceDelta delta = poolManager.swap(
            key, SwapParams({ zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: limit }), ""
        );
        key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
        uint256 bought = uint256(uint128(delta.amount1()));
        key.currency1.take(poolManager, address(this), bought, false);
        return abi.encode(bought);
    }
}
