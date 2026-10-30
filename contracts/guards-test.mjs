import { createPublicClient, createWalletClient, http, defineChain, parseUnits, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";

const A = JSON.parse(readFileSync("./perp-artifacts.json", "utf8"));
const RPC = "http://127.0.0.1:8545";
const chain = defineChain({ id: 31337, name: "hardhat", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const account = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const pub = createPublicClient({ chain, transport: http(RPC) });
const w = createWalletClient({ account, chain, transport: http(RPC) });
const read = (a, abi, fn, args = []) => pub.readContract({ address: a, abi, functionName: fn, args });
const send = async (a, abi, fn, args = []) => {
  const h = await w.writeContract({ address: a, abi, functionName: fn, args });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  if (rc.status !== "success") throw new Error(fn + " reverted");
};
const deploy = async (n, args) => {
  const h = await w.deployContract({ abi: A[n].abi, bytecode: A[n].bytecode, args });
  return (await pub.waitForTransactionReceipt({ hash: h })).contractAddress;
};
const usd = (n) => parseUnits(String(n), 6);
const show = (v) => Number(formatUnits(v, 6)).toFixed(2);
let fails = 0;
const check = (label, cond, extra = "") => {
  console.log(`${cond ? "PASS" : "FAIL"}  ${label}${extra ? "  " + extra : ""}`);
  if (!cond) fails++;
};

// ---------- PPIPriceSource: future timestamp must not revert ----------
console.log("=== price source ===");
const core = await deploy("MockCore", []);
const src = await deploy("PPIPriceSource", [core, 1000n]);
const now = Number((await pub.getBlock()).timestamp);
await send(core, A.MockCore.abi, "set", [1000000n, BigInt(now + 120), 0]);

let riskNow;
try {
  riskNow = await read(src, A.PPIPriceSource.abi, "riskLevel");
  check("future timestamp does not revert", true, "riskLevel=" + riskNow);
} catch (e) {
  check("future timestamp does not revert", false, e.shortMessage || e.message);
  riskNow = null;
}
if (riskNow !== null) check("future timestamp => level 0", riskNow === 0);

const p = await read(src, A.PPIPriceSource.abi, "price");
check("price = PPI x usdPerIndex", p === parseUnits("1000", 18), show(p) + " USD/unit");

await send(core, A.MockCore.abi, "set", [1000000n, BigInt(now - 3 * 3600), 0]);
const stale = await read(src, A.PPIPriceSource.abi, "riskLevel");
check("3h stale => caution", stale === 1, "level=" + stale);
await send(core, A.MockCore.abi, "set", [1000000n, BigInt(now - 7 * 3600), 0]);
const dead = await read(src, A.PPIPriceSource.abi, "riskLevel");
check("7h stale => frozen", dead === 2, "level=" + dead);
await send(core, A.MockCore.abi, "set", [1000000n, BigInt(now - 60), 1]);
const caution = await read(src, A.PPIPriceSource.abi, "riskLevel");
check("asset caution propagates", caution === 1, "level=" + caution);

// a core with an active relayer must be refused: the perp may only price off the 2-of-3 path
await send(core, A.MockCore.abi, "setRelayer", [account.address]);
let refused = false;
try {
  await deploy("PPIPriceSource", [core, 1000n]);
} catch {
  refused = true;
}
check("price source refuses a core with an active relayer", refused);

// ---------- perp new guards ----------
console.log("\n=== perp guards ===");
const price = await deploy("MockPrice", [parseUnits("1000", 18), 0]);
const usdc = await deploy("MockUSDC", []);
const perp = await deploy("PPIPerp", [usdc, price, account.address]);
const treasury = "0x00000000000000000000000000000000000000aa";
await send(perp, A.PPIPerp.abi, "setTreasury", [treasury]);
await send(usdc, A.MockUSDC.abi, "mint", [account.address, usd(100000)]);
await send(usdc, A.MockUSDC.abi, "approve", [perp, 2n ** 255n]);

// protocol fee: 30% of the open fee to treasury
const tBefore = await read(usdc, A.MockUSDC.abi, "balanceOf", [treasury]);
await send(perp, A.PPIPerp.abi, "deposit", [usd(10000)]);
await send(perp, A.PPIPerp.abi, "open", [usd(1000), usd(100)]);
const tAfter = await read(usdc, A.MockUSDC.abi, "balanceOf", [treasury]);
// fee = 1000 * 10bps = 1.00; 30% = 0.30
check("protocol fee 30% of open fee", Math.abs(Number(tAfter - tBefore) / 1e6 - 0.3) < 0.01, "got " + show(tAfter - tBefore));
await send(perp, A.PPIPerp.abi, "close", []);

// OI cap relative to pool: pool 10k, cap 2x = 20k; asking 25k must revert
let capped = false;
try {
  await send(perp, A.PPIPerp.abi, "open", [usd(25000), usd(5000)]);
} catch {
  capped = true;
}
check("OI cannot exceed 2x pool", capped);

// withdraw guard: open 15k (<= 2x pool of 10k), then try to withdraw everything
await send(perp, A.PPIPerp.abi, "open", [usd(15000), usd(3000)]);
let blocked = false;
try {
  await send(perp, A.PPIPerp.abi, "withdraw", [await read(perp, A.PPIPerp.abi, "shares", [account.address])]);
} catch {
  blocked = true;
}
check("withdraw blocked while OI needs the capital", blocked);

// frozen liquidation guard: borderline position (equity >= maint/2) must not liquidate
await send(perp, A.PPIPerp.abi, "close", []);
await send(price, A.MockPrice.abi, "set", [parseUnits("1000", 18), 2]); // frozen
await send(price, A.MockPrice.abi, "set", [parseUnits("1000", 18), 0]);
await send(perp, A.PPIPerp.abi, "open", [usd(10000), usd(1000)]); // 10x
await send(price, A.MockPrice.abi, "set", [parseUnits("960", 18), 0]); // -4%: equity ~595, maint 500, maint/2 250
const eq = await read(perp, A.PPIPerp.abi, "equityOf", [account.address]);
await send(price, A.MockPrice.abi, "set", [parseUnits("960", 18), 2]); // now frozen
let liquidatedWhileFrozen = false;
try {
  await send(perp, A.PPIPerp.abi, "liquidate", [account.address, 0n]);
  liquidatedWhileFrozen = true;
} catch {
  liquidatedWhileFrozen = false;
}
check("frozen feed: borderline position protected", !liquidatedWhileFrozen, "equity=" + show(eq));

// deeply underwater while frozen must still be liquidatable
await send(price, A.MockPrice.abi, "set", [parseUnits("880", 18), 2]); // -12%: equity ~ -205
const eq2 = await read(perp, A.PPIPerp.abi, "equityOf", [account.address]);
let liq2 = false;
try {
  await send(perp, A.PPIPerp.abi, "liquidate", [account.address, 0n]);
  liq2 = true;
} catch (e) {
  console.log("   (", e.shortMessage || e.message, ")");
}
check("frozen feed: deeply underwater still liquidatable", liq2, "equity=" + show(eq2));

console.log(`\n${fails === 0 ? "ALL PASS" : fails + " FAILURE(S)"}`);
process.exit(fails ? 1 : 0);
