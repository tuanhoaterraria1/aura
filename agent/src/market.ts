import { formatEther, type Address, type Hex, type PublicClient } from "viem";
import {
  POOL_MANAGER,
  chainlinkAbi,
  erc20Abi,
  feesAccruedEvent,
  hookAbi,
  poolSwapEvent,
  stateViewAbi,
  treasuryAbi,
} from "./abi.ts";
import type { Config } from "./config.ts";

export interface Addresses {
  hook: Address;
  launcher: Address;
  treasury: Address;
  token: Address;
  poolId: Hex;
}

export interface FlowStats {
  blocks: number;
  buys: number;
  sells: number;
  buyVolumeEth: number;
  sellVolumeEth: number;
  netFlowEth: number;
  largestBuyEth: number;
  largestSellEth: number;
}

export interface MarketSnapshot {
  takenAt: string;
  blockNumber: string;
  ethUsd: number | null;
  token: { symbol: string; totalSupply: number; burned: number };
  price: {
    tick: number;
    tokensPerEth: number;
    ethPerToken: number;
    marketCapEth: number;
    marketCapUsd: number | null;
    changeShortPct: number | null;
    changeLongPct: number | null;
    realizedVolatilityTicks: number | null;
  };
  flowShort: FlowStats;
  flowLong: FlowStats;
  hook: {
    agent: Address;
    currentTreasuryFeePpm: number;
    regimeExpiresInMinutes: number;
    minutesSinceLastUpdate: number | null;
    nextUpdateAllowedInMinutes: number;
    blocksSinceLaunch: number;
    regimeNonce: string;
    platformFeesAccruedEth: number;
    treasuryFeesAccruedEth: number;
    lifetimePlatformFeesEth: number;
    lifetimeTreasuryFeesEth: number;
  };
  treasury: {
    balanceEth: number;
    maxBuybackEth: number;
    minutesUntilBuybackAllowed: number;
    lifetimeEthSpent: number;
    lifetimeTokensBurned: number;
  };
}

/** Raw values the guardrails and executor need, kept exact (bigint) instead of rounded for the model. */
export interface ChainState {
  now: bigint;
  currentTreasuryFeePpm: number;
  lastAgentUpdate: bigint;
  agentFeeExpiresAt: bigint;
  agent: Address;
  treasuryBalance: bigint;
  maxBuybackWei: bigint;
  lastBuybackAt: bigint;
  treasuryFeesAccrued: bigint;
  platformFeesAccrued: bigint;
  tokensPerEth: number;
}

export async function resolveAddresses(client: PublicClient, config: Config): Promise<Addresses> {
  const read = <T>(functionName: string) =>
    client.readContract({ address: config.hook, abi: hookAbi, functionName: functionName as never }) as Promise<T>;
  const [key, poolId, launcher, treasury] = await Promise.all([
    read<{ currency1: Address }>("poolKey"),
    read<Hex>("poolId"),
    read<Address>("registrar"),
    read<Address>("treasury"),
  ]);
  return { hook: config.hook, launcher, treasury, token: key.currency1, poolId };
}

export async function takeSnapshot(
  client: PublicClient,
  config: Config,
  addresses: Addresses,
): Promise<{ snapshot: MarketSnapshot; state: ChainState }> {
  const block = await client.getBlock();
  const hook = { address: addresses.hook, abi: hookAbi } as const;
  const treasury = { address: addresses.treasury, abi: treasuryAbi } as const;

  const [
    agent,
    currentFee,
    expiresAt,
    lastUpdate,
    regimeNonce,
    platformAccrued,
    treasuryAccrued,
    totalPlatform,
    totalTreasury,
    launchBlock,
    maxBuyback,
    lastBuyback,
    ethSpent,
    tokensBurned,
    totalSupply,
    symbol,
    treasuryBalance,
  ] = await Promise.all([
    client.readContract({ ...hook, functionName: "agent" }),
    client.readContract({ ...hook, functionName: "currentAgentFeePpm" }),
    client.readContract({ ...hook, functionName: "agentFeeExpiresAt" }),
    client.readContract({ ...hook, functionName: "lastAgentUpdate" }),
    client.readContract({ ...hook, functionName: "regimeNonce" }),
    client.readContract({ ...hook, functionName: "platformFeesAccrued" }),
    client.readContract({ ...hook, functionName: "treasuryFeesAccrued" }),
    client.readContract({ ...hook, functionName: "totalPlatformFees" }),
    client.readContract({ ...hook, functionName: "totalTreasuryFees" }),
    client.readContract({ ...hook, functionName: "launchBlock" }),
    client.readContract({ ...treasury, functionName: "maxBuybackEth" }),
    client.readContract({ ...treasury, functionName: "lastBuybackAt" }),
    client.readContract({ ...treasury, functionName: "totalEthSpent" }),
    client.readContract({ ...treasury, functionName: "totalTokensBurned" }),
    client.readContract({ address: addresses.token, abi: erc20Abi, functionName: "totalSupply" }),
    client.readContract({ address: addresses.token, abi: erc20Abi, functionName: "symbol" }),
    client.getBalance({ address: addresses.treasury }),
  ]);

  const fromLong = block.number > config.longWindowBlocks ? block.number - config.longWindowBlocks : 0n;
  const fromShort = block.number > config.shortWindowBlocks ? block.number - config.shortWindowBlocks : 0n;
  const [feeLogs, swapLogs] = await Promise.all([
    client.getLogs({ address: addresses.hook, event: feesAccruedEvent, fromBlock: fromLong, toBlock: block.number }),
    client.getLogs({
      address: POOL_MANAGER,
      event: poolSwapEvent,
      args: { id: addresses.poolId },
      fromBlock: fromLong,
      toBlock: block.number,
    }),
  ]);

  const tick = await currentTick(client, config, addresses.poolId, swapLogs);
  const tokensPerEth = 1.0001 ** tick;
  const ethPerToken = 1 / tokensPerEth;
  const supply = Number(formatEther(totalSupply));
  const ethUsd = await readEthUsd(client, config);
  const marketCapEth = supply * ethPerToken;

  const flow = (fromBlock: bigint): FlowStats => {
    const stats: FlowStats = {
      blocks: Number(block.number - fromBlock),
      buys: 0,
      sells: 0,
      buyVolumeEth: 0,
      sellVolumeEth: 0,
      netFlowEth: 0,
      largestBuyEth: 0,
      largestSellEth: 0,
    };
    for (const log of feeLogs) {
      if ((log.blockNumber ?? 0n) < fromBlock) continue;
      const gross = Number(formatEther(log.args.grossEth ?? 0n));
      if (log.args.isBuy) {
        stats.buys += 1;
        stats.buyVolumeEth += gross;
        stats.largestBuyEth = Math.max(stats.largestBuyEth, gross);
      } else {
        stats.sells += 1;
        stats.sellVolumeEth += gross;
        stats.largestSellEth = Math.max(stats.largestSellEth, gross);
      }
    }
    stats.netFlowEth = stats.buyVolumeEth - stats.sellVolumeEth;
    return round(stats);
  };

  const ticks = swapLogs.map((log) => ({ block: log.blockNumber ?? 0n, tick: Number(log.args.tick ?? 0) }));
  const changeSince = (fromBlock: bigint): number | null => {
    const first = ticks.find((entry) => entry.block >= fromBlock);
    return first ? (1.0001 ** (first.tick - tick) - 1) * 100 : null;
  };
  const tickSteps = ticks.slice(1).map((entry, index) => entry.tick - ticks[index]!.tick);
  const volatility = tickSteps.length >= 2
    ? Math.sqrt(tickSteps.reduce((sum, step) => sum + step * step, 0) / tickSteps.length)
    : null;

  const now = block.timestamp;
  const minutesUntil = (at: bigint) => (at > now ? Number(at - now) / 60 : 0);
  const snapshot: MarketSnapshot = {
    takenAt: new Date(Number(now) * 1000).toISOString(),
    blockNumber: block.number.toString(),
    ethUsd,
    token: { symbol, totalSupply: supply, burned: Number(formatEther(tokensBurned)) },
    price: round({
      tick,
      tokensPerEth,
      ethPerToken,
      marketCapEth,
      marketCapUsd: ethUsd === null ? null : marketCapEth * ethUsd,
      // Price in ETH per token moves opposite to the tick.
      changeShortPct: changeSince(fromShort),
      changeLongPct: changeSince(fromLong),
      realizedVolatilityTicks: volatility,
    }),
    flowShort: flow(fromShort),
    flowLong: flow(fromLong),
    hook: round({
      agent,
      currentTreasuryFeePpm: currentFee,
      regimeExpiresInMinutes: minutesUntil(expiresAt),
      minutesSinceLastUpdate: lastUpdate === 0n ? null : Number(now - lastUpdate) / 60,
      nextUpdateAllowedInMinutes: lastUpdate === 0n ? 0 : minutesUntil(lastUpdate + 900n),
      blocksSinceLaunch: Number(block.number - launchBlock),
      regimeNonce: regimeNonce.toString(),
      platformFeesAccruedEth: Number(formatEther(platformAccrued)),
      treasuryFeesAccruedEth: Number(formatEther(treasuryAccrued)),
      lifetimePlatformFeesEth: Number(formatEther(totalPlatform)),
      lifetimeTreasuryFeesEth: Number(formatEther(totalTreasury)),
    }),
    treasury: round({
      balanceEth: Number(formatEther(treasuryBalance)),
      maxBuybackEth: Number(formatEther(maxBuyback)),
      minutesUntilBuybackAllowed: lastBuyback === 0n ? 0 : minutesUntil(lastBuyback + 3600n),
      lifetimeEthSpent: Number(formatEther(ethSpent)),
      lifetimeTokensBurned: Number(formatEther(tokensBurned)),
    }),
  };

  const state: ChainState = {
    now,
    currentTreasuryFeePpm: currentFee,
    lastAgentUpdate: lastUpdate,
    agentFeeExpiresAt: expiresAt,
    agent,
    treasuryBalance,
    maxBuybackWei: maxBuyback,
    lastBuybackAt: lastBuyback,
    treasuryFeesAccrued: treasuryAccrued,
    platformFeesAccrued: platformAccrued,
    tokensPerEth,
  };
  return { snapshot, state };
}

async function currentTick(
  client: PublicClient,
  config: Config,
  poolId: Hex,
  swapLogs: { args: { tick?: number } }[],
): Promise<number> {
  try {
    const [, tick] = await client.readContract({
      address: config.stateView,
      abi: stateViewAbi,
      functionName: "getSlot0",
      args: [poolId],
    });
    return tick;
  } catch {
    const last = swapLogs.at(-1)?.args.tick;
    if (last === undefined) throw new Error("cannot read the pool tick from StateView or recent swaps");
    return last;
  }
}

async function readEthUsd(client: PublicClient, config: Config): Promise<number | null> {
  try {
    const [, answer] = await client.readContract({
      address: config.ethUsdFeed,
      abi: chainlinkAbi,
      functionName: "latestRoundData",
    });
    return Number(answer) / 1e8;
  } catch {
    return null;
  }
}

/** Rounds every number to 6 significant digits so the prompt stays compact and stable. */
function round<T extends object>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).map(([key, entry]) => [
      key,
      typeof entry === "number" && Number.isFinite(entry) ? Number(entry.toPrecision(6)) : entry,
    ]),
  ) as T;
}
