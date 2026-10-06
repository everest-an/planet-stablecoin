// Public read API for PlanetCore — white paper appendix III (`/get_ppi`, `/reserves`).
// GET /api/status  ->  JSON snapshot of the on-chain basket + PPI + reserve/supply/fees.
//
// Serverless (Vercel Node runtime), no dependencies: it calls the public TON testnet
// `runGetMethod` RPC directly and decodes the returned stack (ints + tuples).

const CORE = process.env.PLANET_CORE || "kQBUZM0RwN4SXnQDO1q9WzmG2aaiOSD6ybkpaG9LSQ1Aj3Jf";
// Previous deployment, used as a fallback while the current core is being (re)configured.
const CORE_FALLBACK = "kQAzxh1PoqeXWVYQrABxZky8_bAXddjoGTPbqN4tv8Zsfuul";
const ENDPOINT = process.env.TON_ENDPOINT || "https://testnet.toncenter.com/api/v2/runGetMethod";
const API_KEY = process.env.TON_API_KEY || ""; // optional: raises the public RPC rate limit
const PPI_SCALE = 1e6;
const WEIGHT_SCALE = 1e6;
const SPACING_MS = 600;

// Display names, index-aligned with the on-chain basket (see relayer/assets.example.json).
// The chain stores weights/prices only, so names live here for the dashboard.
const NAMES = [
  "WTI Crude",
  "Brent Crude",
  "Natural Gas",
  "Gold",
  "Silver",
  "Copper",
  "Wheat",
  "Corn",
  "Soybean",
  "Coffee",
  "Lumber (ETF)",
  "Lithium (ETF)",
  "Water (ETF)",
  "Carbon (ETF)",
];

let ACTIVE = CORE; // resolved per request (falls back when the current core has no basket)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Decode one toncenter stack entry: ["num","0x.."] | ["tuple",[..]] | ["cell"/"slice", b64]
function decode(entry) {
  if (!entry) return null;
  const [type, value] = entry;
  if (type === "num") return BigInt(value).toString();
  if (type === "tuple") return value.map(decode);
  return null; // cells/slices (addresses) are not needed here
}

// The public testnet RPC rate-limits aggressively (HTTP 429). Retry with backoff so a
// burst of get-method calls still resolves; the CDN caches the successful response.
async function runGet(method, stack = [], tries = 8) {
  for (let a = 0; a < tries; a++) {
    const res = await fetch(ENDPOINT, {
      method: "POST",
      headers: { "content-type": "application/json", ...(API_KEY ? { "X-API-Key": API_KEY } : {}) },
      body: JSON.stringify({ address: ACTIVE, method, stack }),
    });
    if (res.status === 429) {
      await sleep(700 * (a + 1));
      continue;
    }
    if (!res.ok) throw new Error(`runGet ${method}: HTTP ${res.status}`);
    const j = await res.json();
    if (j.error) throw new Error(`runGet ${method}: ${j.error.message}`);
    // A non-zero exit code means the call failed (e.g. the account is not initialised).
    if (j?.result?.exit_code !== 0) throw new Error(`runGet ${method}: exit ${j?.result?.exit_code}`);
    return (j?.result?.stack ?? []).map(decode);
  }
  throw new Error(`runGet ${method}: rate-limited`);
}

const n = (v) => (v == null ? 0 : Number(v));

const tryGet = async (method, stack) => {
  try {
    return await runGet(method, stack);
  } catch {
    return null;
  }
};

export default async function handler(_req, res) {
  let partial = false;
  try {
    ACTIVE = CORE;
    const ac0 = await tryGet("assetCount");
    let assetCount = n(ac0 ? ac0[0] : null);
    if (assetCount === 0) {
      ACTIVE = CORE_FALLBACK; // current core not configured yet -> serve the previous one
      const ac1 = await tryGet("assetCount");
      assetCount = n(ac1 ? ac1[0] : null);
    }

    // Scalars, sequentially (the public RPC rate-limits bursts).
    const scalar = async (m) => {
      const arr = await tryGet(m);
      if (arr == null || arr.length === 0) partial = true;
      await sleep(SPACING_MS);
      return arr ? arr[0] : null;
    };
    const ppi = await scalar("ppi");
    const supply = await scalar("supply");
    const reserve = await scalar("reserve");
    const lastOracleUpdate = await scalar("lastOracleUpdate");
    const riskFund = await scalar("riskFund");
    const threshold = await scalar("threshold");
    const feesBurn = await scalar("feesBurn");
    const feesReserve = await scalar("feesReserve");
    const feesStaking = await scalar("feesStaking");

    const assets = [];
    for (let i = 0; i < assetCount; i++) {
      // toncenter v2 expects stack entries as ["num","0x<hex>"] (not the v3 {type,value} shape).
      // A struct return is FLATTENED onto the stack (6 ints for CoreAsset).
      const a = await tryGet("assetAt", [["num", "0x" + i.toString(16)]]);
      if (a == null || a.length < 6) {
        partial = true;
        break;
      }
      const [weight, basePrice, currentPrice, volatility, liquidity, riskState] = a.map(n);
      assets.push({
        index: i,
        name: NAMES[i] ?? `asset ${i}`,
        weight,
        weightPct: weight / (WEIGHT_SCALE / 100),
        basePrice: basePrice / PPI_SCALE,
        currentPrice: currentPrice / PPI_SCALE,
        changePct: basePrice ? (currentPrice / basePrice - 1) * 100 : 0,
        volatility,
        liquidity,
        riskState,
      });
      await sleep(SPACING_MS);
    }

    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Cache-Control", "s-maxage=60, stale-while-revalidate=300");
    res.status(200).json({
      ok: true,
      partial,
      network: "testnet",
      core: ACTIVE,
      isCurrentDeployment: ACTIVE === CORE,
      ppi: ppi == null ? null : n(ppi) / PPI_SCALE,
      supply: n(supply),
      reserve: n(reserve),
      assetCount,
      assetsReturned: assets.length,
      lastOracleUpdate: n(lastOracleUpdate),
      riskFund: n(riskFund),
      signerThreshold: n(threshold),
      fees: { burn: n(feesBurn), reserve: n(feesReserve), staking: n(feesStaking) },
      assets,
    });
  } catch (e) {
    res.status(200).json({ ok: false, partial: true, error: String(e?.message ?? e) });
  }
}
