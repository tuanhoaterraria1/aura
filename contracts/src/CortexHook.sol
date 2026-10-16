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
///           - 1.00% creator fee, fixed forever, for the creator recipient bound at launch (the launch wallet).
///           - a treasury fee chosen by the AI agent (0%..3%, max 0.5% change per update, at least 15 minutes
///             between updates, every update expires within 24 hours back to the 0.70% base). Each update anchors
///             a hash and URI of the agent's published reasoning onchain.
///         There is no opening, anti-sniper or other time-based fee: from the first block the all-in hook fee is
///         1.30% + the current treasury fee (1.30%..4.30%).
///         Accrued fees are paid out by the permissionless `distribute()` to their fixed recipients. The treasury fee
///         can only fund buyback-and-burn in `CortexTreasury`; nobody can withdraw it.
contract CortexHook is BaseHook, IUnlockCallback, ReentrancyGuardTransient {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using SafeCast for *;

    struct Fees {
        uint256 platform;
        uint256 creator;
        uint256 treasury;
    }

    uint256 public constant PPM = 1_000_000;
    address public constant PLATFORM_FEE_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    uint24 public constant PLATFORM_FEE_PPM = 3_000;
    uint24 public constant CREATOR_FEE_PPM = 10_000;
    uint24 public constant AGENT_FEE_BASE_PPM = 7_000;
    uint24 public constant AGENT_FEE_CAP_PPM = 30_000;
    uint24 public constant AGENT_FEE_MAX_STEP_PPM = 5_000;
    uint32 public constant AGENT_MIN_UPDATE_INTERVAL = 15 minutes;
    uint32 public constant AGENT_MAX_TTL = 24 hours;

    bytes4 private constant DISTRIBUTE_UNLOCK_MAGIC = bytes4(keccak256("CORTEX_HOOK_DISTRIBUTE_V2"));
    Currency private constant NATIVE = Currency.wrap(address(0));

    /// @notice Launcher allowed to bind and initialize the single pool.
    address public immutable registrar;

    bool public poolRegistered;
    bytes32 public poolId;
    PoolKey private _poolKey;
    address public treasury;
    /// @notice Receives the fixed creator fee. Bound once at launch; there is no setter.
    address public creatorFeeRecipient;
    address public admin;
    address public agent;
    uint64 public launchBlock;

    uint24 public agentFeePpm;
    uint64 public agentFeeExpiresAt;
    uint64 public lastAgentUpdate;
    uint64 public regimeNonce;

    uint256 public platformFeesAccrued;
    uint256 public creatorFeesAccrued;
    uint256 public treasuryFeesAccrued;
    uint256 public totalPlatformFees;
    uint256 public totalCreatorFees;
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
        bytes32 indexed poolId,
        address indexed token,
        address indexed treasury,
        address creatorFeeRecipient,
        address admin,
        address agent
    );
    event FeesAccrued(
        address indexed sender,
        bool indexed isBuy,
        uint256 grossEth,
        uint256 platformFee,
        uint256 creatorFee,
        uint256 treasuryFee,
        uint24 treasuryFeePpm
    );
    event FeesDistributed(uint256 platformAmount, uint256 creatorAmount, uint256 treasuryAmount);
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
    ///         The launch wallet becomes both the admin and the permanent creator fee recipient.
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
        creatorFeeRecipient = admin_;
        admin = admin_;
        agent = agent_;
        agentFeePpm = AGENT_FEE_BASE_PPM;
        launchBlock = uint64(block.number);

        emit PoolRegistered(poolId, Currency.unwrap(key.currency1), treasury_, admin_, admin_, agent_);
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

    /// @notice Transfers or renounces (address(0)) the admin role. The admin can only rotate the agent key; it cannot
    ///         change any fee rate or the creator fee recipient.
    function setAdmin(address newAdmin) external {
        if (msg.sender != admin) revert Unauthorized();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    function currentAgentFeePpm() public view returns (uint24) {
        return block.timestamp >= agentFeeExpiresAt ? AGENT_FEE_BASE_PPM : agentFeePpm;
    }

    /// @notice Treasury fee every swap pays right now (platform and creator fees excluded). Same for all senders.
    function treasuryFeePpmFor(address) public view returns (uint24) {
        return currentAgentFeePpm();
    }

    /// @notice Fees for a swap whose gross ETH leg is known (exact-input buys, exact-input sells).
    function feesForGross(uint256 grossEth, uint24 treasuryPpm) public pure returns (Fees memory fees) {
        fees.platform = FullMath.mulDivRoundingUp(grossEth, PLATFORM_FEE_PPM, PPM);
        fees.creator = FullMath.mulDivRoundingUp(grossEth, CREATOR_FEE_PPM, PPM);
        fees.treasury = FullMath.mulDivRoundingUp(grossEth, treasuryPpm, PPM);
    }

    /// @notice Fees for a swap where only the ETH leg net of fees is known (exact-output buys and sells).
    ///         The total is sized to cover the full combined rate on the resulting gross leg `net + total`; the
    ///         platform share is the full rounded-up 0.3% of that gross leg.
    function feesForNet(uint256 netEth, uint24 treasuryPpm) public pure returns (Fees memory fees) {
        uint256 rate = uint256(PLATFORM_FEE_PPM) + CREATOR_FEE_PPM + treasuryPpm;
        uint256 total = FullMath.mulDivRoundingUp(netEth, rate, PPM - rate);
        uint256 gross = netEth + total;
        fees.platform = FullMath.mulDivRoundingUp(gross, PLATFORM_FEE_PPM, PPM);
        uint256 creator = FullMath.mulDivRoundingUp(gross, CREATOR_FEE_PPM, PPM);
        uint256 remaining = total - fees.platform;
        fees.creator = creator < remaining ? creator : remaining;
        fees.treasury = remaining - fees.creator;
    }

    function totalFee(Fees memory fees) public pure returns (uint256) {
        return fees.platform + fees.creator + fees.treasury;
    }

    // ---------------------------------------------------------------- payout

    /// @notice Pays every accrued fee to its fixed recipient: Programmable, the creator and the treasury.
    ///         Permissionless; recipients cannot be chosen by the caller.
    function distribute()
        external
        nonReentrant
        returns (uint256 platformAmount, uint256 creatorAmount, uint256 treasuryAmount)
    {
        platformAmount = platformFeesAccrued;
        creatorAmount = creatorFeesAccrued;
        treasuryAmount = treasuryFeesAccrued;
        if (platformAmount + creatorAmount + treasuryAmount == 0) revert NothingToDistribute();
        platformFeesAccrued = 0;
        creatorFeesAccrued = 0;
        treasuryFeesAccrued = 0;
        bytes memory result = poolManager.unlock(
            abi.encode(DISTRIBUTE_UNLOCK_MAGIC, Fees({ platform: platformAmount, creator: creatorAmount, treasury: treasuryAmount }))
        );
        if (result.length != 0) revert UnexpectedUnlock();
        emit FeesDistributed(platformAmount, creatorAmount, treasuryAmount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_reentrancyGuardEntered()) revert UnexpectedUnlock();
        (bytes4 magic, Fees memory fees) = abi.decode(data, (bytes4, Fees));
        if (magic != DISTRIBUTE_UNLOCK_MAGIC) revert UnexpectedUnlock();
        NATIVE.settle(poolManager, address(this), totalFee(fees), true);
        if (fees.platform != 0) NATIVE.take(poolManager, PLATFORM_FEE_RECIPIENT, fees.platform, false);
        if (fees.creator != 0) NATIVE.take(poolManager, creatorFeeRecipient, fees.creator, false);
        if (fees.treasury != 0) NATIVE.take(poolManager, treasury, fees.treasury, false);
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

        uint24 treasuryPpm = treasuryFeePpmFor(sender);
        uint256 specified = SignedMath.abs(params.amountSpecified);
        Fees memory fees;
        uint256 expectedPoolAmount;
        if (exactInput) {
            // Exact-input buy: `specified` is the gross ETH input.
            fees = feesForGross(specified, treasuryPpm);
            uint256 total = totalFee(fees);
            if (total >= specified) revert FeeExceedsAmount(specified, total);
            expectedPoolAmount = specified - total;
            _accrue(sender, true, specified, fees, treasuryPpm);
        } else {
            // Exact-output sell: `specified` is the net ETH the seller receives; the pool pays out net + fee.
            fees = feesForNet(specified, treasuryPpm);
            expectedPoolAmount = specified + totalFee(fees);
            _accrue(sender, false, expectedPoolAmount, fees, treasuryPpm);
        }
        _pendingSpecifiedPoolAmountPlusOne = expectedPoolAmount + 1;
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(totalFee(fees)), 0), 0);
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

        uint24 treasuryPpm = treasuryFeePpmFor(sender);
        Fees memory fees;
        if (exactInput) {
            // Exact-input sell: the pool's ETH output is the gross ETH leg; the fee comes out of it.
            fees = feesForGross(poolEth, treasuryPpm);
            uint256 total = totalFee(fees);
            if (total >= poolEth) revert FeeExceedsAmount(poolEth, total);
            _accrue(sender, false, poolEth, fees, treasuryPpm);
        } else {
            // Exact-output buy: the buyer pays the pool's ETH input plus the fee on top.
            fees = feesForNet(poolEth, treasuryPpm);
            _accrue(sender, true, poolEth + totalFee(fees), fees, treasuryPpm);
        }
        return (IHooks.afterSwap.selector, _toInt128(totalFee(fees)));
    }

    // ---------------------------------------------------------------- internals

    function _accrue(address sender, bool isBuy, uint256 grossEth, Fees memory fees, uint24 treasuryPpm) private {
        if (grossEth == 0) return;
        platformFeesAccrued += fees.platform;
        creatorFeesAccrued += fees.creator;
        treasuryFeesAccrued += fees.treasury;
        totalPlatformFees += fees.platform;
        totalCreatorFees += fees.creator;
        totalTreasuryFees += fees.treasury;
        emit FeesAccrued(sender, isBuy, grossEth, fees.platform, fees.creator, fees.treasury, treasuryPpm);
        // Backed ERC-6909 claims: no ETH leaves the PoolManager mid-swap, so this works before the swapper settles.
        uint256 total = totalFee(fees);
        if (total != 0) NATIVE.take(poolManager, address(this), total, true);
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
