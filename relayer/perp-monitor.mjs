// Hourly invariant monitor. The one thing that must never silently break: the pool's accounting.
// Alerts through the same Telegram bot the oracle monitor uses.
//
// Env: RPC, PERP, TG_BOT_TOKEN, TG_ALERT_CHAT_ID (all optional except RPC/PERP)
import { createPublicClient, http, formatUnits } from "viem";
import { arbitrum, arbitrumSepolia, sepolia } from "viem/chains";

const RPC = process.env.RPC || "https://ethereum-sepolia-rpc.publicnode.com";
const PERP = process.env.PERP || "0x48fecec7f876540a4584fc71c22b8d49051ffe26";
const TG = process.env.TG_BOT_TOKEN;
const CHAT = process.env.TG_ALERT_CHAT_ID;

const chain = /arb1/.test(RPC) ? arbitrum : /sepolia-rollup/.test(RPC) ? arbitrumSepolia : sepolia;
const USDC = process.env.COLLATERAL || "0x5a46eca6a7ee7b1514715f29bd9305d0db34b5ef";

const ABI = [
  { name: "poolAssets", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "totalCollateral", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "netSize", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "int256" }] },
  { name: "totalShares", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "riskLevel", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { name: "paused", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { name: "maxOiToPoolBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "traders", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }] },
  { name: "positions", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "int256" }, { type: "uint256" }, { type: "uint256" }, { type: "int256" }, { type: "bool" }] },
];
const ERC20 = [{ name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] }];

const pub = createPublicClient({ chain, transport: http(RPC, { timeout: 60000, retryCount: 3 }) });
const alerts = [];

try {
  const [poolAssets, totalCollateral, netSize, totalShares, risk, paused, oiCap] = await Promise.all([
    pub.readContract({ address: PERP, abi: ABI, functionName: "poolAssets" }),
    pub.readContract({ address: PERP, abi: ABI, functionName: "totalCollateral" }),
    pub.readContract({ address: PERP, abi: ABI, functionName: "netSize" }),
    pub.readContract({ address: PERP, abi: ABI, functionName: "totalShares" }),
    pub.readContract({ address: PERP, abi: ABI, functionName: "riskLevel" }),
    pub.readContract({ address: PERP, abi: ABI, functionName: "paused" }),
    pub.readContract({ address: PERP, abi: ABI, functionName: "maxOiToPoolBps" }),
  ]);
  const balance = await pub.readContract({ address: USDC, abi: ERC20, functionName: "balanceOf", args: [PERP] });

  // I1: the invariant every settlement writes against
  if (balance !== totalCollateral + poolAssets) {
    alerts.push(`INVARIANT BROKEN: balance ${formatUnits(balance, 6)} != collateral ${formatUnits(totalCollateral, 6)} + pool ${formatUnits(poolAssets, 6)}`);
  }

  // I2/I3: positions must agree with the aggregates
  let sumColl = 0n, sumSize = 0n, n = 0;
  for (let i = 0; i < 500; i++) {
    const who = await pub.readContract({ address: PERP, abi: ABI, functionName: "traders", args: [BigInt(i)] }).catch(() => null);
    if (!who) break;
    n++;
    const p = await pub.readContract({ address: PERP, abi: ABI, functionName: "positions", args: [who] });
    if (!p[4]) { alerts.push(`LISTED WITHOUT POSITION: ${who}`); continue; }
    sumColl += p[1];
    sumSize += p[0];
  }
  if (sumColl !== totalCollateral) alerts.push(`COLLATERAL SUM ${formatUnits(sumColl, 6)} != ${formatUnits(totalCollateral, 6)}`);
  if (sumSize !== netSize) alerts.push(`SIZE SUM ${formatUnits(sumSize, 6)} != ${formatUnits(netSize, 6)}`);

  // exposure beyond the configured multiple is a solvency red flag
  const exposure = netSize < 0n ? -netSize : netSize;
  if (exposure > (poolAssets * oiCap) / 10000n) alerts.push(`EXPOSURE ${formatUnits(exposure, 6)} > cap ${formatUnits((poolAssets * oiCap) / 10000n, 6)}`);

  if (risk === 2) alerts.push("RISK FROZEN: the index is stale or an asset is frozen — the market is close-only");

  console.log(
    `${chain.name} | pool ${formatUnits(poolAssets, 6)} | collateral ${formatUnits(totalCollateral, 6)} | ` +
      `balance ${formatUnits(balance, 6)} | net ${formatUnits(netSize, 6)} | positions ${n} | risk ${risk} | paused ${paused}`,
  );
} catch (e) {
  alerts.push(`MONITOR FAILED TO READ: ${e.shortMessage || e.message}`);
}

if (alerts.length === 0) {
  console.log("all invariants hold");
  process.exit(0);
}

for (const a of alerts) console.error("ALERT:", a);

if (TG && CHAT) {
  const text = `Planet perp monitor\n${alerts.map((a) => "• " + a).join("\n")}`;
  await fetch(`https://api.telegram.org/bot${TG}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: CHAT, text }),
  }).catch(() => {});
}
process.exit(1);
