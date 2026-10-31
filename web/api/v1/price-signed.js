// GET /api/v1/price-signed — the pull-oracle feed.
//
// Signs one payload per asset on demand. A consumer submits them on-chain in ITS OWN transaction
// via PlanetCore.updatePriceSigned(payload, sig) and pays that gas; this publisher pays nothing.
// The signer key lives in ORACLE_SIGNER_KEY (server-side only, no funds at risk: it can only sign
// prices, and the oracle's signer set is what authorises it).
import { keccak256, encodeAbiParameters, parseAbiParameters, createPublicClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { ASSETS, readAsset } from "../_channels.js";
import { rateLimit } from "../_ratelimit.js";

const ORACLE = process.env.PPI_ORACLE || "0x0daf541ef7e41402070bc549f91475ab368d1824";
const CORE = process.env.PPI_CORE || "0x61de052af7cb7dc957a07b1e6298152bb851cbbb";
const RPC = process.env.ETH_RPC || "https://arb1.arbitrum.io/rpc";
const KEY = process.env.ORACLE_SIGNER_KEY || "";
const KEY2 = process.env.ORACLE_SIGNER_KEY_2 || "";
const SCALE = 1_000_000;
const DOMAIN = keccak256(new TextEncoder().encode("PLANET_PRICE_V1"));

const pub = createPublicClient({ chain: arbitrum, transport: http(RPC) });

let cache = { at: 0, prices: null };
async function prices() {
  if (cache.prices && Date.now() - cache.at < 60_000) return cache.prices;
  const out = await Promise.all(ASSETS.map(async (a) => ({ a, agg: await readAsset(a).catch(() => ({ ok: false })) })));
  cache = { at: Date.now(), prices: out };
  return out;
}

export default async function handler(req, res) {
  if (!rateLimit(req, res, { limit: 8, name: "price-signed" })) return;
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "GET" && req.method !== "HEAD") {
    return res.status(405).json({ error: { code: "method_not_allowed", message: "GET only." } });
  }
  if (!KEY || !KEY2) {
    return res.status(503).json({ error: { code: "not_configured", message: "ORACLE_SIGNER_KEY and ORACLE_SIGNER_KEY_2 are both required (2-of-3)." } });
  }

  try {
    const account = privateKeyToAccount(KEY.startsWith("0x") ? KEY : "0x" + KEY);
    const account2 = privateKeyToAccount(KEY2.startsWith("0x") ? KEY2 : "0x" + KEY2);
    const chainId = BigInt(await pub.getChainId());
    const last = await pub.readContract({
      address: CORE,
      abi: [{ name: "lastOracleUpdate", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] }],
      functionName: "lastOracleUpdate",
    });
    // timestamps must exceed the global lastOracleUpdate and be unique per asset
    const nowTs = BigInt(Math.floor(Date.now() / 1000) + 120);
    const nextTs = BigInt(last) + 1n;
    const base = nowTs > nextTs ? nowTs : nextTs + 1n;

    const rows = await prices();
    const payloads = [];
    for (const { a, agg } of rows) {
      if (!agg.ok) continue;
      const p = {
        index: BigInt(a.i),
        price: BigInt(Math.round(agg.price * SCALE)),
        volatility: 0n,
        liquidity: BigInt(SCALE),
        riskState: Number(agg.riskState ?? 0),
        timestamp: base + BigInt(a.i),
      };
      const digest = keccak256(
        encodeAbiParameters(
          parseAbiParameters("bytes32, address, uint256, address, uint256, uint64, uint64, uint64, uint8, uint64"),
          [DOMAIN, ORACLE, chainId, CORE, p.index, p.price, p.volatility, p.liquidity, p.riskState, p.timestamp],
        ),
      );
      const s1 = await account.sign({ hash: digest });
      const s2 = await account2.sign({ hash: digest });
      // the oracle reads 65-byte r||s||v blocks back to back
      const sig = "0x" + s1.slice(2) + s2.slice(2);
      payloads.push({
        index: Number(p.index),
        symbol: a.sym,
        price: p.price.toString(),
        volatility: p.volatility.toString(),
        liquidity: p.liquidity.toString(),
        riskState: p.riskState,
        timestamp: p.timestamp.toString(),
        sig,
      });
    }

    res.setHeader("Cache-Control", "public, s-maxage=30, stale-while-revalidate=60");
    return res.status(200).json({
      oracle: ORACLE,
      core: CORE,
      chainId: Number(chainId),
      signer: account.address,
      generatedAt: new Date().toISOString(),
      payloads,
    });
  } catch (e) {
    return res.status(503).json({ error: { code: "sign_failed", message: e.message } });
  }
}
