// Behavior tests for the v2 additions: the guardian emergency pause and the TWAP liquidation gate.
// Runs against the local hardhat node like the other guard scripts.
import { createPublicClient, createWalletClient, http, defineChain, parseUnits, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";

const A = JSON.parse(readFileSync("./perp-artifacts.json", "utf8"));
const RPC = "http://127.0.0.1:8545";
const chain = defineChain({ id: 31337, name: "hardhat", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const acct = (i) => privateKeyToAccount(i === 0 ? "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" : `0x00000000000000000000000000000000000000000000000000000000000000${String(i)}0`);
const pub = createPublicClient({ chain, transport: http(RPC) });
const w = createWalletClient({ account: acct(0), chain, transport: http(RPC) });
const read = (a, abi, fn, args = []) => pub.readContract({ address: a, abi, functionName: fn, args });
const deploy = async (n, args) => {
  const h = await w.deployContract({ abi: A[n].abi, bytecode: A[n].bytecode, args });
  return (await pub.waitForTransactionReceipt({ hash: h })).contractAddress;
};
const tx = async (fn) => { try { await fn(); return true; } catch { return false; } };
let fails = 0;
const check = (label, cond, extra = "") => { console.log(`${cond ? "PASS" : "FAIL"}  ${label}${extra ? "  " + extra : ""}`); if (!cond) fails++; };

const usdc = await deploy("MockUSDC", []);
const src = await deploy("MockPrice", [BigInt(1000) * 10n ** 18n, 0]);
const perp = await deploy("PPIPerp", [usdc, src, acct(0).address]);
const mint = async (to, n) => tx(() => w.writeContract({ address: usdc, abi: A.MockUSDC.abi, functionName: "mint", args: [to, parseUnits(String(n), 6)] }));

// ---------- guardian ----------
console.log("=== guardian ===");
// custom keys are not in the hardhat mnemonic; fund every one of them so their txs can run
for (const i of [1, 2, 3, 4]) {
  await tx(() => w.sendTransaction({ to: acct(i).address, value: 10n ** 18n }));
}
const guardianAddr = acct(3).address;
await tx(() => w.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "setGuardian", args: [guardianAddr] }));
check("guardian set", (await read(perp, A.PPIPerp.abi, "guardian")) === guardianAddr);

const w3 = createWalletClient({ account: acct(3), chain, transport: http(RPC) });
check("guardian can pause instantly", await tx(() => w3.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "emergencyPause" })));
check("market is paused", await read(perp, A.PPIPerp.abi, "paused"));
check("guardian CANNOT unpause", !(await tx(() => w3.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "setPaused", args: [false] }))));
check("guardian CANNOT do anything else (setKeeper)", !(await tx(() => w3.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "setKeeper", args: [guardianAddr] }))));
const rando = createWalletClient({ account: acct(4), chain, transport: http(RPC) });
check("random address cannot pause", !(await tx(() => rando.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "emergencyPause" }))));
await tx(() => w.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "setPaused", args: [false] }));

// ---------- TWAP gate ----------
console.log("=== TWAP liquidation gate ===");
const trader = acct(1).address;
const usd = (n) => parseUnits(String(n), 6);
await mint(trader, 10000);
const wt = createWalletClient({ account: acct(1), chain, transport: http(RPC) });
await tx(() => wt.writeContract({ address: usdc, abi: A.MockUSDC.abi, functionName: "approve", args: [perp, usd(10000)] }));
// LP deposits to make the pool able to pay
await mint(acct(0).address, 100000);
await tx(() => w.writeContract({ address: usdc, abi: A.MockUSDC.abi, functionName: "approve", args: [perp, usd(100000)] }));
await tx(() => w.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "deposit", args: [usd(100000)] }));
// set riskLevel on the mock to 0 and open a 3x long at spot 1000e18
const set = async (priceV, levelV) => tx(() => w.writeContract({ address: src, abi: A.MockPrice.abi, functionName: "set", args: [BigInt(priceV) * 10n ** 18n, levelV] }));
const setTwap = async (v) => tx(() => w.writeContract({ address: src, abi: A.MockPrice.abi, functionName: "setTwap", args: [v === 0 ? 0n : BigInt(v) * 10n ** 18n] }));
await set(1000, 0);
await setTwap(0); // twap == spot
await tx(() => w.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "setParams", args: [30000n, 10n, 10n, 1000n] }));
await tx(() => wt.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "open", args: [usd(3000), usd(1000)] }));

// now: spot crashes to 750 (underwater at 3x, maint 10%: liquidation below ~766) but twap says 800
await set(750, 0);
await setTwap(800);
check("underwater at spot only -> liquidation REJECTED (wick protected)",
  !(await tx(() => w.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "liquidate", args: [trader, 0n] }))));

// now twap also crashes: 810 -> underwater at both -> liquidates
await setTwap(760);
check("underwater at both -> liquidation executes",
  await tx(() => w.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "liquidate", args: [trader, 0n] })));

// short position variant: spot spikes up against a short
const trader2 = acct(2).address;
await mint(trader2, 10000);
const w2 = createWalletClient({ account: acct(2), chain, transport: http(RPC) });
await tx(() => w2.writeContract({ address: usdc, abi: A.MockUSDC.abi, functionName: "approve", args: [perp, usd(10000)] }));
await set(1000, 0);
await setTwap(0);
await tx(() => w2.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "open", args: [usd(-3000), usd(1000)] }));
await set(1250, 0); // short underwater at spot
await setTwap(1005); // twap fine (short equity positive there)
check("short underwater at spot only -> REJECTED",
  !(await tx(() => w.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "liquidate", args: [trader2, 0n] }))));
await setTwap(1240);
check("short underwater at both -> executes",
  await tx(() => w.writeContract({ address: perp, abi: A.PPIPerp.abi, functionName: "liquidate", args: [trader2, 0n] })));

console.log(fails === 0 ? "ALL NEW-BEHAVIOR TESTS PASSED" : `${fails} FAILURES`);
process.exit(fails === 0 ? 0 : 1);
