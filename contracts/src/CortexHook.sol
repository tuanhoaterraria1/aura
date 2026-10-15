// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import { BaseHook } from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface ICortexTreasuryBinding {
    function hook() external view returns (address);
}

/// @title CortexHook
/// @notice Uniswap v4 hook for one native-ETH/token pool whose trading fee is steered by an AI agent inside
///         immutable guardrails.
///
///         Every buy and sell is charged on its gross native ETH leg (input on buys, output on sells), rounded up:
///           - 0.30% platform fee, accrued as backed PoolManager claims for the fixed Programmable recipient.
///           - a treasury fee chosen by the AI agent (0%..3%, max 0.5% change per update, at least 15 minutes
///             between updates, every update expires within 24 hours back to the 0.70% base). Each update anchors
///             a hash and URI of the agent's published reasoning onchain.
///           - during the first 30 blocks after launch, a linearly decaying anti-sniper fee (10% -> 0%) replaces
///             the agent fee when higher. The launcher's own initial buy is exempt from it.
///         Accrued fees are paid out by the permissionless `distribute()`. The treasury fee can only fund
///         buyback-and-burn in `CortexTreasury`; nobody can withdraw it.
contract CortexHook is BaseHook, IUnlockCallback, ReentrancyGuardTransient {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using SafeCast for *;

    uint256 public constant PPM = 1_000_000;
    address public constant PLATFORM_FEE_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    uint24 public constant PLATFORM_FEE_PPM = 3_000;
    uint24 public constant AGENT_FEE_BASE_PPM = 7_000;
    uint24 public constant AGENT_FEE_CAP_PPM = 30_000;
    uint24 public constant AGENT_FEE_MAX_STEP_PPM = 5_000;
    uint32 public constant AGENT_MIN_UPDATE_INTERVAL = 15 minutes;
    uint32 public constant AGENT_MAX_TTL = 24 hours;
    uint24 public constant SNIPE_FEE_START_PPM = 100_000;
    uint64 public constant SNIPE_DECAY_BLOCKS = 30;

    bytes4 private constant DISTRIBUTE_UNLOCK_MAGIC = bytes4(keccak256("CORTEX_HOOK_DISTRIBUTE_V1"));
    Currency private constant NATIVE = Currency.wrap(address(0));

    /// @notice Launcher allowed to bind and initialize the single pool.
    address public immutable registrar;

    bool public poolRegistered;
    bytes32 public poolId;
    PoolKey private _poolKey;
    address public treasury;
    address public admin;
    address public agent;
    uint64 public launchBlock;

    uint24 public agentFeePpm;
    uint64 public agentFeeExpiresAt;
    uint64 public lastAgentUpdate;
    uint64 public regimeNonce;

    uint256 public platformFeesAccrued;
    uint256 public treasuryFeesAccrued;
    uint256 public totalPlatformFees;
    uint256 public totalTreasuryFees;
    uint256 private _pendingSpecifiedPoolAmountPlusOne;

    error AgentFeeAboveCap(uint24 feePpm);
    error AgentStepTooLarge(uint24 fromPpm, uint24 toPpm);
    error AgentUpdateTooSoon(uint64 nextAllowedAt);
    error AlreadyRegistered();
    error FeeExceedsAmount(uint256 amount, uint256 fee);
    error InvalidTtl(uint32 ttl);
    error NothingToDistribute();
    error PartialFillUnsupported(uint256 expected, uint256 actual);
    error PendingSpecifiedSwap();
    error PoolNotRegistered();
    error TreasuryMismatch();
    error Unauthorized();
    error UnexpectedUnlock();
    error ZeroAddress();

    event PoolRegistered(
        bytes32 indexed poolId, address indexed token, address indexed treasury, address admin, address agent
    );
    event FeesAccrued(
        address indexed sender,
        bool indexed isBuy,
        uint256 grossEth,
        uint256 platformFee,
        uint256 treasuryFee,
        uint24 treasuryFeePpm
    );
    event FeesDistributed(uint256 platformAmount, uint256 treasuryAmount);
    event AgentRegimeUpdated(
        uint64 indexed nonce,
        uint24 fromPpm,
        uint24 toPpm,
        uint64 expiresAt,
        bytes32 indexed reasoningHash,
        string reasoningURI
    );
    event AgentChanged(address indexed previousAgent, address indexed newAgent);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    constructor(IPoolManager poolManager_, address registrar_) BaseHook(poolManager_) {
        if (address(poolManager_) == address(0) || registrar_ == address(0)) revert ZeroAddress();
        registrar = registrar_;
    }

    // ---------------------------------------------------------------- launch

    /// @notice Binds the one supported ETH/token pool and initializes it. Callable once, by the launcher only.
    function registerPool(
        PoolKey calldata key,
        address treasury_,
        address admin_,
        address agent_,
        uint160 sqrtPriceX96
    ) external nonReentrant returns (int24 tick) {
        if (msg.sender != registrar) revert Unauthorized();
        if (poolRegistered) revert AlreadyRegistered();
        if (treasury_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (ICortexTreasuryBinding(treasury_).hook() != address(this)) revert TreasuryMismatch();
        _validatePoolShape(key);

        _poolKey = key;
        poolId = PoolId.unwrap(key.toId());
        poolRegistered = true;
        treasury = treasury_;
        admin = admin_;
        agent = agent_;
        agentFeePpm = AGENT_FEE_BASE_PPM;
        launchBlock = uint64(block.number);

        emit PoolRegistered(poolId, Currency.unwrap(key.currency1), treasury_, admin_, agent_);
        tick = poolManager.initialize(key, sqrtPriceX96);
    }

    function poolKey() external view returns (PoolKey memory) {
        if (!poolRegistered) revert PoolNotRegistered();
        return _poolKey;
    }

    // ---------------------------------------------------------------- AI agent

    /// @notice The AI agent proposes a new treasury fee. Bounded by immutable cap, step size, rate limit and expiry.
    /// @param newFeePpm treasury fee in parts per million of the gross ETH leg
    /// @param ttl seconds until the regime lapses back to `AGENT_FEE_BASE_PPM`
    /// @param reasoningHash keccak256 of the exact published reasoning document
    /// @param reasoningURI where that reasoning document is published
    function setAgentFee(uint24 newFeePpm, uint32 ttl, bytes32 reasoningHash, string calldata reasoningURI)
        external
    {
        if (msg.sender != agent || agent == address(0)) revert Unauthorized();
        uint64 nextAllowedAt = lastAgentUpdate + AGENT_MIN_UPDATE_INTERVAL;
        if (lastAgentUpdate != 0 && block.timestamp < nextAllowedAt) revert AgentUpdateTooSoon(nextAllowedAt);
        if (newFeePpm > AGENT_FEE_CAP_PPM) revert AgentFeeAboveCap(newFeePpm);
        if (ttl == 0 || ttl > AGENT_MAX_TTL) revert InvalidTtl(ttl);

        uint24 current = currentAgentFeePpm();
        uint24 step = newFeePpm > current ? newFeePpm - current : current - newFeePpm;
        if (step > AGENT_FEE_MAX_STEP_PPM) revert AgentStepTooLarge(current, newFeePpm);

        agentFeePpm = newFeePpm;
        agentFeeExpiresAt = uint64(block.timestamp) + ttl;
        lastAgentUpdate = uint64(block.timestamp);
        emit AgentRegimeUpdated(++regimeNonce, current, newFeePpm, agentFeeExpiresAt, reasoningHash, reasoningURI);
    }

    /// @notice Rotates or revokes (address(0)) the agent key. Revoking resets the fee to the base rate.
    function setAgent(address newAgent) external {
        if (msg.sender != admin) revert Unauthorized();
        emit AgentChanged(agent, newAgent);
        agent = newAgent;
        if (newAgent == address(0)) {
            agentFeePpm = AGENT_FEE_BASE_PPM;
            agentFeeExpiresAt = 0;
        }
    }

    /// @notice Transfers or renounces (address(0)) the admin role. The admin can only rotate the agent key.
    function setAdmin(address newAdmin) external {
        if (msg.sender != admin) revert Unauthorized();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    function currentAgentFeePpm() public view returns (uint24) {
        return block.timestamp >= agentFeeExpiresAt ? AGENT_FEE_BASE_PPM : agentFeePpm;
    }

    function snipeFeePpm() public view returns (uint24) {
        uint64 endBlock = launchBlock + SNIPE_DECAY_BLOCKS;
        if (!poolRegistered || block.number >= endBlock) return 0;
        return uint24(uint256(SNIPE_FEE_START_PPM) * (endBlock - block.number) / SNIPE_DECAY_BLOCKS);
    }

    /// @notice Treasury fee a swap from `sender` pays right now (platform fee excluded).
    function treasuryFeePpmFor(address sender) public view returns (uint24 feePpm) {
        feePpm = currentAgentFeePpm();
        if (sender != registrar) {
            uint24 snipe = snipeFeePpm();
            if (snipe > feePpm) feePpm = snipe;
        }
    }

    /// @notice Fees for a swap whose gross ETH leg is known (exact-input buys, exact-input sells).
    function feesForGross(uint256 grossEth, uint24 treasuryPpm)
        public
        pure
        returns (uint256 platformFee, uint256 treasuryFee)
    {
        platformFee = FullMath.mulDivRoundingUp(grossEth, PLATFORM_FEE_PPM, PPM);
        treasuryFee = FullMath.mulDivRoundingUp(grossEth, treasuryPpm, PPM);
    }

    /// @notice Fees for a swap where only the ETH leg net of fees is known (exact-output buys and sells).
    ///         The fee is sized so that it covers the full rate on the resulting gross leg `net + fee`.
    function feesForNet(uint256 netEth, uint24 treasuryPpm)
        public
        pure
        returns (uint256 platformFee, uint256 treasuryFee)
    {
        uint256 rate = uint256(PLATFORM_FEE_PPM) + treasuryPpm;
        uint256 totalFee = FullMath.mulDivRoundingUp(netEth, rate, PPM - rate);
        platformFee = FullMath.mulDivRoundingUp(netEth + totalFee, PLATFORM_FEE_PPM, PPM);
        treasuryFee = totalFee - platformFee;
    }

    // ---------------------------------------------------------------- payout

    /// @notice Pays every accrued fee: platform share to the fixed Programmable recipient, the rest to the treasury.
    ///         Permissionless; recipients are fixed.
    function distribute() external nonReentrant returns (uint256 platformAmount, uint256 treasuryAmount) {
        platformAmount = platformFeesAccrued;
        treasuryAmount = treasuryFeesAccrued;
        if (platformAmount + treasuryAmount == 0) revert NothingToDistribute();
        platformFeesAccrued = 0;
        treasuryFeesAccrued = 0;
        bytes memory result =
            poolManager.unlock(abi.encode(DISTRIBUTE_UNLOCK_MAGIC, platformAmount, treasuryAmount));
        if (result.length != 0) revert UnexpectedUnlock();
        emit FeesDistributed(platformAmount, treasuryAmount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_reentrancyGuardEntered()) revert UnexpectedUnlock();
        (bytes4 magic, uint256 platformAmount, uint256 treasuryAmount) = abi.decode(data, (bytes4, uint256, uint256));
        if (magic != DISTRIBUTE_UNLOCK_MAGIC) revert UnexpectedUnlock();
        NATIVE.settle(poolManager, address(this), platformAmount + treasuryAmount, true);
        if (platformAmount != 0) NATIVE.take(poolManager, PLATFORM_FEE_RECIPIENT, platformAmount, false);
        if (treasuryAmount != 0) NATIVE.take(poolManager, treasury, treasuryAmount, false);
        return "";
    }

    // ---------------------------------------------------------------- hook callbacks

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (sender != address(this)) revert Unauthorized();
        _requirePool(key);
        return IHooks.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requirePool(key);
        bool exactInput = params.amountSpecified < 0;
        // ETH is always currency0, so it is the specified currency exactly when zeroForOne == exactInput.
        if (params.zeroForOne != exactInput) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        if (_pendingSpecifiedPoolAmountPlusOne != 0) revert PendingSpecifiedSwap();

        bool isBuy = params.zeroForOne;
        uint24 treasuryPpm = treasuryFeePpmFor(sender);
        uint256 specified = SignedMath.abs(params.amountSpecified);
        uint256 platformFee;
        uint256 treasuryFee;
        uint256 expectedPoolAmount;
        if (exactInput) {
            // Exact-input buy: `specified` is the gross ETH input.
            (platformFee, treasuryFee) = feesForGross(specified, treasuryPpm);
            if (platformFee + treasuryFee >= specified) revert FeeExceedsAmount(specified, platformFee + treasuryFee);
            expectedPoolAmount = specified - platformFee - treasuryFee;
            _accrue(sender, isBuy, specified, platformFee, treasuryFee, treasuryPpm);
        } else {
            // Exact-output sell: `specified` is the net ETH the seller receives; the pool pays out net + fee.
            (platformFee, treasuryFee) = feesForNet(specified, treasuryPpm);
            expectedPoolAmount = specified + platformFee + treasuryFee;
            _accrue(sender, isBuy, expectedPoolAmount, platformFee, treasuryFee, treasuryPpm);
        }
        _pendingSpecifiedPoolAmountPlusOne = expectedPoolAmount + 1;
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(platformFee + treasuryFee), 0), 0);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        nonReentrant
        returns (bytes4, int128)
    {
        _requirePool(key);
        bool exactInput = params.amountSpecified < 0;
        uint256 poolEth = SignedMath.abs(int256(delta.amount0()));

        if (params.zeroForOne == exactInput) {
            uint256 pendingPlusOne = _pendingSpecifiedPoolAmountPlusOne;
            if (pendingPlusOne == 0) revert PendingSpecifiedSwap();
            _pendingSpecifiedPoolAmountPlusOne = 0;
            if (poolEth != pendingPlusOne - 1) revert PartialFillUnsupported(pendingPlusOne - 1, poolEth);
            return (IHooks.afterSwap.selector, 0);
        }

        bool isBuy = params.zeroForOne;
        uint24 treasuryPpm = treasuryFeePpmFor(sender);
        uint256 platformFee;
        uint256 treasuryFee;
        if (exactInput) {
            // Exact-input sell: the pool's ETH output is the gross ETH leg; the fee comes out of it.
            (platformFee, treasuryFee) = feesForGross(poolEth, treasuryPpm);
            if (platformFee + treasuryFee >= poolEth) revert FeeExceedsAmount(poolEth, platformFee + treasuryFee);
            _accrue(sender, isBuy, poolEth, platformFee, treasuryFee, treasuryPpm);
        } else {
            // Exact-output buy: the buyer pays the pool's ETH input plus the fee on top.
            (platformFee, treasuryFee) = feesForNet(poolEth, treasuryPpm);
            _accrue(sender, isBuy, poolEth + platformFee + treasuryFee, platformFee, treasuryFee, treasuryPpm);
        }
        return (IHooks.afterSwap.selector, _toInt128(platformFee + treasuryFee));
    }

    // ---------------------------------------------------------------- internals

    function _accrue(
        address sender,
        bool isBuy,
        uint256 grossEth,
        uint256 platformFee,
        uint256 treasuryFee,
        uint24 treasuryPpm
    ) private {
        if (grossEth == 0) return;
        platformFeesAccrued += platformFee;
        treasuryFeesAccrued += treasuryFee;
        totalPlatformFees += platformFee;
        totalTreasuryFees += treasuryFee;
        emit FeesAccrued(sender, isBuy, grossEth, platformFee, treasuryFee, treasuryPpm);
        // Backed ERC-6909 claims: no ETH leaves the PoolManager mid-swap, so this works before the swapper settles.
        uint256 totalFee = platformFee + treasuryFee;
        if (totalFee != 0) NATIVE.take(poolManager, address(this), totalFee, true);
    }

    function _requirePool(PoolKey calldata key) private view {
        if (!poolRegistered) revert PoolNotRegistered();
        if (PoolId.unwrap(key.toId()) != poolId) revert InvalidPool();
    }

    function _validatePoolShape(PoolKey calldata key) private view {
        if (address(key.hooks) != address(this)) revert InvalidPool();
        if (Currency.unwrap(key.currency0) != address(0)) revert InvalidPool();
        if (Currency.unwrap(key.currency1) == address(0)) revert InvalidPool();
        if (key.fee.isDynamicFee() || !key.fee.isValid()) revert InvalidPool();
    }

    function _toInt128(uint256 amount) private pure returns (int128) {
        return amount.toInt256().toInt128();
    }
}
