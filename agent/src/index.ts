import Anthropic from "@anthropic-ai/sdk";
import { createPublicClient, http, type PublicClient } from "viem";
import { mainnet } from "viem/chains";
import { Brain } from "./brain.ts";
import { config } from "./config.ts";
import { Executor, type ReasoningRecord } from "./executor.ts";
import { applyGuardrails } from "./guardrails.ts";
import { resolveAddresses, takeSnapshot, type Addresses } from "./market.ts";

const client = createPublicClient({ chain: mainnet, transport: http(config.rpcUrl) }) as PublicClient;
const brain = new Brain(config.model);

async function tick(addresses: Addresses, executor: Executor): Promise<void> {
  let { snapshot, state } = await takeSnapshot(client, config, addresses);
  if (executor.agentAddress && state.agent.toLowerCase() !== executor.agentAddress.toLowerCase()) {
    console.warn(`hook.agent is ${state.agent}, this key is ${executor.agentAddress}: fee updates and buybacks will be skipped`);
  }

  // Move accrued fees into the treasury first, then re-read so the model sees the real budget.
  await executor.housekeeping(state);
  if (!config.dryRun) ({ snapshot, state } = await takeSnapshot(client, config, addresses));

  const decision = await brain.decide(snapshot, await executor.recentDecisions());
  const plan = applyGuardrails(decision, state, config.buybackSlippageBps, config.intervalMinutes);

  const record: ReasoningRecord = {
    schemaVersion: "cortex.reasoning.v1",
    chainId: 1,
    hook: addresses.hook,
    decidedAt: snapshot.takenAt,
    model: config.model,
    snapshot,
    decision,
    applied: {
      feePpm: plan.fee?.feePpm ?? null,
      ttlSeconds: plan.fee?.ttlSeconds ?? null,
      buybackWei: plan.buyback?.ethWei.toString() ?? null,
      minTokensOut: plan.buyback?.minTokensOut.toString() ?? null,
      notes: plan.notes,
    },
  };
  const reasoning = await executor.publish(record);
  console.log(
    `[decision] ${decision.regime} fee=${plan.fee?.feePpm ?? "unchanged"}ppm buyback=${plan.buyback?.ethWei ?? 0n}wei `
      + `hash=${reasoning.hash}${plan.notes.length ? ` notes=${plan.notes.join("; ")}` : ""}`,
  );
  await executor.apply(plan, reasoning);
}

async function main(): Promise<void> {
  const addresses = await resolveAddresses(client, config);
  const executor = new Executor(client, config, addresses);
  console.log(
    `cortex agent | hook ${addresses.hook} | token ${addresses.token} | model ${config.model} | `
      + `${config.dryRun ? "DRY RUN" : "LIVE"} | every ${config.intervalMinutes} min`,
  );

  const once = process.argv.includes("--once");
  for (;;) {
    try {
      await tick(addresses, executor);
    } catch (error) {
      if (error instanceof Anthropic.RateLimitError) console.warn("[claude] rate limited, retrying next interval");
      else if (error instanceof Anthropic.APIError) console.error(`[claude] API error ${error.status}: ${error.message}`);
      else console.error("[tick] failed:", error);
      if (once) process.exitCode = 1;
    }
    if (once) return;
    await new Promise((resolve) => setTimeout(resolve, config.intervalMinutes * 60_000));
  }
}

await main();
