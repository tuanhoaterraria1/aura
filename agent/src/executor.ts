import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  createWalletClient,
  http,
  keccak256,
  toBytes,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import { hookAbi, launcherAbi, treasuryAbi } from "./abi.ts";
import type { Decision } from "./brain.ts";
import type { Config } from "./config.ts";
import type { Plan } from "./guardrails.ts";
import type { Addresses, ChainState, MarketSnapshot } from "./market.ts";

export interface ReasoningRecord {
  schemaVersion: "cortex.reasoning.v1";
  chainId: 1;
  hook: string;
  decidedAt: string;
  model: string;
  snapshot: MarketSnapshot;
  decision: Decision;
  applied: {
    feePpm: number | null;
    ttlSeconds: number | null;
    buybackWei: string | null;
    minTokensOut: string | null;
    notes: string[];
  };
}

/** Deterministic JSON (sorted keys) so the onchain hash can be recomputed from the published file. */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(value, (_key, entry) =>
    entry && typeof entry === "object" && !Array.isArray(entry)
      ? Object.fromEntries(Object.entries(entry).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
      : typeof entry === "bigint"
        ? entry.toString()
        : entry);
}

export class Executor {
  private readonly wallet: WalletClient | undefined;
  private readonly account: PrivateKeyAccount | undefined;
  private readonly client: PublicClient;
  private readonly config: Config;
  private readonly addresses: Addresses;

  constructor(client: PublicClient, config: Config, addresses: Addresses) {
    this.client = client;
    this.config = config;
    this.addresses = addresses;
    if (config.agentPrivateKey) {
      this.account = privateKeyToAccount(config.agentPrivateKey);
      this.wallet = createWalletClient({ account: this.account, chain: mainnet, transport: http(config.rpcUrl) });
    }
  }

  get agentAddress(): string | undefined {
    return this.account?.address;
  }

  async recentDecisions(limit = 5): Promise<unknown[]> {
    try {
      const files = (await readdir(this.config.reasoningDir)).filter((file) => file.endsWith(".json"));
      const records = await Promise.all(
        files.map(async (file) => JSON.parse(await readFile(path.join(this.config.reasoningDir, file), "utf8")) as ReasoningRecord),
      );
      return records
        .sort((a, b) => a.decidedAt.localeCompare(b.decidedAt))
        .slice(-limit)
        .map((record) => ({
          decidedAt: record.decidedAt,
          regime: record.decision.regime,
          appliedFeePpm: record.applied.feePpm,
          buybackWei: record.applied.buybackWei,
          rationale: record.decision.rationale,
        }));
    } catch {
      return [];
    }
  }

  /** Writes the reasoning file and returns its keccak256 and public URI. */
  async publish(record: ReasoningRecord): Promise<{ hash: Hex; uri: string }> {
    const body = canonicalJson(record);
    const hash = keccak256(toBytes(body));
    await mkdir(this.config.reasoningDir, { recursive: true });
    await writeFile(path.join(this.config.reasoningDir, `${hash}.json`), body);
    await mkdir(this.config.postsDir, { recursive: true });
    await writeFile(
      path.join(this.config.postsDir, `${record.decidedAt.replace(/[:.]/g, "-")}.txt`),
      `${record.decision.publicPost}\n`,
    );
    const uri = this.config.reasoningBaseUrl ? `${this.config.reasoningBaseUrl}/${hash}.json` : `cortex-reasoning:${hash}`;
    return { hash, uri };
  }

  /** Moves accrued hook fees and LP fees into the treasury so buybacks can use them. */
  async housekeeping(state: ChainState): Promise<void> {
    if (state.treasuryFeesAccrued + state.platformFeesAccrued >= this.config.minDistributeWei) {
      await this.send("hook.distribute", { address: this.addresses.hook, abi: hookAbi, functionName: "distribute" });
    }
    await this.send("launcher.collectLpFees", {
      address: this.addresses.launcher,
      abi: launcherAbi,
      functionName: "collectLpFees",
    });
    await this.send("treasury.burnHeldTokens", {
      address: this.addresses.treasury,
      abi: treasuryAbi,
      functionName: "burnHeldTokens",
    });
  }

  async apply(plan: Plan, reasoning: { hash: Hex; uri: string }): Promise<void> {
    if (plan.fee) {
      await this.send("hook.setAgentFee", {
        address: this.addresses.hook,
        abi: hookAbi,
        functionName: "setAgentFee",
        args: [plan.fee.feePpm, plan.fee.ttlSeconds, reasoning.hash, reasoning.uri],
      });
    }
    if (plan.buyback) {
      await this.send("treasury.buyback", {
        address: this.addresses.treasury,
        abi: treasuryAbi,
        functionName: "buyback",
        args: [plan.buyback.ethWei, plan.buyback.minTokensOut, reasoning.hash],
      });
    }
  }

  /** Simulates first; only broadcasts when DRY_RUN=false. A failed simulation is logged and skipped. */
  private async send(label: string, call: Parameters<PublicClient["simulateContract"]>[0]): Promise<void> {
    const account = this.account?.address;
    try {
      const { request } = await this.client.simulateContract({ ...call, account } as never);
      if (this.config.dryRun || !this.wallet) {
        console.log(`[dry-run] ${label} would succeed`);
        return;
      }
      const hash = await this.wallet.writeContract(request as never);
      const receipt = await this.client.waitForTransactionReceipt({ hash });
      console.log(`[tx] ${label} ${receipt.status} ${hash}`);
    } catch (error) {
      const message = error instanceof Error ? error.message.split("\n")[0] : String(error);
      console.warn(`[skip] ${label}: ${message}`);
    }
  }
}
