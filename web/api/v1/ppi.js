// GET /api/v1/ppi — the mainnet index, read straight from Arbitrum One.
// This is the number a venue would settle against: currentPpi, the 14 assets with their weights and
// prices, and the oracle's state. Cached briefly; every field comes from the chain, not a database.
import { createPublicClient, http } from "viem";
import { arbitrum } from "viem/chains";
import { rateLimit } from "../_ratelimit.js";

const CORE = process.env.PPI_CORE || "0x61de052af7cb7dc957a07b1e6298152bb851cbbb";
const ORACLE = process.env.PPI_ORACLE || "0x0daf541ef7e41402070bc549f91475ab368d1824";
const TIMELOCK = process.env.PPI_TIMELOCK || "0xa1fdb9f95210af1d968872f6fc86f623a3e3017c";
const RPC = process.env.ETH_RPC_ONE || "https://arb1.arbitrum.io/rpc";

const CORE_ABI = [
  { name: "currentPpi", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { name: "lastOracleUpdate", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { name: "assetCount", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "weightSum", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { name: "baseLocked", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { name: "owner", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "oracle", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  {
    name: "assets",
    type: "function",
    stateMutability: "view",
    inputs: [{ type: "uint256" }],
    outputs: [
      { name: "weight", type: "uint64" },
      { name: "basePrice", type: "uint64" },
      { name: "currentPrice", type: "uint64" },
      { name: "volatility", type: "uint64" },
      { name: "liquidity", type: "uint64" },
      { name: "riskState", type: "uint8" },
      { name: "lastUpdate", type: "uint64" },
    ],
  },
];
const ORACLE_ABI = [
  { name: "threshold", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { name: "signerCount", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
];

const NAMES = [
  "WTI Crude", "Brent Crude", "Natural Gas", "Gold", "Silver", "Copper", "Wheat",
  "Corn", "Soybean", "Coffee", "Lumber", "Lithium", "Water", "Carbon",
];
const SYMBOLS = ["CL=F", "BZ=F", "NG=F", "GC=F", "SI=F", "HG=F", "ZW=F", "ZC=F", "ZS=F", "KC=F", "WOOD", "LIT", "PHO", "KRBN"];

const pub = createPublicClient({ chain: arbitrum, transport: http(RPC) });
let cache = { at: 0, body: null };

export default async function handler(req, res) {
  if (!rateLimit(req, res, { limit: 30, name: "ppi" })) return;
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "GET" && req.method !== "HEAD") {
    return res.status(405).json({ error: { code: "method_not_allowed", message: "GET only." } });
  }
  if (cache.body && Date.now() - cache.at < 30_000) {
    res.setHeader("Cache-Control", "public, s-maxage=20, stale-while-revalidate=40");
    return res.status(200).json(cache.body);
  }

  try {
    const [ppi, lastUpdate, count, wsum, baseLocked, owner, oracleAddr] = await Promise.all([
      pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "currentPpi" }),
      pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "lastOracleUpdate" }),
      pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "assetCount" }),
      pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "weightSum" }),
      pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "baseLocked" }),
      pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "owner" }),
      pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "oracle" }),
    ]);

    const n = Number(count);
    const assets = [];
    for (let i = 0; i < n; i++) {
      const a = await pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "assets", args: [BigInt(i)] });
      assets.push({
        index: i,
        name: NAMES[i] ?? `asset ${i}`,
        symbol: SYMBOLS[i] ?? "",
        weightPpm: Number(a[0]),
        weightPct: Number(a[0]) / 10000,
        basePrice: Number(a[1]),
        currentPrice: Number(a[2]),
        changePct: (Number(a[2]) / Number(a[1]) - 1) * 100,
        riskState: Number(a[5]),
        lastUpdate: Number(a[6]),
      });
    }

    const body = {
      chain: { name: "arbitrum-one", id: 42161 },
      core: CORE,
      token: process.env.PPI_TOKEN || "0xee270802969f0689e3085331d47679bdc5bf4512",
      timelock: TIMELOCK,
      owner,
      ppi: Number(ppi) / 1e6,
      lastOracleUpdate: Number(lastUpdate),
      oracleAgeSeconds: Math.max(0, Math.floor(Date.now() / 1000) - Number(lastUpdate)),
      assetCount: n,
      weightSum: Number(wsum),
      baseLocked,
      mintingEnabled: false,
      oracle: {
        address: oracleAddr,
        threshold: Number(await pub.readContract({ address: ORACLE, abi: ORACLE_ABI, functionName: "threshold" })),
        signerCount: Number(await pub.readContract({ address: ORACLE, abi: ORACLE_ABI, functionName: "signerCount" })),
        mode: "pull",
        feed: "/api/v1/price-signed",
      },
      assets,
      methodology: "/methodology",
    };
    cache = { at: Date.now(), body };
    res.setHeader("Cache-Control", "public, s-maxage=20, stale-while-revalidate=40");
    return res.status(200).json(body);
  } catch (e) {
    return res.status(503).json({ error: { code: "chain_unavailable", message: e.message } });
  }
}
