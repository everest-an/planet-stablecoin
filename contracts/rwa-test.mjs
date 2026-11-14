import { createPublicClient, createWalletClient, http, defineChain, parseUnits, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";

const A = JSON.parse(readFileSync("./rwa-artifacts.json", "utf8"));
const RPC = "http://127.0.0.1:8545";
const chain = defineChain({ id: 31337, name: "hardhat", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pk = (i) => `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`.replace(/^0x/, "0x");
const acct0 = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const mk = (i) => privateKeyToAccount(("0x" + String(i).padStart(64, "0")));
const pub = createPublicClient({ chain, transport: http(RPC) });
const w0 = createWalletClient({ account: acct0, chain, transport: http(RPC) });
const usd = (n) => parseUnits(String(n), 6);
const gold = (n) => parseUnits(String(n), 18);

const deploy = async (name, args) => {
  const h = await w0.deployContract({ abi: A[name].abi, bytecode: A[name].bytecode, args });
  return (await pub.waitForTransactionReceipt({ hash: h })).contractAddress;
};
const send = async (w, addr, abi, fn, args = []) => {
  const h = await w.writeContract({ address: addr, abi, functionName: fn, args });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  if (rc.status !== "success") throw new Error(fn + " reverted");
  return rc;
};
const trySend = async (w, addr, abi, fn, args = []) => { try { await send(w, addr, abi, fn, args); return true; } catch { return false; } };
let fails = 0;
const check = (label, cond, extra = "") => { console.log(`${cond ? "PASS" : "FAIL"}  ${label}${extra ? "  " + extra : ""}`); if (!cond) fails++; };

// funding for custom keys (accounts beyond the hardhat mnemonic)
const fund = async (addr) => { const h = await w0.sendTransaction({ to: addr, value: 10n ** 18n }); await pub.waitForTransactionReceipt({ hash: h }); };
const lenderA = mk(1), borrowerA = mk(2), liquidatorA = mk(3);
for (const a of [lenderA, borrowerA, liquidatorA]) await fund(a.address);
const wL = createWalletClient({ account: lenderA, chain, transport: http(RPC) });
const wB = createWalletClient({ account: borrowerA, chain, transport: http(RPC) });
const wX = createWalletClient({ account: liquidatorA, chain, transport: http(RPC) });

const usdc = await deploy("MockUSDC6", []);
const goldToken = await deploy("MockToken18", []);
const feed = await deploy("MockFeed", [parseUnits("2000", 18), 0]);
const registry = await deploy("CollateralRegistry", [acct0.address]);
const pool = await deploy("LendingPool", [usdc, registry, acct0.address]);

await send(w0, registry, A.CollateralRegistry.abi, "setAsset", [goldToken, feed, 7000, 6000, 8000]);
console.log("asset: gold, LTV 70% / caution 60% / liq 80%");

for (const w of [wL, wB, wX]) await send(w0, pool, A.LendingPool.abi, "setAllowed", [w.account.address, true]);

// lender supplies 100,000 USDC
await send(w0, usdc, A.MockUSDC6.abi, "mint", [lenderA.address, usd(100000)]);
await send(wL, usdc, A.MockUSDC6.abi, "approve", [pool, usd(100000)]);
await send(wL, pool, A.LendingPool.abi, "deposit", [usd(100000)]);
check("supply 100k", (await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "totalSupplyAssets" })) === usd(100000));

// borrower pledges 10 gold = 20,000 USD
await send(w0, goldToken, A.MockToken18.abi, "mint", [borrowerA.address, gold(10)]);
await send(wB, goldToken, A.MockToken18.abi, "approve", [pool, gold(10)]);
await send(wB, pool, A.LendingPool.abi, "depositCollateral", [goldToken, gold(10)]);
const limit0 = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "borrowLimit", args: [borrowerA.address] });
check("normal LTV 70% -> 14,000", limit0 === usd(14000), formatUnits(limit0, 6));

check("borrow 14,000", await trySend(wB, pool, A.LendingPool.abi, "borrow", [usd(14000)]));
check("borrow beyond limit rejected", !(await trySend(wB, pool, A.LendingPool.abi, "borrow", [usd(1)])));

// caution lowers the limit to 60%
await send(w0, feed, A.MockFeed.abi, "set", [parseUnits("2000", 18), 1]);
const limit1 = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "borrowLimit", args: [borrowerA.address] });
check("caution LTV 60% -> 12,000", limit1 === usd(12000), formatUnits(limit1, 6));
check("caution blocks further borrowing", !(await trySend(wB, pool, A.LendingPool.abi, "borrow", [usd(1)])));

// frozen blocks all new borrowing
await send(w0, feed, A.MockFeed.abi, "set", [parseUnits("2000", 18), 2]);
const limit2 = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "borrowLimit", args: [borrowerA.address] });
check("frozen LTV 0", limit2 === 0n);
check("frozen blocks borrowing", !(await trySend(wB, pool, A.LendingPool.abi, "borrow", [usd(1)])));

// price drop -> unhealthy -> liquidation
await send(w0, feed, A.MockFeed.abi, "set", [parseUnits("1500", 18), 0]);
const liqLimit = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "liquidationLimit", args: [borrowerA.address] });
check("liq limit 80% of 15,000 = 12,000", liqLimit === usd(12000), formatUnits(liqLimit, 6));
const debt = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "debtOf", args: [borrowerA.address] });
check("debt 14,000 > liq limit -> liquidatable", debt >= liqLimit);

await send(w0, usdc, A.MockUSDC6.abi, "mint", [liquidatorA.address, usd(20000)]);
await send(wX, usdc, A.MockUSDC6.abi, "approve", [pool, usd(20000)]);
check("liquidation executes", await trySend(wX, pool, A.LendingPool.abi, "liquidate", [borrowerA.address]));
const debtAfter = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "debtOf", args: [borrowerA.address] });
check("debt cleared", debtAfter === 0n);
const seized = await pub.readContract({ address: pool, abi: A.LendingPool.abi, functionName: "collateral", args: [borrowerA.address, goldToken] });
check("collateral seized (~98%)", seized < gold(0.3), formatUnits(seized, 18));

// compliance + pause
const stranger = mk(9);
await fund(stranger.address);
const wS = createWalletClient({ account: stranger, chain, transport: http(RPC) });
check("not allow-listed cannot supply", !(await trySend(wS, pool, A.LendingPool.abi, "deposit", [usd(1)])));
await send(w0, pool, A.LendingPool.abi, "setPaused", [true]);
check("paused blocks supply", !(await trySend(wL, pool, A.LendingPool.abi, "deposit", [usd(1)])));
await send(w0, pool, A.LendingPool.abi, "setPaused", [false]);

console.log(fails === 0 ? "\nALL RWA TESTS PASSED" : `\n${fails} FAILURES`);
process.exit(fails === 0 ? 0 : 1);
