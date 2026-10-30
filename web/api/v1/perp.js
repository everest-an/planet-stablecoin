// GET /api/v1/perp — the Sepolia perp market, read straight from the chain.
// Read-only; the page does its own signing. Every field is a chain read, no database.
import { createPublicClient, http } from "viem";
import { arbitrum } from "viem/chains";

const PERP = process.env.PERP_ADDRESS || "0x9c2250914c457914af3bffb085ae44141667f5ac";
const CORE = process.env.PERP_CORE || "0x61de052af7cb7dc957a07b1e6298152bb851cbbb";
const SOURCE = process.env.PERP_SOURCE || "0x5d767020ab6e830f5914fbe11401ad536b720d6c";
const RPC = process.env.PERP_RPC || "https://arbitrum-one-rpc.publicnode.com";

const PERP_ABI = [
  { name: "poolAssets", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "totalShares", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "sharePrice", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "netSize", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "int256" }] },
  { name: "totalCollateral", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "maxLeverageBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "openFeeBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "maintenanceBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "protocolShareBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "maxOiToPoolBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "paused", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { name: "keeper", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "treasury", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "riskLevel", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
];
const SOURCE_ABI = [
  { name: "price", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "usdPerIndex", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
];
const CORE_ABI = [
  { name: "currentPpi", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { name: "lastOracleUpdate", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { name: "assetCount", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
];

const pub = createPublicClient({ chain: arbitrum, transport: http(RPC) });
let cache = { at: 0, body: null };

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "GET" && req.method !== "HEAD") {
    return res.status(405).json({ error: { code: "method_not_allowed", message: "GET only." } });
  }
  if (cache.body && Date.now() - cache.at < 20_000) {
    res.setHeader("Cache-Control", "public, s-maxage=15, stale-while-revalidate=30");
    return res.status(200).json(cache.body);
  }

  try {
    const readPerp = (fn) => pub.readContract({ address: PERP, abi: PERP_ABI, functionName: fn });
    const [poolAssets, totalShares, sharePrice, netSize, totalCollateral, maxLev, openFee, maint, protShare, oiCap, paused, keeper, treasury, risk] =
      await Promise.all([
        readPerp("poolAssets"), readPerp("totalShares"), readPerp("sharePrice"), readPerp("netSize"),
        readPerp("totalCollateral"), readPerp("maxLeverageBps"), readPerp("openFeeBps"), readPerp("maintenanceBps"),
        readPerp("protocolShareBps"), readPerp("maxOiToPoolBps"), readPerp("paused"), readPerp("keeper"),
        readPerp("treasury"), readPerp("riskLevel"),
      ]);
    const price = await pub.readContract({ address: SOURCE, abi: SOURCE_ABI, functionName: "price" });
    const usdPerIndex = await pub.readContract({ address: SOURCE, abi: SOURCE_ABI, functionName: "usdPerIndex" });
    const ppi = await pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "currentPpi" });
    const lastUpdate = await pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "lastOracleUpdate" });
    const assets = await pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "assetCount" });

    const body = {
      chain: { name: "arbitrum-one", id: 42161 },
      contracts: { perp: PERP, core: CORE, priceSource: SOURCE, collateral: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831" },
      market: {
        price: Number(price) / 1e18,
        ppi: Number(ppi) / 1e6,
        usdPerIndex: Number(usdPerIndex),
        assets: Number(assets),
        oracleAgeSeconds: Math.max(0, Math.floor(Date.now() / 1000) - Number(lastUpdate)),
        riskLevel: Number(risk),
        riskLabel: Number(risk) === 0 ? "normal" : Number(risk) === 1 ? "caution" : "frozen",
        paused,
        maxLeverage: Number(maxLev) / 10000,
        maintenancePct: Number(maint) / 100,
        openFeePct: Number(openFee) / 100,
        protocolSharePct: Number(protShare) / 100,
        maxOiToPool: Number(oiCap) / 10000,
      },
      pool: {
        assets: Number(poolAssets) / 1e6,
        shares: Number(totalShares) / 1e6,
        sharePrice: Number(sharePrice) / 1e6,
        netExposure: Number(netSize) / 1e6,
        traderCollateral: Number(totalCollateral) / 1e6,
      },
      roles: { keeper, treasury },
      notes: [
        "Arbitrum One limited beta. Collateral is real USDC. The contracts are self-audited, not externally audited.",
        "The pool is empty until an LP deposits; open interest is capped at 2x the pool.",
      ],
    };
    cache = { at: Date.now(), body };
    res.setHeader("Cache-Control", "public, s-maxage=15, stale-while-revalidate=30");
    return res.status(200).json(body);
  } catch (e) {
    return res.status(503).json({ error: { code: "chain_unavailable", message: e.message } });
  }
}
