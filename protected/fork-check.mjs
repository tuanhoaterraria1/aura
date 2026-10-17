#!/usr/bin/env node
// Local mainnet-fork rehearsal of the protected AURA launch (needs `anvil --fork-url <mainnet> --port 8545`).
// Deploys the exact @programmable/launch 4.1.7 protected graph with the same parameters as launch-input.json,
// runs the atomic initialize + initial buy, then checks the 2% limits, the opening fee decay and the normal fees.
// Rehearsal only: it uses the canonical CREATE2 deployer instead of Programmable's GraphFactory, so addresses differ.
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const cli = path.join(here, "..", "tools", "cli417", "node_modules");
const load = (relative) => import(pathToFileURL(path.join(cli, relative)).href);
const { prepareProtectedNativeContractsV1 } = await load("@programmable/launch/src/launch-protection.mjs");
const viem = await load("viem/_esm/index.js");
const { mainnet } = await load("viem/_esm/chains/index.js");
const { createPublicClient, createTestClient, createWalletClient, http, parseAbi, parseEther, formatEther, concatHex, keccak256 } = viem;

const RPC = "http://127.0.0.1:8545";
const CREATE2_DEPLOYER = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
const AUTHORITY = "0x00000000000000000000000000000000000a11ce";
const BUYER = "0x00000000000000000000000000000000000b0b0b";
const RECEIVER = "0x0000000000000000000000000000000000c0ffee";
const input = JSON.parse(await readFile(path.join(here, "launch-input.json"), "utf8"));
const DEV = input.launchWallet;

const pub = createPublicClient({ chain: mainnet, transport: http(RPC) });
const test = createTestClient({ chain: mainnet, mode: "anvil", transport: http(RPC) });
const wallet = createWalletClient({ chain: mainnet, transport: http(RPC) });
const results = [];
const check = (name, ok, detail) => { results.push({ name, ok, detail }); console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`); };
const send = async (from, tx) => {
  const hash = await wallet.sendTransaction({ account: from, ...tx });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`tx reverted: ${hash}`);
  return receipt;
};
const advance = async (seconds) => { await test.increaseTime({ seconds }); await test.mine({ blocks: 1 }); };
for (const who of [AUTHORITY, DEV, BUYER, RECEIVER]) { await test.impersonateAccount({ address: who }); await test.setBalance({ address: who, value: parseEther("100") }); }

// Fresh feed timestamp on the fork so the 1-hour feed age check reflects a live launch.
const block = await pub.getBlock();
await test.setNextBlockTimestamp({ timestamp: block.timestamp + 12n }); await test.mine({ blocks: 1 });

const prepared = await prepareProtectedNativeContractsV1({
  client: pub, chainId: 1, developer: DEV, deploymentFactory: CREATE2_DEPLOYER, initializerAuthority: AUTHORITY,
  nonce: input.nonce, name: input.token.name, symbol: input.token.symbol, supply: input.supply,
  creatorBuyFeeBps: input.creatorBuyFeeBps, creatorSellFeeBps: input.creatorSellFeeBps,
  additionalTaxExemptWallets: input.additionalTaxExemptWallets, targetFdvUsd: input.targetFdvUsd,
  initialBuyWei: input.initialBuyWei, minimumTokensOut: "1",
});
console.log(`opening tick ${prepared.price.initialTick}, opening FDV $${prepared.price.openingFdvUsd}`);

for (const role of ["initializer", "token", "hook"]) {
  const d = prepared.deployments[role];
  await send(AUTHORITY, { to: CREATE2_DEPLOYER, data: concatHex([d.salt, prepared.contracts[role].initCode]), gas: 16_000_000n });
  const code = await pub.getCode({ address: prepared.contracts[role].address });
  check(`${role} deployed with exact runtime`, code !== undefined && keccak256(code) === prepared.contracts[role].runtimeCodeHash);
}
for (const role of ["feeVault", "module", "openingTaxVault"]) {
  const code = await pub.getCode({ address: prepared.contracts[role].address });
  check(`${role} child created with exact runtime`, code !== undefined && keccak256(code) === prepared.contracts[role].runtimeCodeHash);
}

const A = prepared.contracts;
const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)", "function walletTokenLimit() view returns (uint256)", "function startedAt() view returns (uint256)", "function totalSupply() view returns (uint256)", "function approve(address,uint256) returns (bool)"]);
const init = parseAbi(["function initialized() view returns (bool)", "function openingFdvUsd() view returns (uint256)", "function lockedLiquidity() view returns (uint128)"]);
const vault = parseAbi(["function platformAccrued() view returns (uint256)", "function creatorAccrued() view returns (uint256)"]);
const mod = parseAbi(["function additionalTaxPpmForBuyer(address) view returns (uint24)", "function isTaxExempt(address) view returns (bool)"]);
const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });
const accrued = async () => ({
  platform: await read(A.feeVault.address, vault, "platformAccrued"),
  creator: await read(A.feeVault.address, vault, "creatorAccrued"),
  openingTax: await read(A.openingTaxVault.address, vault, "platformAccrued"),
});

// ---- launch: atomic initialize + initial buy
await send(AUTHORITY, { to: A.initializer.address, data: prepared.initializeData, value: BigInt(input.initialBuyWei), gas: 5_000_000n });
check("initializer.initialized()", await read(A.initializer.address, init, "initialized"));
const fdv = await read(A.initializer.address, init, "openingFdvUsd");
check("opening FDV >= $15,000 (checked onchain)", fdv >= 15000n, `$${fdv}`);
check("liquidity locked", (await read(A.initializer.address, init, "lockedLiquidity")) > 0n);
const supply = await read(A.token.address, erc20, "totalSupply");
const devTokens = await read(A.token.address, erc20, "balanceOf", [DEV]);
check("initial buy delivered to developer, below 2%", devTokens > 0n && devTokens * 50n <= supply, `${formatEther(devTokens)} AURA = ${(Number(devTokens * 10000n / supply) / 100).toFixed(2)}%`);
const afterLaunch = await accrued();
check("initial buy paid 0.3% platform fee", afterLaunch.platform * 1000n >= BigInt(input.initialBuyWei) * 3n - 1000n, `${formatEther(afterLaunch.platform)} ETH`);
check("initial buy paid 1% creator fee", afterLaunch.creator * 100n >= BigInt(input.initialBuyWei) - 100n, `${formatEther(afterLaunch.creator)} ETH`);
check("developer exempt from opening extra fee", afterLaunch.openingTax === 0n, `${formatEther(afterLaunch.openingTax)} ETH`);
const limit = await read(A.token.address, erc20, "walletTokenLimit");
check("wallet limit is 2% of supply", limit * 50n === supply, `${formatEther(limit)} AURA`);

// ---- protection window
const t0 = Number(await read(A.token.address, erc20, "startedAt"));
const tax0 = await read(A.module.address, mod, "additionalTaxPpmForBuyer", [BUYER]);
check("opening extra fee near 98.7% at start (99% total)", tax0 > 950_000, `${tax0} ppm extra`);
check("developer pays no opening extra fee", (await read(A.module.address, mod, "additionalTaxPpmForBuyer", [DEV])) === 0);
for (const exempt of input.additionalTaxExemptWallets) {
  const extra = await read(A.module.address, mod, "additionalTaxPpmForBuyer", [exempt]);
  check(`whitelisted ${exempt.slice(0, 8)}… pays no opening extra fee`, extra === 0 && (await read(A.module.address, mod, "isTaxExempt", [exempt])));
}
await advance(15);
const tax15 = await read(A.module.address, mod, "additionalTaxPpmForBuyer", [BUYER]);
check("opening extra fee decays (~half at 15s)", tax15 < tax0 && tax15 > 0, `${tax15} ppm extra`);
await advance(16);
const tax31 = await read(A.module.address, mod, "additionalTaxPpmForBuyer", [BUYER]);
check("opening extra fee is zero after 30s", tax31 === 0, `${tax31} ppm`);

// Recipient cap: developer can move tokens out, but a recipient may not exceed 2% cumulatively within 300s.
const router = JSON.parse(await readFile(path.join(here, "..", "contracts", "out", "Cortex.t.sol", "TestSwapRouter.json"), "utf8"));
const routerAbi = router.abi;
const deployHash = await wallet.deployContract({ account: BUYER, abi: routerAbi, bytecode: router.bytecode.object, args: ["0x000000000004444c5dc75cB358380D2e3dE08A90"] });
const routerAddress = (await pub.waitForTransactionReceipt({ hash: deployHash })).contractAddress;
const key = await read(A.hook.address, parseAbi(["struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }", "function poolKey() view returns (PoolKey)"]), "poolKey");

let directBuyReverted = false;
try { await send(BUYER, { to: routerAddress, data: viem.encodeFunctionData({ abi: routerAbi, functionName: "swap", args: [key, true, -parseEther("0.01")] }), value: parseEther("0.01"), gas: 3_000_000n }); }
catch { directBuyReverted = true; }
check("non-canonical-router buy reverts during protection", directBuyReverted);

await send(DEV, { to: A.token.address, data: viem.encodeFunctionData({ abi: erc20, functionName: "transfer", args: [RECEIVER, devTokens / 2n] }), gas: 300_000n });
check("transfer within 2% to a fresh wallet works during protection", (await read(A.token.address, erc20, "balanceOf", [RECEIVER])) === devTokens / 2n);

// ---- after the 300s window: normal fees only
await advance(300);
const before = await accrued();
const buyWei = parseEther("0.1");
await send(BUYER, { to: routerAddress, data: viem.encodeFunctionData({ abi: routerAbi, functionName: "swap", args: [key, true, -buyWei] }), value: buyWei, gas: 3_000_000n });
const afterBuy = await accrued();
const buyerTokens = await read(A.token.address, erc20, "balanceOf", [BUYER]);
check("buy works after protection window", buyerTokens > 0n, `${formatEther(buyerTokens)} AURA`);
check("buy: platform fee 0.3%", afterBuy.platform - before.platform >= buyWei * 3n / 1000n - 1n && afterBuy.platform - before.platform <= buyWei * 3n / 1000n + 1n, `${formatEther(afterBuy.platform - before.platform)} ETH`);
check("buy: creator fee 1%", afterBuy.creator - before.creator >= buyWei / 100n - 1n && afterBuy.creator - before.creator <= buyWei / 100n + 1n, `${formatEther(afterBuy.creator - before.creator)} ETH`);
check("buy: no opening tax after 30s", afterBuy.openingTax === before.openingTax);

await send(BUYER, { to: A.token.address, data: viem.encodeFunctionData({ abi: erc20, functionName: "approve", args: [routerAddress, buyerTokens] }), gas: 100_000n });
const ethBefore = await pub.getBalance({ address: BUYER });
const sellReceipt = await send(BUYER, { to: routerAddress, data: viem.encodeFunctionData({ abi: routerAbi, functionName: "swap", args: [key, false, -(buyerTokens / 2n)] }), gas: 3_000_000n });
const afterSell = await accrued();
const received = (await pub.getBalance({ address: BUYER })) - ethBefore + sellReceipt.gasUsed * sellReceipt.effectiveGasPrice;
const sellPlatform = afterSell.platform - afterBuy.platform, sellCreator = afterSell.creator - afterBuy.creator;
const gross = received + sellPlatform + sellCreator;
check("sell works and pays 0.3% platform fee", sellPlatform * 1000n >= gross * 3n - 1000n && sellPlatform * 1000n <= gross * 3n + 1000n, `${formatEther(sellPlatform)} ETH of ${formatEther(gross)} gross`);
check("sell pays 1% creator fee", sellCreator * 100n >= gross - 100n && sellCreator * 100n <= gross + 100n, `${formatEther(sellCreator)} ETH`);

const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} checks passed`);
process.exitCode = failed ? 1 : 0;
