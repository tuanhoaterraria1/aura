import { parseAbi, parseAbiItem } from "viem";

export const hookAbi = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "function poolKey() view returns (PoolKey)",
  "function poolId() view returns (bytes32)",
  "function registrar() view returns (address)",
  "function treasury() view returns (address)",
  "function agent() view returns (address)",
  "function launchBlock() view returns (uint64)",
  "function currentAgentFeePpm() view returns (uint24)",
  "function agentFeeExpiresAt() view returns (uint64)",
  "function lastAgentUpdate() view returns (uint64)",
  "function regimeNonce() view returns (uint64)",
  "function platformFeesAccrued() view returns (uint256)",
  "function treasuryFeesAccrued() view returns (uint256)",
  "function totalPlatformFees() view returns (uint256)",
  "function totalTreasuryFees() view returns (uint256)",
  "function setAgentFee(uint24 newFeePpm, uint32 ttl, bytes32 reasoningHash, string reasoningURI)",
  "function distribute() returns (uint256, uint256, uint256)",
]);

export const treasuryAbi = parseAbi([
  "function lastBuybackAt() view returns (uint64)",
  "function maxBuybackEth() view returns (uint256)",
  "function totalEthSpent() view returns (uint256)",
  "function totalTokensBurned() view returns (uint256)",
  "function buyback(uint256 ethIn, uint256 minTokensOut, bytes32 reasoningHash) returns (uint256)",
  "function burnHeldTokens() returns (uint256)",
]);

export const launcherAbi = parseAbi(["function collectLpFees() returns (uint256, uint256)"]);

export const erc20Abi = parseAbi([
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
]);

export const stateViewAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128)",
]);

export const chainlinkAbi = parseAbi([
  "function latestRoundData() view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80)",
]);

export const feesAccruedEvent = parseAbiItem(
  "event FeesAccrued(address indexed sender, bool indexed isBuy, uint256 grossEth, uint256 platformFee, uint256 creatorFee, uint256 treasuryFee, uint24 treasuryFeePpm)",
);

export const poolSwapEvent = parseAbiItem(
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
);

export const POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90" as const;
