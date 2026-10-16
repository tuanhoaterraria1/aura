import { parseEther } from "viem";
import type { Decision } from "./brain.ts";
import type { ChainState } from "./market.ts";

// Mirrors the immutable constants in CortexHook / CortexTreasury, so a decision the chain would reject is never sent.
export const FEE_CAP_PPM = 30_000;
export const MAX_STEP_PPM = 5_000;
export const MIN_UPDATE_INTERVAL = 15n * 60n;
export const MAX_TTL_MINUTES = 24 * 60;
export const MIN_TTL_MINUTES = 15;
export const BUYBACK_COOLDOWN = 60n * 60n;
export const PLATFORM_FEE_PPM = 3_000;
export const CREATOR_FEE_PPM = 10_000;
/** Ignore fee changes smaller than this unless the current regime is about to lapse. */
export const MIN_MEANINGFUL_CHANGE_PPM = 250;

export interface FeePlan {
  feePpm: number;
  ttlSeconds: number;
}

export interface BuybackPlan {
  ethWei: bigint;
  minTokensOut: bigint;
}

export interface Plan {
  fee: FeePlan | null;
  buyback: BuybackPlan | null;
  notes: string[];
}

export function applyGuardrails(decision: Decision, state: ChainState, slippageBps: number, intervalMinutes: number): Plan {
  const notes: string[] = [];
  let fee: FeePlan | null = null;
  let buyback: BuybackPlan | null = null;

  // ---- fee
  const current = state.currentTreasuryFeePpm;
  let target = Math.min(Math.max(decision.treasuryFeePpm, 0), FEE_CAP_PPM);
  if (target !== decision.treasuryFeePpm) notes.push(`fee clamped to cap: ${decision.treasuryFeePpm} -> ${target}`);
  if (Math.abs(target - current) > MAX_STEP_PPM) {
    const stepped = current + Math.sign(target - current) * MAX_STEP_PPM;
    notes.push(`fee step limited: ${target} -> ${stepped}`);
    target = stepped;
  }
  const ttlMinutes = Math.min(Math.max(decision.ttlMinutes, MIN_TTL_MINUTES), MAX_TTL_MINUTES);
  const updateAllowed = state.lastAgentUpdate === 0n || state.now >= state.lastAgentUpdate + MIN_UPDATE_INTERVAL;
  const expiresSoon = state.agentFeeExpiresAt <= state.now + BigInt(intervalMinutes * 60);
  const meaningful = Math.abs(target - current) >= MIN_MEANINGFUL_CHANGE_PPM;
  if (!updateAllowed) {
    notes.push("fee update skipped: onchain rate limit");
  } else if (!state.agent || state.agent === "0x0000000000000000000000000000000000000000") {
    notes.push("fee update skipped: no agent set on the hook");
  } else if (meaningful || (expiresSoon && target !== 7_000)) {
    fee = { feePpm: target, ttlSeconds: ttlMinutes * 60 };
  } else {
    notes.push("fee unchanged: no meaningful change");
  }

  // ---- buyback
  let requested: bigint;
  try {
    requested = parseEther(decision.buybackEth);
  } catch {
    requested = 0n;
    notes.push(`invalid buybackEth ${decision.buybackEth}`);
  }
  if (requested > 0n) {
    // Fees accrued in the hook reach the treasury in the same run (distribute), but maxBuybackWei was read before that.
    const cooldownOver = state.lastBuybackAt === 0n || state.now >= state.lastBuybackAt + BUYBACK_COOLDOWN;
    const ethWei = requested > state.maxBuybackWei ? state.maxBuybackWei : requested;
    if (!cooldownOver) {
      notes.push("buyback skipped: cooldown");
    } else if (ethWei === 0n) {
      notes.push("buyback skipped: treasury empty");
    } else {
      if (ethWei !== requested) notes.push(`buyback clamped to maxBuybackEth: ${ethWei} wei`);
      // Expected output at the spot price after the hook's fees, minus a slippage allowance.
      const feeFactor = 1 - (PLATFORM_FEE_PPM + CREATOR_FEE_PPM + target) / 1_000_000 - 0.003;
      const expectedTokens = Number(ethWei) * state.tokensPerEth * feeFactor;
      const minTokensOut = BigInt(Math.floor(expectedTokens * (1 - slippageBps / 10_000)));
      buyback = { ethWei, minTokensOut: minTokensOut > 0n ? minTokensOut : 1n };
    }
  }

  return { fee, buyback, notes };
}
