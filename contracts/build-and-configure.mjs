#!/usr/bin/env node
// Compiles the Cortex launch graph with the exact compiler Programmable requires (solc 0.8.26) and writes
// `programmable-launch.config.json` (schema programmable.launch-pack-config.v3) for `programmable-launch pack`.
// Adapted from Programmable's public `direct-native-v3-no-broadcast` example. It never signs, submits or broadcasts.
//
//   node build-and-configure.mjs --compile-only   compile + size report, no launch inputs needed
//   node build-and-configure.mjs                  compile + write the pack config (needs the env below)

import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, open, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const EXPECTED_SOLC = "0.8.26+commit.8a97fa7a.Emscripten.clang";
// Frozen `programmable:settlement-fee-vault:v1` release module, copied from the verified @programmable/launch 3.3.9
// package (test/fixtures). Values are the ones Programmable's own example pins.
const EXPECTED_VAULT_DESCRIPTOR_SHA256 =
  "sha256:b3bc25d1471953ab2afd5eb5bb2261bfe39d194e4e597eeabd6bea8d445ae56a";
const EXPECTED_VAULT_STANDARD_JSON_SHA256 =
  "sha256:840f0827714818dd9cf28ce15b684eb907d58b3701d3b3a9f28d0f3be137c7d9";
const EXPECTED_VAULT_CREATION_SHA256 =
  "sha256:7b0d51612be90023839f36cf28ae56963d8146d28ff441dd2a20195d56238b81";
const EXPECTED_VAULT_RUNTIME_SHA256 =
  "sha256:980c0eec1017a7dbbd9010935107440125070a0b1fa4688bca92754e2bf1e649";
const VAULT_SOURCE = "src/ProgrammableSettlementFeeVaultV1.sol";
const VAULT_CONTRACT = "ProgrammableSettlementFeeVaultV1";
const VAULT_DESCRIPTOR_PATH = "release-modules/programmable-settlement-fee-vault-v1.json";
const VAULT_STANDARD_JSON_PATH = "release-modules/programmable-settlement-fee-vault-v1.standard-json.json";

// Ethereum Mainnet bindings used by Programmable's V3 profile.
const GRAPH_FACTORY = "0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887";
const POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90";
const NATIVE_CURRENCY = "0x0000000000000000000000000000000000000000";

// Must match CortexLauncher.LP_FEE / TICK_SPACING and CortexHook.AGENT_FEE_BASE_PPM.
const LP_FEE = 3000;
const TICK_SPACING = 60;
const BASE_TREASURY_FEE_PPM = "7000";
const MIN_TICK = -887272;
const MAX_TICK = 887272;

const ENTRYPOINTS = Object.freeze([
  "src/CortexToken.sol",
  "src/CortexHook.sol",
  "src/CortexLauncher.sol",
  "src/CortexTreasury.sol",
]);
const CONTRACTS = Object.freeze({
  token: ["src/CortexToken.sol", "CortexToken"],
  hook: ["src/CortexHook.sol", "CortexHook"],
  launcher: ["src/CortexLauncher.sol", "CortexLauncher"],
  treasury: ["src/CortexTreasury.sol", "CortexTreasury"],
});
const HOOK_PERMISSIONS = Object.freeze([
  "beforeInitialize",
  "beforeSwap",
  "afterSwap",
  "beforeSwapReturnDelta",
  "afterSwapReturnDelta",
]);

const args = process.argv.slice(2);
if (args.includes("--help")) {
  process.stdout.write(`cortex build

Required environment (full build):
  PROGRAMMABLE_LAUNCH_WALLET              controller wallet that signs the launch (nonzero address)
  PROGRAMMABLE_SOURCE_REVISION            exact lowercase 40-character public Git commit of this source
  PROGRAMMABLE_PUBLIC_ORIGIN              public HTTPS Git repository URL holding that commit
  PROGRAMMABLE_LAUNCH_NONCE               nonzero lowercase bytes32 (public launch input)
  PROGRAMMABLE_TOKEN_NAME                 1..64 UTF-8 bytes
  PROGRAMMABLE_TOKEN_SYMBOL               1..16 UTF-8 bytes, no whitespace
  PROGRAMMABLE_PROJECT_DESCRIPTION        20..4096 UTF-8 bytes, at least 8 letters or numbers
  PROGRAMMABLE_PROJECT_IMAGE_SOURCE_PATH  relative path of the local PNG/JPEG/WebP/GIF logo
  PROGRAMMABLE_PROJECT_IMAGE_URI          its public https://, ipfs:// or ar:// URI
  PROGRAMMABLE_WEBSITE_URL                public HTTPS website
  PROGRAMMABLE_X_URL                      https://x.com/<handle>
  CORTEX_AGENT_ADDRESS                    hot wallet of the AI agent (or 0x0 to launch without an agent)
  CORTEX_START_TOKENS_PER_ETH             opening price, whole tokens per 1 ETH (e.g. 300000000)

Optional:
  PROGRAMMABLE_TOKEN_SUPPLY               token base units (default 1e27 = 1,000,000,000 tokens)
  CORTEX_INITIAL_BUY_WEI                  launch wallet's initial buy in wei (default 0)
  CORTEX_MIN_INITIAL_BUY_TOKENS           slippage floor for that buy, token base units (default 0)
  PROGRAMMABLE_PERMIT_DEADLINE_SECONDS    permit window length (default 3540; run pack right after build)
  PROGRAMMABLE_SOURCE_LINEAGE_NONCE       default 1
  PROGRAMMABLE_CHECKED_AT                 canonical UTC timestamp with milliseconds
  PROGRAMMABLE_TELEGRAM_URL / PROGRAMMABLE_DISCORD_URL / PROGRAMMABLE_GITHUB_URL / PROGRAMMABLE_DOCS_URL
`);
  process.exit(0);
}
const compileOnly = args.includes("--compile-only");
if (args.some((arg) => arg !== "--compile-only")) {
  throw new TypeError("build accepts only --help or --compile-only; configure launch inputs through the environment");
}

const root = process.cwd();
// Run the locked solcjs entrypoint with this Node binary directly (works the same on Windows, macOS and Linux).
const solcEntrypoint = path.join(root, "node_modules", "solc", "solc.js");
const compilerVersion = (await runSolc(["--version"])).stdout.trim();
if (compilerVersion !== EXPECTED_SOLC) {
  throw new TypeError(`expected exact locked solc ${EXPECTED_SOLC}, received ${compilerVersion}`);
}

// ------------------------------------------------------------------ compile the project unit

const sources = await collectSoliditySources(ENTRYPOINTS);
const standardJson = {
  language: "Solidity",
  sources: Object.fromEntries([...sources.entries()]
    .sort(([left], [right]) => Buffer.compare(Buffer.from(left), Buffer.from(right)))
    .map(([sourceName, content]) => [sourceName, { content }])),
  settings: {
    optimizer: { enabled: true, runs: 200 },
    evmVersion: "cancun",
    viaIR: true,
    metadata: { bytecodeHash: "none", appendCBOR: false, useLiteralContent: true },
    libraries: {},
    remappings: [],
    outputSelection: {
      "*": {
        "*": [
          "abi",
          "metadata",
          "evm.bytecode.object",
          "evm.bytecode.linkReferences",
          "evm.deployedBytecode.object",
          "evm.deployedBytecode.linkReferences",
          "evm.deployedBytecode.immutableReferences",
        ],
        "": ["ast"],
      },
    },
  },
};
const standardJsonBytes = Buffer.from(`${JSON.stringify(standardJson)}\n`, "utf8");
await mkdir(path.join(root, "standard-json"), { recursive: true });
const standardJsonPath = path.join(root, "standard-json/cortex.json");
await writeFile(standardJsonPath, standardJsonBytes);
const output = await compileStandardJson(standardJsonPath, path.join(root, "standard-json/.cortex-output.json"));

const compiled = Object.fromEntries(Object.entries(CONTRACTS).map(([targetId, [sourceName, contractName]]) => {
  const unit = output.contracts?.[sourceName]?.[contractName];
  if (!unit?.abi || !unit?.metadata || !unit?.evm?.bytecode?.object || !unit?.evm?.deployedBytecode?.object) {
    throw new TypeError(`compiler output is incomplete for ${sourceName}:${contractName}`);
  }
  return [targetId, unit];
}));

await mkdir(path.join(root, "artifacts"), { recursive: true });
const sizeReport = {};
for (const [targetId, unit] of Object.entries(compiled)) {
  const runtimeBytes = unit.evm.deployedBytecode.object.length / 2;
  const initBytes = unit.evm.bytecode.object.length / 2;
  sizeReport[targetId] = { runtimeBytes, initBytes };
  if (runtimeBytes > 24_576) throw new TypeError(`${targetId} runtime ${runtimeBytes} bytes exceeds EIP-170`);
  await writeFile(
    path.join(root, `artifacts/${targetId}.json`),
    `${JSON.stringify({
      abi: unit.abi,
      bytecode: unit.evm.bytecode,
      deployedBytecode: unit.evm.deployedBytecode,
      metadata: unit.metadata,
    })}\n`,
  );
}

if (compileOnly) {
  process.stdout.write(`${JSON.stringify({ compilerVersion, sourceCount: sources.size, sizes: sizeReport }, null, 2)}\n`);
  process.exit(0);
}

// ------------------------------------------------------------------ launch inputs

const launchWallet = address(required("PROGRAMMABLE_LAUNCH_WALLET"), "PROGRAMMABLE_LAUNCH_WALLET", { nonzero: true });
const agentAddress = address(required("CORTEX_AGENT_ADDRESS"), "CORTEX_AGENT_ADDRESS");
if (agentAddress.toLowerCase() === launchWallet.toLowerCase()) {
  throw new TypeError("CORTEX_AGENT_ADDRESS must be a separate hot wallet, never the launch wallet");
}
const revision = required("PROGRAMMABLE_SOURCE_REVISION");
if (!/^[0-9a-f]{40}$/.test(revision)) throw new TypeError("PROGRAMMABLE_SOURCE_REVISION must be a lowercase 40-char commit");
const publicOriginUrl = new URL(required("PROGRAMMABLE_PUBLIC_ORIGIN"));
if (publicOriginUrl.protocol !== "https:" || publicOriginUrl.username || publicOriginUrl.password || publicOriginUrl.hash) {
  throw new TypeError("PROGRAMMABLE_PUBLIC_ORIGIN must be credential-free HTTPS without a fragment");
}
const nonce = required("PROGRAMMABLE_LAUNCH_NONCE");
if (!/^0x(?!0{64}$)[0-9a-f]{64}$/.test(nonce)) throw new TypeError("PROGRAMMABLE_LAUNCH_NONCE must be a nonzero lowercase bytes32");
const checkedAt = process.env.PROGRAMMABLE_CHECKED_AT ?? new Date().toISOString();
if (new Date(checkedAt).toISOString() !== checkedAt) throw new TypeError("PROGRAMMABLE_CHECKED_AT must be canonical UTC");
const sourceLineageNonce = canonicalUint(process.env.PROGRAMMABLE_SOURCE_LINEAGE_NONCE ?? "1", "PROGRAMMABLE_SOURCE_LINEAGE_NONCE");

const tokenName = publicText(required("PROGRAMMABLE_TOKEN_NAME"), "PROGRAMMABLE_TOKEN_NAME", 64);
const tokenSymbol = publicText(required("PROGRAMMABLE_TOKEN_SYMBOL"), "PROGRAMMABLE_TOKEN_SYMBOL", 16, { whitespace: false });
const tokenSupply = canonicalUint(
  process.env.PROGRAMMABLE_TOKEN_SUPPLY ?? "1000000000000000000000000000",
  "PROGRAMMABLE_TOKEN_SUPPLY",
  { nonzero: true },
);
const description = publicText(required("PROGRAMMABLE_PROJECT_DESCRIPTION"), "PROGRAMMABLE_PROJECT_DESCRIPTION", 4096, {
  multiline: true,
});
if ([...description].length < 20 || [...description.matchAll(/[\p{L}\p{N}]/gu)].length < 8) {
  throw new TypeError("PROGRAMMABLE_PROJECT_DESCRIPTION needs at least 20 characters and 8 letters or numbers");
}
const imageSourcePath = publicText(required("PROGRAMMABLE_PROJECT_IMAGE_SOURCE_PATH"), "PROGRAMMABLE_PROJECT_IMAGE_SOURCE_PATH", 2048);
if (!existsSync(path.join(root, imageSourcePath))) throw new TypeError(`project image ${imageSourcePath} does not exist`);
const imageUri = publicText(required("PROGRAMMABLE_PROJECT_IMAGE_URI"), "PROGRAMMABLE_PROJECT_IMAGE_URI", 2048);
if (!/^(?:https|ipfs|ar):/.test(imageUri)) throw new TypeError("PROGRAMMABLE_PROJECT_IMAGE_URI must be https, ipfs or ar");
const xUrl = required("PROGRAMMABLE_X_URL");
if (!/^https:\/\/x\.com\/[A-Za-z0-9_]{1,64}$/.test(xUrl)) throw new TypeError("PROGRAMMABLE_X_URL must be https://x.com/<handle>");
const links = [
  ["website", required("PROGRAMMABLE_WEBSITE_URL")],
  ["x", xUrl],
  ["telegram", process.env.PROGRAMMABLE_TELEGRAM_URL],
  ["discord", process.env.PROGRAMMABLE_DISCORD_URL],
  ["github", process.env.PROGRAMMABLE_GITHUB_URL],
  ["documentation", process.env.PROGRAMMABLE_DOCS_URL],
].filter(([, uri]) => uri).map(([kind, uri]) => {
  if (!uri.startsWith("https://")) throw new TypeError(`${kind} link must be HTTPS`);
  return { kind, uri };
});

const startTick = startTickFromPrice(required("CORTEX_START_TOKENS_PER_ETH"));
const initialBuyWei = canonicalUint(process.env.CORTEX_INITIAL_BUY_WEI ?? "0", "CORTEX_INITIAL_BUY_WEI");
const minInitialBuyTokens = canonicalUint(process.env.CORTEX_MIN_INITIAL_BUY_TOKENS ?? "0", "CORTEX_MIN_INITIAL_BUY_TOKENS");
if (initialBuyWei !== "0" && minInitialBuyTokens === "0") {
  throw new TypeError("set CORTEX_MIN_INITIAL_BUY_TOKENS when CORTEX_INITIAL_BUY_WEI is nonzero");
}
const now = Math.floor(Date.now() / 1000);
// The CLI caps the permit window at one hour; Programmable refreshes the outer transaction window after approval.
// Cortex embeds no deadlines in its own calls, so nothing inside the graph expires during review.
const permitSeconds = Number(canonicalUint(process.env.PROGRAMMABLE_PERMIT_DEADLINE_SECONDS ?? "3540", "PROGRAMMABLE_PERMIT_DEADLINE_SECONDS"));
if (permitSeconds < 60 || permitSeconds > 3540) {
  throw new TypeError("PROGRAMMABLE_PERMIT_DEADLINE_SECONDS must be 60..3540 (CLI limit: 3600s window incl. 60s back-dating)");
}

// ------------------------------------------------------------------ frozen settlement-fee-vault module

for (const required of [VAULT_DESCRIPTOR_PATH, VAULT_STANDARD_JSON_PATH]) {
  if (!existsSync(path.join(root, required))) {
    throw new TypeError(`${required} is missing; copy it from the verified @programmable/launch 3.3.9 package (see README)`);
  }
}
const vaultDescriptorBytes = await readFile(path.join(root, VAULT_DESCRIPTOR_PATH));
assertDigest(vaultDescriptorBytes, EXPECTED_VAULT_DESCRIPTOR_SHA256, "settlement fee vault descriptor");
const vaultStandardJson = JSON.parse(await readFile(path.join(root, VAULT_STANDARD_JSON_PATH), "utf8"));
const vaultStandardJsonBytes = Buffer.from(JSON.stringify(vaultStandardJson), "utf8");
assertDigest(vaultStandardJsonBytes, EXPECTED_VAULT_STANDARD_JSON_SHA256, "settlement fee vault Standard JSON");
const vaultStandardJsonPath = path.join(root, "standard-json/programmable-settlement-fee-vault-v1.json");
await writeFile(vaultStandardJsonPath, vaultStandardJsonBytes);
const vaultOutput = await compileStandardJson(
  vaultStandardJsonPath,
  path.join(root, "standard-json/.programmable-settlement-fee-vault-v1-output.json"),
);
const vault = vaultOutput.contracts?.[VAULT_SOURCE]?.[VAULT_CONTRACT];
if (!vault?.abi || !vault?.evm?.bytecode?.object || !vault?.evm?.deployedBytecode?.object) {
  throw new TypeError("settlement fee vault compiler output is incomplete");
}
assertDigest(Buffer.from(vault.evm.bytecode.object, "hex"), EXPECTED_VAULT_CREATION_SHA256, "vault creation bytecode");
assertDigest(Buffer.from(vault.evm.deployedBytecode.object, "hex"), EXPECTED_VAULT_RUNTIME_SHA256, "vault runtime bytecode");
await writeFile(
  path.join(root, "artifacts/settlement-fee-vault.json"),
  `${JSON.stringify({
    abi: vault.abi,
    bytecode: { object: vault.evm.bytecode.object, linkReferences: {} },
    deployedBytecode: { object: vault.evm.deployedBytecode.object, linkReferences: {}, immutableReferences: {} },
    metadata: {
      compiler: { version: "0.8.26+commit.8a97fa7a" },
      language: "Solidity",
      settings: { ...vaultStandardJson.settings, compilationTarget: { [VAULT_SOURCE]: VAULT_CONTRACT } },
    },
  })}\n`,
);

// ------------------------------------------------------------------ evidence + config

const immutableBindings = {
  poolManager: { literal: POOL_MANAGER },
  registrar: { target: "launcher" },
  launchWallet: { literal: launchWallet },
  settlementFeeVault: { target: "settlement-fee-vault" },
  hook: { target: "hook" },
  token: { target: "token" },
};

await mkdir(path.join(root, "evidence"), { recursive: true });
const evidence = {
  schemaVersion: "cortex.build-evidence.v1",
  checkedAt,
  sourceRevision: revision,
  compilerVersion,
  compilerSettings: { evmVersion: "cancun", optimizerRuns: 200, viaIR: true, metadataBytecodeHash: "none", appendCBOR: false },
  standardJsonSha256: sha256(standardJsonBytes),
  sizes: sizeReport,
  hookPermissionMask: "0x20cc",
  platformFee: { rateBps: 30, recipient: "0xD88539d3c4C460136a733A3Fd60cf6BF269079da", basis: "gross native ETH leg, rounded up" },
  treasuryFee: { basePpm: 7000, capPpm: 30000, maxStepPpm: 5000, minIntervalSeconds: 900, maxTtlSeconds: 86400 },
  antiSnipe: { startPpm: 100000, decayBlocks: 30, launcherExempt: true },
  liquidity: { model: "single-sided token liquidity below the start price, no withdraw path", startTick, tickSpacing: TICK_SPACING },
  ownerControls: [
    "hook.admin (launch wallet) can rotate or revoke the agent key, and transfer or renounce admin",
    "hook.agent can set the treasury fee within the immutable guardrails above",
    "treasury.buyback is agent-only while an agent is set, permissionless once revoked; 20% balance cap, 1h cooldown",
    "no mint, pause, blacklist, upgrade, proxy, selfdestruct or withdraw path in any contract",
  ],
};
await writeFile(path.join(root, "evidence/build.json"), `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600 });
const checks = [{ checkId: "cortex-exact-build", evidence: "evidence/build.json" }];
if (existsSync(path.join(root, "evidence/forge-test.txt"))) {
  checks.push({ checkId: "cortex-foundry-tests", evidence: "evidence/forge-test.txt" });
}

const target = (targetId, extra) => ({
  targetId,
  compilationUnitId: "cortex-solc",
  artifact: `artifacts/${targetId}.json`,
  initializer: null,
  deploymentValueWei: "0",
  initializerValueWei: "0",
  componentKind: "other",
  declaredHookPermissions: null,
  runtimeImmutables: runtimeImmutables(compiled[targetId], targetId),
  ...extra,
});

const config = {
  schemaVersion: "programmable.launch-pack-config.v3",
  // profileVersion is deliberately omitted: CLI 4.1.6 then reads live capabilities at pack time and binds the
  // current profile (3.6.0) and its current Programmable trade-fee policy. An explicit version would bind the
  // CLI's offline default policy, which the server rejects.
  launchWallet,
  chainId: "1",
  nonce,
  source: {
    root: ".",
    paths: ["package-lock.json", "release-modules", "src"],
    sourceLineageNonce,
    publicOrigin: { url: publicOriginUrl.toString(), revision },
  },
  compilationUnits: [
    { compilationUnitId: "canonical-settlement-fee-vault-v1", standardJson: "standard-json/programmable-settlement-fee-vault-v1.json" },
    { compilationUnitId: "cortex-solc", standardJson: "standard-json/cortex.json" },
  ],
  targets: [
    target("launcher", {
      applicantSalt: `0x${"01".repeat(32)}`,
      constructorArguments: [POOL_MANAGER, launchWallet, { target: "settlement-fee-vault" }],
      initializer: {
        function: "initialize",
        arguments: [
          { target: "hook" },
          { target: "token" },
          { target: "treasury" },
          agentAddress,
          String(startTick),
          minInitialBuyTokens,
        ],
      },
      initializerValueWei: initialBuyWei,
    }),
    target("token", {
      applicantSalt: `0x${"02".repeat(32)}`,
      constructorArguments: [tokenName, tokenSymbol, tokenSupply, { target: "launcher" }],
      componentKind: "token",
    }),
    target("hook", {
      applicantSalt: { mode: "deterministic-hook-permission-grind-v1", start: "0", maxAttempts: "1000000" },
      constructorArguments: [POOL_MANAGER, { target: "launcher" }],
      componentKind: "hook",
      declaredHookPermissions: [...HOOK_PERMISSIONS],
    }),
    target("treasury", {
      applicantSalt: `0x${"03".repeat(32)}`,
      constructorArguments: [POOL_MANAGER, { target: "hook" }, { target: "token" }],
    }),
    {
      targetId: "settlement-fee-vault",
      compilationUnitId: "canonical-settlement-fee-vault-v1",
      artifact: "artifacts/settlement-fee-vault.json",
      applicantSalt: `0x${"04".repeat(32)}`,
      constructorArguments: [GRAPH_FACTORY],
      initializer: { function: "bindRoute", arguments: [{ target: "launcher" }] },
      deploymentValueWei: "0",
      initializerValueWei: "0",
      componentKind: "other",
      declaredHookPermissions: null,
      runtimeImmutables: [],
    },
  ],
  pool: { tokenTargetId: "token", hookTargetId: "hook", fee: LP_FEE, tickSpacing: TICK_SPACING, quoteCurrency: NATIVE_CURRENCY },
  projectMetadata: {
    schemaVersion: "programmable.project-metadata-input.v1",
    token: { name: tokenName, symbol: tokenSymbol },
    presentation: { description, image: { sourcePath: imageSourcePath, uri: imageUri }, links },
  },
  launchProfile: {
    schemaVersion: "programmable.direct-native-hook-graph-profile-selection.v3",
    profileId: "programmable.direct-native-hook-graph.v1",
    profileRevision: 3,
    targetRoles: {
      tokenTargetId: "token",
      hookTargetId: "hook",
      initializerTargetId: "launcher",
      // 3.6: the target that declares the platform fee binding; CortexHook hard-codes the 0.3% recipient.
      platformFeeBindingTargetId: "hook",
    },
    liquidityModel: {
      schemaVersion: "programmable.direct-native-liquidity-model-intent.v1",
      model: "launch-seeded-concentrated-liquidity",
      declaredLaunchState: "assessment_required",
      liquidityTargetId: "launcher",
      assessment: {
        schemaVersion: "programmable.direct-native-liquidity-model-assessment.v1",
        status: "required",
        requestClaimsExecution: false,
        requiredVectorIds: [
          "liquidity.seeded.pool-active-liquidity",
          "liquidity.seeded.position-custody-and-withdrawal",
          "liquidity.seeded.buy-and-sell",
        ],
      },
    },
    fundingMode: initialBuyWei === "0" ? "none" : "wallet-transaction-value",
    accountingMode: "additive-platform-share",
    assessmentBase: "executed-gross-declared-quote",
    feeCurrency: "declared-quote-currency",
    claimMode: "claim-authority-selected-recipient",
    applicantSelectedBuyHundredthsOfBip: BASE_TREASURY_FEE_PPM,
    applicantSelectedSellHundredthsOfBip: BASE_TREASURY_FEE_PPM,
  },
  permitWindow: { validAfter: String(now - 60), deadline: String(now + permitSeconds) },
  agentAttestation: { agentId: "cortex-build-and-configure", checkedAt, checks },
};
await writeFile(path.join(root, "programmable-launch.config.json"), `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });

process.stdout.write(`${JSON.stringify({
  configPath: "programmable-launch.config.json",
  compilerVersion,
  targets: config.targets.map(({ targetId }) => targetId),
  startTick,
  fundingMode: config.launchProfile.fundingMode,
  initialBuyWei,
  sizes: sizeReport,
  next: "programmable-launch pack --config programmable-launch.config.json --output launch.json",
}, null, 2)}\n`);

// ------------------------------------------------------------------ helpers

function runtimeImmutables(unit, targetId) {
  const declarations = new Map();
  for (const source of Object.values(output.sources ?? {})) walkAst(source.ast, declarations);
  const references = unit.evm.deployedBytecode.immutableReferences ?? {};
  return Object.keys(references).sort((left, right) => (BigInt(left) < BigInt(right) ? -1 : 1)).map((immutableId) => {
    const declaration = declarations.get(immutableId);
    const binding = declaration && immutableBindings[declaration.name];
    if (!binding) {
      throw new TypeError(`unmapped ${targetId} immutable ${immutableId} (${declaration?.name}); do not guess runtime materialization`);
    }
    return { immutableId, abiType: "address", ...binding };
  });
}

function walkAst(node, declarations) {
  if (node === null || typeof node !== "object") return;
  if (node.nodeType === "VariableDeclaration" && node.mutability === "immutable" && Number.isSafeInteger(node.id)) {
    declarations.set(String(node.id), { name: node.name });
  }
  for (const value of Object.values(node)) {
    if (Array.isArray(value)) for (const child of value) walkAst(child, declarations);
    else if (value !== null && typeof value === "object") walkAst(value, declarations);
  }
}

/** Opening price as whole tokens per 1 ETH -> tick, rounded down to the spacing (both assets have 18 decimals). */
function startTickFromPrice(raw) {
  const price = Number(raw);
  if (!Number.isFinite(price) || price <= 1) throw new TypeError("CORTEX_START_TOKENS_PER_ETH must be a number > 1");
  const tick = Math.floor(Math.log(price) / Math.log(1.0001));
  const aligned = Math.floor(tick / TICK_SPACING) * TICK_SPACING;
  if (aligned <= Math.ceil(MIN_TICK / TICK_SPACING) * TICK_SPACING || aligned >= MAX_TICK) {
    throw new TypeError(`start tick ${aligned} is outside the usable range`);
  }
  return aligned;
}

async function compileStandardJson(inputPath, outputPath) {
  await runSolc(["--standard-json"], inputPath, outputPath);
  const text = await readFile(outputPath, "utf8");
  const start = text.indexOf("{");
  if (start === -1) throw new TypeError("solc returned no Standard JSON output");
  const result = JSON.parse(text.slice(start));
  const errors = (result.errors ?? []).filter(({ severity }) => severity === "error");
  if (errors.length !== 0) throw new TypeError(`solc failed:\n${errors.map(({ formattedMessage }) => formattedMessage).join("\n")}`);
  for (const warning of (result.errors ?? []).filter(({ severity }) => severity === "warning")) {
    if (!warning.sourceLocation?.file?.startsWith("@")) process.stderr.write(`${warning.formattedMessage}\n`);
  }
  return result;
}

async function collectSoliditySources(entrypoints) {
  const collected = new Map();
  const pending = [...entrypoints];
  while (pending.length !== 0) {
    const sourceName = pending.shift();
    if (collected.has(sourceName)) continue;
    if (path.posix.isAbsolute(sourceName) || sourceName.startsWith("../")) throw new TypeError(`unsafe source ${sourceName}`);
    const content = await readSoliditySource(sourceName);
    collected.set(sourceName, content);
    for (const match of content.matchAll(/^\s*import\s+(?:[^;]*?\sfrom\s+)?["']([^"']+)["']\s*;/gmu)) {
      const specifier = match[1];
      const imported = specifier.startsWith(".")
        ? path.posix.normalize(path.posix.join(path.posix.dirname(sourceName), specifier))
        : path.posix.normalize(specifier);
      if (!collected.has(imported) && !pending.includes(imported)) pending.push(imported);
    }
  }
  return collected;
}

async function readSoliditySource(sourceName) {
  for (const base of [root, path.join(root, "node_modules")]) {
    try {
      return await readFile(path.join(base, ...sourceName.split("/")), "utf8");
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  throw new TypeError(`Solidity dependency ${sourceName} is absent; run npm ci first`);
}

function canonicalUint(value, label, { nonzero = false } = {}) {
  if (typeof value !== "string" || !/^(?:0|[1-9][0-9]*)$/.test(value) || BigInt(value) >= 1n << 256n
    || (nonzero && value === "0")) {
    throw new TypeError(`${label} must be a canonical ${nonzero ? "nonzero " : ""}uint256`);
  }
  return value;
}

function address(value, label, { nonzero = false } = {}) {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(value) || (nonzero && /^0x0{40}$/i.test(value))) {
    throw new TypeError(`${label} must be a ${nonzero ? "nonzero " : ""}Ethereum address`);
  }
  return value;
}

function publicText(value, label, maximumBytes, { multiline = false, whitespace = true } = {}) {
  if (typeof value !== "string" || value !== value.normalize("NFC") || value.trim() !== value || value.length === 0
    || Buffer.byteLength(value, "utf8") > maximumBytes
    || (multiline
      ? /[\u0000-\u0009\u000b-\u001f\u007f​-‏‪-‮⁠-⁯﻿]/u.test(value)
      : /[\u0000-\u001f\u007f​-‏‪-‮⁠-⁯﻿]/u.test(value))
    || (!whitespace && /\s/u.test(value))) {
    throw new TypeError(`${label} must be canonical public text within ${maximumBytes} UTF-8 bytes`);
  }
  return value;
}

function required(name) {
  const value = process.env[name];
  if (!value) throw new TypeError(`${name} is required (see --help)`);
  return value;
}

function assertDigest(bytes, expected, label) {
  const actual = sha256(bytes);
  if (actual !== expected) throw new TypeError(`${label} differs: expected ${expected}, received ${actual}`);
}

function sha256(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

async function runSolc(solcArgs, inputPath = null, outputPath = null) {
  const inputHandle = inputPath === null ? null : await open(inputPath, "r");
  const outputHandle = outputPath === null ? null : await open(outputPath, "w", 0o600);
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [solcEntrypoint, ...solcArgs], {
      cwd: root,
      stdio: [inputHandle?.fd ?? "ignore", outputHandle?.fd ?? "pipe", "pipe"],
    });
    void inputHandle?.close();
    void outputHandle?.close();
    let stdout = "";
    let stderr = "";
    child.stdout?.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => reject(error?.code === "ENOENT" ? new TypeError("locked solcjs is absent; run npm ci") : error));
    child.on("close", (code) => (code !== 0 ? reject(new TypeError(`solcjs exited ${code}: ${stderr.trim()}`)) : resolve({ stdout, stderr })));
  });
}
