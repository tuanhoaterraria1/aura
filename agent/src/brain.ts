import Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import type { MarketSnapshot } from "./market.ts";

export const DecisionSchema = z.object({
  regime: z.enum(["launch", "calm", "trending_up", "volatile", "dump_pressure", "sniper_or_bot_activity"]),
  treasuryFeePpm: z.number().int(),
  ttlMinutes: z.number().int(),
  buybackEth: z.string().regex(/^\d+(\.\d{1,18})?$/),
  confidence: z.number(),
  rationale: z.string(),
  publicPost: z.string(),
});
export type Decision = z.infer<typeof DecisionSchema>;

// Structured-output schema for the same shape. Ranges are enforced afterwards by the zod parse and the guardrails.
const DECISION_JSON_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["regime", "treasuryFeePpm", "ttlMinutes", "buybackEth", "confidence", "rationale", "publicPost"],
  properties: {
    regime: {
      type: "string",
      enum: ["launch", "calm", "trending_up", "volatile", "dump_pressure", "sniper_or_bot_activity"],
    },
    treasuryFeePpm: { type: "integer", description: "Treasury fee in parts per million of the gross ETH leg." },
    ttlMinutes: { type: "integer", description: "How long the regime stays active before lapsing to the base fee." },
    buybackEth: { type: "string", description: "ETH to spend on buyback-and-burn now, decimal string, \"0\" for none." },
    confidence: { type: "number", description: "0 to 1." },
    rationale: { type: "string", description: "Why, citing the specific numbers from the snapshot. Under 120 words." },
    publicPost: { type: "string", description: "A plain, factual post for holders announcing the decision. Max 260 characters." },
  },
} as const;

const SYSTEM_PROMPT = `You are Cortex, the autonomous market agent of a Uniswap v4 token on Ethereum Mainnet. Every few minutes you receive an onchain snapshot of the token's only pool and choose two things: the treasury fee the hook charges on every trade, and whether the treasury should buy back and burn tokens now.

How the system works:
- Every trade pays a fixed 0.30% platform fee plus your treasury fee, both on the gross ETH leg. The pool's LP fee (0.30%) is separate and also flows to the treasury.
- Your treasury fee lives in [0, 30000] ppm (0%-3%). The onchain hook rejects any change larger than 5000 ppm from the current fee, any update sooner than 15 minutes after the previous one, and any TTL above 24 hours. When your regime expires the fee falls back to 7000 ppm.
- There is no opening or anti-sniper fee. The fee you set applies to every trader equally from the first block.
- The treasury can only buy back and burn, and only you can trigger it. One buyback may spend at most maxBuybackEth, must wait at least 1 hour after the previous one, and reverts if it would move the price more than about 2%, so keep buybacks small relative to pool depth.
- Everything you decide is hashed and published with the transaction, so holders can audit your reasoning.

What good decisions look like:
- Calm market, organic two-sided flow: keep fees low (around 3000-7000 ppm) so trading stays cheap.
- Bursty one-sided flow, very large single trades, or high realized volatility: raise the fee to tax extraction by bots and fast flippers, with a short TTL so it does not linger.
- Heavy sell pressure after a run-up: a moderately higher fee on all trades dampens churn; consider a buyback only if the treasury has budget and price has already dropped meaningfully.
- Buy back into weakness, never into strength. Spend nothing when the treasury is small, when a buyback is on cooldown, or when you are unsure. Never exceed maxBuybackEth.
- Prefer small, explainable moves. If nothing material changed, keep the current fee and set buybackEth to "0".
- The public post is factual: state the regime, the fee, and any buyback. No price predictions, no promises, no hype.`;

export class Brain {
  private readonly client = new Anthropic();
  private readonly model: string;

  constructor(model: string) {
    this.model = model;
  }

  async decide(snapshot: MarketSnapshot, recentDecisions: unknown[]): Promise<Decision> {
    const response = await this.client.beta.messages.create({
      model: this.model,
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      thinking: { type: "adaptive" },
      output_config: {
        effort: "high",
        format: { type: "json_schema", schema: DECISION_JSON_SCHEMA },
      },
      system: SYSTEM_PROMPT,
      messages: [
        {
          role: "user",
          content: [
            "Your recent decisions (newest last):",
            JSON.stringify(recentDecisions),
            "",
            "Current snapshot:",
            JSON.stringify(snapshot),
          ].join("\n"),
        },
      ],
    });

    if (response.stop_reason === "refusal") {
      throw new Error(`model refused: ${response.stop_details?.category ?? "unknown"} ${response.stop_details?.explanation ?? ""}`);
    }
    if (response.stop_reason === "max_tokens") throw new Error("model output was truncated (max_tokens)");
    const text = response.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");
    return DecisionSchema.parse(JSON.parse(text));
  }
}
