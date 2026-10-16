#!/usr/bin/env node
// Builds the AURA launch on Programmable's mandatory protected graph (@programmable/launch 4.1.7
// `launch-protection`): ProtectedLaunchTokenV1 + ProtectedNative30HookV1 + ProtectedNativeInitializerV1.
// It reads live Ethereum capabilities and the Chainlink ETH/USD feed, writes the exact protected sources into this
// directory, then writes launch.json bound to the server's current trade-fee policy. It never signs or submits.
//
//   node build-protected.mjs            uses PROGRAMMABLE_SOURCE_REVISION / ETH_RPC_URL from the environment
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const cli = path.join(here, "..", "tools", "cli417", "node_modules");
const load = (relative) => import(pathToFileURL(path.join(cli, relative)).href);
const { buildProtectedEthereumLaunchV1, protectedOpeningPriceV1, PROTECTED_LAUNCH_CHAIN_PINS_V1 } =
  await load("@programmable/launch/src/launch-protection.mjs");
const { getLaunchCapabilities } = await load("@programmable/launch/src/api-client.mjs");
const { packLaunch } = await load("@programmable/launch/src/pack.mjs");
const { createPublicClient, http, parseAbi } = await load("viem/_esm/index.js");
const { mainnet } = await load("viem/_esm/chains/index.js");

const input = JSON.parse(await readFile(path.join(here, "launch-input.json"), "utf8"));
const revision = process.env.PROGRAMMABLE_SOURCE_REVISION ?? input.publicOrigin.revision;
if (!/^[0-9a-f]{40}$/.test(revision)) throw new TypeError("PROGRAMMABLE_SOURCE_REVISION must be a 40-char commit");
const description = (await readFile(path.join(here, input.descriptionFile), "utf8")).replace(/\r\n/g, "\n").trim();

const client = createPublicClient({ chain: mainnet, transport: http(process.env.ETH_RPC_URL ?? "https://ethereum-rpc.publicnode.com") });
const capabilities = (await getLaunchCapabilities({ apiVersion: 3 })).resource;

// Size the initial-buy floor from the same feed the initializer checks. The buy is atomic with pool creation, so the
// floor only guards against a misconfigured price; 50% of the fee-adjusted spot estimate.
const pins = PROTECTED_LAUNCH_CHAIN_PINS_V1[1];
const round = await client.readContract({
  address: pins.feed,
  abi: parseAbi(["function latestRoundData() view returns(uint80,int256,uint256,uint256,uint80)"]),
  functionName: "latestRoundData",
});
const price = protectedOpeningPriceV1({ supply: input.supply, answer: round[1], feedDecimals: 8, targetFdvUsd: input.targetFdvUsd });
const normalBuyFee = (30 + input.creatorBuyFeeBps) / 10_000;
const estimate = Number(BigInt(input.initialBuyWei)) * 1.0001 ** price.initialTick * (1 - normalBuyFee);
const minimumTokensOut = BigInt(Math.floor(estimate * 0.5)).toString();
if (BigInt(minimumTokensOut) > BigInt(input.supply) / 50n) throw new TypeError("initial buy would exceed the 2% limit");

const now = Math.floor(Date.now() / 1000);
const { configPath, built } = await buildProtectedEthereumLaunchV1({
  projectRoot: here,
  client,
  capabilities,
  permitWindow: { validAfter: String(now - 60), deadline: String(now + 3540) },
  input: {
    launchWallet: input.launchWallet,
    nonce: input.nonce,
    supply: input.supply,
    creatorBuyFeeBps: input.creatorBuyFeeBps,
    creatorSellFeeBps: input.creatorSellFeeBps,
    additionalTaxExemptWallets: input.additionalTaxExemptWallets,
    targetFdvUsd: input.targetFdvUsd,
    initialBuyWei: input.initialBuyWei,
    minimumTokensOut,
    publicOrigin: { url: input.publicOrigin.url, revision },
    projectMetadata: {
      schemaVersion: "programmable.project-metadata-input.v1",
      token: input.token,
      presentation: { description, image: input.image, links: input.links },
    },
  },
});

const packed = await packLaunch({
  configPath,
  outputPath: path.join(here, "launch.json"),
  directNativeTradeFeePolicy: capabilities.programmableTradeFeePolicy?.policy,
});
const summary = {
  ethUsd: Number(round[1]) / 1e8,
  openingTick: price.initialTick,
  openingFdvUsd: String(price.openingFdvUsd),
  tokensPerEth: Math.round(1.0001 ** price.initialTick),
  initialBuyWei: input.initialBuyWei,
  minimumTokensOut,
  estimatedInitialBuyTokens: Math.round(estimate),
  predictions: built.predictions.map(({ targetId, predictedAddress }) => ({ targetId, predictedAddress })),
  launchJson: packed.outputPath,
  requestSha256: packed.requestSha256 ?? built.requestSha256,
};
await writeFile(path.join(here, "build-summary.json"), `${JSON.stringify(summary, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
