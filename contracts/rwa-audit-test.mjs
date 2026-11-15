import { createPublicClient, createWalletClient, http, defineChain, parseUnits, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";

const A = JSON.parse(readFileSync("./rwa-artifacts.json", "utf8"));
const RPC = "http://127.0.0.1:8545";
const chain = defineChain({ id: 31337, name: "hardhat", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const owner = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const mk = (i) => privateKeyToAccount("0x" + String(i).padStart(64, "0"));
const pub = createPublicClient({ chain, transport: http(RPC) });
const w0 = createWalletClient({ account: owner, chain, transport: http(RPC) });
const usd = (n) => parseUnits(String(n), 6);
const gold = (n) => parseUnits(String(n), 18);
let fails = 0;
const check = (l, c, e = "") => { console.log(`${c ? "PASS" : "FAIL"}  ${l}${e ? "  " + e : ""}`); if (!c) fails++; };
const tryIt = async (fn) => { try { await fn(); return true; } catch { return false; } };

const dep = async (n, args) => { const h = await w0.deployContract({ abi: A[n].abi, bytecode: A[n].bytecode, args }); return (await pub.waitForTransactionReceipt({ hash: h })).contractAddress; };
const send = async (w, addr, abi, fn, args = []) => { const h = await w.writeContract({ address: addr, abi, functionName: fn, args }); const rc = await pub.waitForTransactionReceipt({ hash: h }); if (rc.status !== "success") throw new Error(fn); return rc; };
const fund = async (addr) => { const h = await w0.sendTransaction({ to: addr, value: 10n ** 18n }); await pub.waitForTransactionReceipt({ hash: h }); };

const L = mk(11), B1 = mk(12), X = mk(13), B2 = mk(14);
for (const a of [L, B1, X, B2]) await fund(a.address);
const wL = createWalletClient({ account: L, chain, transport: http(RPC) });
const wB1 = createWalletClient({ account: B1, chain, transport: http(RPC) });
const wB2 = createWalletClient({ account: B2, chain, transport: http(RPC) });
const wX = createWalletClient({ account: X, chain, transport: http(RPC) });

const usdc = await dep("MockUSDC6", []);
const goldT = await dep("MockToken18", []);
const feed = await dep("MockFeed", [parseUnits("2000", 18), 0]);
const reg = await dep("CollateralRegistry", [owner.address]);
const pool = await dep("LendingPool", [usdc, reg, owner.address]);
await send(w0, reg, A.CollateralRegistry.abi, "setAsset", [goldT, feed, 7000, 6000, 8000]);
for (const w of [wL, wB1, wB2, wX]) await send(w0, pool, A.LendingPool.abi, "setAllowed", [w.account.address, true]);
await send(w0, usdc, A.MockUSDC6.abi, "mint", [X.address, usd(100000)]);
await send(wX, usdc, A.MockUSDC6.abi, "approve", [pool, usd(100000)]);

// supply
await send(w0, usdc, A.MockUSDC6.abi, "mint", [L.address, usd(200000)]);
await send(wL, usdc, A.MockUSDC6.abi, "approve", [pool, usd(200000)]);
await send(wL, pool, A.LendingPool.abi, "deposit", [usd(200000)]);

const openPos = async (w, who) => {
  await send(w0, goldT, A.MockToken18.abi, "mint", [who, gold(10)]);
  await send(w, goldT, A.MockToken18.abi, "approve", [pool, gold(10)]);
  await send(w, pool, A.LendingPool.abi, "depositCollateral", [goldT, gold(10)]);
  await send(w, pool, A.LendingPool.abi, "borrow", [usd(14000)]);
};

// ---------- A1: bad debt path ----------
console.log("=== A1 bad debt ===");
await openPos(wB1, B1.address);
await send(w0, feed, A.MockFeed.abi, "set", [parseUnits("1000", 18), 0]); // 10k value < 14k debt
const supplyBefore = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "totalSupplyAssets" });
check("liquidation succeeds when collateral < debt", await tryIt(() => send(wX, pool, A.LendingPool.abi, "liquidate", [B1.address])));
const debtAfter = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "debtOf", args: [B1.address] });
const totalDebt = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "totalDebt" });
const supplyAfter = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "totalSupplyAssets" });
const seized = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "collateral", args: [B1.address, goldT] });
check("debt cleared", debtAfter === 0n && totalDebt === 0n);
check("liquidator took all collateral", seized === 0n);
check("lenders absorbed the shortfall", supplyAfter < supplyBefore, formatUnits(supplyBefore - supplyAfter, 6) + " written off");

// ---------- A2: frozen feed blocks mild liquidation ----------
console.log("=== A2 frozen feed guard ===");
await send(w0, feed, A.MockFeed.abi, "set", [parseUnits("2000", 18), 0]);
await openPos(wB2, B2.address); // debt 14k, value 20k, liq limit 16k -> healthy
await send(w0, feed, A.MockFeed.abi, "set", [parseUnits("1700", 18), 2]); // value 17k, liq 13.6k < 14k -> underwater but frozen
check("frozen feed blocks a borderline liquidation", !(await tryIt(() => send(wX, pool, A.LendingPool.abi, "liquidate", [B2.address]))));
await send(w0, feed, A.MockFeed.abi, "set", [parseUnits("1700", 18), 0]); // fresh again
check("same position liquidatable once data is fresh", await tryIt(() => send(wX, pool, A.LendingPool.abi, "liquidate", [B2.address])));


// ---------- B1: broken/disabled feed degrades instead of reverting ----------
console.log("=== B1 fail-safe valuation ===");
const junk = await dep("MockToken18", []);
const vUnknown = await pub.readContract({ address: reg, abi: A.CollateralRegistry.abi, functionName: "valueOf", args: [junk, gold(1)] }).catch((e) => "revert");
check("unregistered asset values at (0, frozen) instead of reverting", Array.isArray(vUnknown) && vUnknown[0] === 0n && vUnknown[1] === 2);
const zeroFeed = await dep("MockFeed", [0n, 0]);
await send(w0, reg, A.CollateralRegistry.abi, "setAsset", [junk, zeroFeed, 7000, 6000, 8000]);
const vZero = await pub.readContract({ address: reg, abi: A.CollateralRegistry.abi, functionName: "valueOf", args: [junk, gold(1)] });
check("zero-price feed values at (0, frozen)", vZero[0] === 0n && vZero[1] === 2);
const ltvZero = await pub.readContract({ address: reg, abi: A.CollateralRegistry.abi, functionName: "ltvOf", args: [junk] });
check("zero-price feed LTV is 0", ltvZero[0] === 0);

// ---------- B2: unknown collateral rejected ----------
console.log("=== B2 unknown collateral ===");
const strangerToken = await dep("MockToken18", []);
await send(w0, strangerToken, A.MockToken18.abi, "mint", [B2.address, gold(1)]);
await send(wB2, strangerToken, A.MockToken18.abi, "approve", [pool, gold(1)]);
check("unregistered collateral cannot be deposited", !(await tryIt(() => send(wB2, pool, A.LendingPool.abi, "depositCollateral", [strangerToken, gold(1)]))));

// ---------- B3: exact repayment clears dust ----------
console.log("=== B3 dust-free repayment ===");
await send(w0, feed, A.MockFeed.abi, "set", [parseUnits("2000", 18), 0]);
const B3 = mk(15);
await fund(B3.address);
const wB3 = createWalletClient({ account: B3, chain, transport: http(RPC) });
await send(w0, pool, A.LendingPool.abi, "setAllowed", [B3.address, true]);
await send(w0, goldT, A.MockToken18.abi, "mint", [B3.address, gold(5)]);
await send(wB3, goldT, A.MockToken18.abi, "approve", [pool, gold(5)]);
await send(wB3, pool, A.LendingPool.abi, "depositCollateral", [goldT, gold(5)]);
await send(wB3, pool, A.LendingPool.abi, "borrow", [usd(3000)]);
const dBefore = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "debtOf", args: [B3.address] });
await send(w0, usdc, A.MockUSDC6.abi, "mint", [B3.address, dBefore]);
await send(wB3, usdc, A.MockUSDC6.abi, "approve", [pool, dBefore]);
await send(wB3, pool, A.LendingPool.abi, "repay", [dBefore]);
const dAfter = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "debtOf", args: [B3.address] });
check("exact repayment leaves zero debt (no dust)", dAfter === 0n, "debt " + dAfter.toString());

console.log(fails === 0 ? "\nAUDIT FIXES VERIFIED" : `\n${fails} FAILURES`);
process.exit(fails === 0 ? 0 : 1);
