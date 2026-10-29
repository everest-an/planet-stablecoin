// PPIPerp keeper: liquidates under-margined positions and can nudge the funding rate.
//
// The keeper is not trusted with funds - it only calls liquidate() (open to anyone) and
// setFundingRate() (bounded by MAX_FUNDING_RATE_PER_SEC). A compromised keeper can annoy the market,
// not drain the pool: liquidation pays the keeper half of the remaining equity, and the funding rate
// is capped on-chain.
//
// Usage:  node perp-keeper.mjs [--once] [--dry]
// Env:    RPC, PERP, PRIVATE_KEY, INTERVAL_MS (default 30000), FUNDING_RATE (optional, 1e18/s)
import { createPublicClient, createWalletClient, http, defineChain, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum, arbitrumSepolia } from "viem/chains";

const ABI = [
  { name: "traders", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }] },
  { name: "positions", type: "function", stateMutability: "view", inputs: [{ type: "address" }],
    outputs: [
      { name: "size", type: "int256" }, { name: "collateral", type: "uint256" },
      { name: "entryPrice", type: "uint256" }, { name: "fundingEntry", type: "int256" }, { name: "open", type: "bool" },
    ] },
  { name: "equityOf", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "int256" }] },
  { name: "maintenanceBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "riskLevel", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { name: "liquidate", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { name: "setFundingRate", type: "function", stateMutability: "nonpayable", inputs: [{ type: "int256" }], outputs: [] },
  { name: "keeper", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
];

function chainFor(rpc) {
  if (/sepolia/.test(rpc)) return arbitrumSepolia;
  if (/127\.0\.0\.1|localhost/.test(rpc)) {
    return defineChain({ id: 31337, name: "local", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpc] } } });
  }
  return arbitrum;
}

export async function runOnce({ rpc, perp, key, dry = false, fundingRate = null, log = console.log }) {
  const chain = chainFor(rpc);
  const pub = createPublicClient({ chain, transport: http(rpc) });
  const account = privateKeyToAccount(key.startsWith("0x") ? key : "0x" + key);
  const wallet = createWalletClient({ account, chain, transport: http(rpc) });

  const risk = await pub.readContract({ address: perp, abi: ABI, functionName: "riskLevel" });
  const maintBps = await pub.readContract({ address: perp, abi: ABI, functionName: "maintenanceBps" });
  const keeperAddr = await pub.readContract({ address: perp, abi: ABI, functionName: "keeper" });

  // Snapshot first: liquidating removes the address (swap-and-pop), so iterating by index while
  // mutating would skip whoever gets swapped into the freed slot.
  const traders = [];
  for (let i = 0; i < 500; i++) {
    try {
      traders.push(await pub.readContract({ address: perp, abi: ABI, functionName: "traders", args: [BigInt(i)] }));
    } catch { break; }
  }
  const n = traders.length;

  const actions = [];
  for (const who of traders) {
    const p = await pub.readContract({ address: perp, abi: ABI, functionName: "positions", args: [who] });
    if (!p[4]) continue;
    const equity = await pub.readContract({ address: perp, abi: ABI, functionName: "equityOf", args: [who] });
    const size = p[0] < 0n ? -p[0] : p[0];
    const maint = (size * BigInt(maintBps)) / 10000n;
    const liquidatable = equity < maint;
    log(`  ${who} size=${formatUnits(p[0], 6)} equity=${formatUnits(equity, 6)} maint=${formatUnits(maint, 6)}${liquidatable ? "  <-- liquidatable" : ""}`);
    if (!liquidatable) continue;
    actions.push(who);
    if (dry) continue;
    try {
      const h = await wallet.writeContract({ address: perp, abi: ABI, functionName: "liquidate", args: [who, 0n] });
      const rc = await pub.waitForTransactionReceipt({ hash: h });
      log(`    liquidated ${who}: ${rc.status} (gas ${rc.gasUsed})`);
    } catch (e) {
      log(`    liquidate failed for ${who}: ${e.shortMessage || e.message}`);
    }
  }

  if (fundingRate !== null && !dry && account.address.toLowerCase() === keeperAddr.toLowerCase()) {
    try {
      const h = await wallet.writeContract({ address: perp, abi: ABI, functionName: "setFundingRate", args: [BigInt(fundingRate)] });
      await pub.waitForTransactionReceipt({ hash: h });
      log(`  funding rate -> ${fundingRate}`);
    } catch (e) {
      log(`  funding update failed: ${e.shortMessage || e.message}`);
    }
  }

  return { risk, positions: n, liquidatable: actions, dry };
}

const isMain = process.argv[1]?.replace(/\\\\/g, "/").endsWith("perp-keeper.mjs");
if (isMain) {
  const rpc = process.env.RPC || "https://arb1.arbitrum.io/rpc";
  const perp = process.env.PERP;
  const key = process.env.PRIVATE_KEY;
  if (!perp || !key) {
    console.error("PERP and PRIVATE_KEY are required");
    process.exit(1);
  }
  const once = process.argv.includes("--once");
  const dry = process.argv.includes("--dry");
  const interval = Number(process.env.INTERVAL_MS || 30000);
  const funding = process.env.FUNDING_RATE ? String(process.env.FUNDING_RATE) : null;

  const tick = async () => {
    const r = await runOnce({ rpc, perp, key, dry, fundingRate: funding });
    console.log(`[${new Date().toISOString()}] risk=${r.risk} positions=${r.positions} liquidatable=${r.liquidatable.length}${r.dry ? " (dry)" : ""}`);
  };
  await tick();
  if (!once) {
    setInterval(() => tick().catch((e) => console.error("tick failed:", e.shortMessage || e.message)), interval);
  }
}
