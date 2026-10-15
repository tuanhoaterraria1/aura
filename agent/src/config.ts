import { getAddress, isAddress, type Address, type Hex } from "viem";

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required (see .env.example)`);
  return value;
}

function optionalAddress(name: string, fallback: Address): Address {
  const value = process.env[name] ?? fallback;
  if (!isAddress(value)) throw new Error(`${name} must be an address`);
  return getAddress(value);
}

function integer(name: string, fallback: number): number {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(`${name} must be a non-negative integer`);
  return value;
}

const hookAddress = required("HOOK_ADDRESS");
if (!isAddress(hookAddress)) throw new Error("HOOK_ADDRESS must be an address");

const privateKey = process.env.AGENT_PRIVATE_KEY;
if (privateKey !== undefined && privateKey !== "" && !/^0x[0-9a-fA-F]{64}$/.test(privateKey)) {
  throw new Error("AGENT_PRIVATE_KEY must be a 0x-prefixed 32-byte hex key");
}

export const config = {
  rpcUrl: required("RPC_URL"),
  hook: getAddress(hookAddress),
  agentPrivateKey: privateKey ? (privateKey as Hex) : undefined,
  // Transactions are only sent when DRY_RUN is explicitly "false".
  dryRun: process.env.DRY_RUN !== "false",
  model: process.env.CLAUDE_MODEL ?? "claude-opus-5-5",
  intervalMinutes: integer("INTERVAL_MINUTES", 20),
  shortWindowBlocks: BigInt(integer("SHORT_WINDOW_BLOCKS", 300)),
  longWindowBlocks: BigInt(integer("LONG_WINDOW_BLOCKS", 1800)),
  buybackSlippageBps: integer("BUYBACK_SLIPPAGE_BPS", 300),
  minDistributeWei: BigInt(process.env.MIN_DISTRIBUTE_WEI ?? "10000000000000000"),
  reasoningDir: process.env.REASONING_DIR ?? "reasoning",
  reasoningBaseUrl: (process.env.REASONING_BASE_URL ?? "").replace(/\/+$/, ""),
  postsDir: process.env.POSTS_DIR ?? "posts",
  // Uniswap v4 StateView and Chainlink ETH/USD on Ethereum Mainnet.
  stateView: optionalAddress("STATE_VIEW_ADDRESS", "0x7ffe42c4a5deea5b0fec41c94c136cf115597227"),
  ethUsdFeed: optionalAddress("ETH_USD_FEED", "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419"),
} as const;

export type Config = typeof config;
