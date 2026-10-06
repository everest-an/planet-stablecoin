// Public read API for PlanetCore — white paper appendix III (`/get_ppi`, `/reserves`).
// GET /api/status  ->  JSON snapshot of the on-chain basket + PPI + reserve/supply/fees.
//
// Serverless (Vercel Node runtime), no dependencies: it calls the public TON testnet
// `runGetMethod` RPC directly and decodes the returned stack (ints + tuples).
//
// SPEED: an earlier version fetched ~23 get-methods SEQUENTIALLY and blew past Vercel's 30s
// function limit (HTTP 504, so the dashboard showed nothing). It now runs the scalars in
// parallel and the per-asset reads through a small worker pool, inside a hard time budget —
// returning a partial (still 200) result rather than timing out.

const CORE = process.env.PLANET_CORE || "kQAwzh3O-52-QBtB8JFFTjtNaKFhw-uJMkd-zdnoHoGibzcU";
// Previous deployment, used as a fallback while the current core is being (re)configured.
const CORE_FALLBACK = "kQBUZM0RwN4SXnQDO1q9WzmG2aaiOSD6ybkpaG9LSQ1Aj3Jf";
const ENDPOINT = process.env.TON_ENDPOINT || "https://testnet.toncenter.com/api/v2/runGetMethod";
const API_KEY = process.env.TON_API_KEY || ""; // optional: raises the public RPC rate limit
const PPI_SCALE = 1e6;
const WEIGHT_SCALE = 1e6;

const CONCURRENCY = 3; // parallel get-methods (the public RPC rate-limits big bursts)
const BUDGET_MS = 50000; // public RPC ~1 req/s; give the basket time to fully land (fn limit 60s)
const TRIES = 5;
const BACKOFF_MS = 350;

// Display names, index-aligned with the on-chain basket (see relayer/assets.example.json).
// The chain stores weights/prices only, so names live here for the dashboard/consumers.
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

// One get-method call with retries. Returns the FULL decoded stack (structs are flattened)
// or null on failure. Never throws, so callers can collect partial results.
async function tryCall(method, stack = [], deadline = Infinity) {
  for (let a = 0; a < TRIES; a++) {
    if (Date.now() > deadline) return null;
    try {
      const res = await fetch(ENDPOINT, {
        method: "POST",
        headers: { "content-type": "application/json", ...(API_KEY ? { "X-API-Key": API_KEY } : {}) },
        body: JSON.stringify({ address: ACTIVE, method, stack }),
      });
      if (res.status === 429) {
        await sleep(BACKOFF_MS * (a + 1));
        continue;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const j = await res.json();
      if (j.error) throw new Error(j.error.message);
      if (j?.result?.exit_code !== 0) throw new Error(`exit ${j?.result?.exit_code}`);
      return (j?.result?.stack ?? []).map(decode);
    } catch {
      if (a === TRIES - 1) return null;
      await sleep(BACKOFF_MS * (a + 1));
    }
  }
  return null;
}

const one = async (method) => {
  const arr = await tryCall(method);
  return arr && arr.length ? arr[0] : null;
};
const n = (v) => (v == null ? 0 : Number(v));

export default async function handler(_req, res) {
  let partial = false;
  const started = Date.now();
  const deadline = started + BUDGET_MS;
  try {
    ACTIVE = CORE;
    let assetCount = n(await one("assetCount"));
    if (assetCount === 0) {
      ACTIVE = CORE_FALLBACK; // current core not configured yet -> serve the previous one
      assetCount = n(await one("assetCount"));
    }

    // Headline values FIRST, sequentially, so `ppi` is never missing even under rate limiting.
    const ppi = await one("ppi");
    const lastOracleUpdate = await one("lastOracleUpdate");

    // The remaining scalars in parallel (a burst the RPC only mildly rate-limits).
    const [supply, reserve, riskFund, threshold, feesBurn, feesReserve, feesStaking] = await Promise.all([
      one("supply"),
      one("reserve"),
      one("riskFund"),
      one("threshold"),
      one("feesBurn"),
      one("feesReserve"),
      one("feesStaking"),
    ]);
    for (const v of [supply, reserve]) if (v == null) partial = true;

    // Per-asset reads through a small worker pool (toncenter v2 stack format: ["num","0x.."];
    // a struct return is FLATTENED onto the stack — 6 ints for CoreAsset). A call that fails
    // (transient 429) is REQUEUED and retried until the budget runs out, so rate limiting
    // costs latency, not rows.
    const results = new Map();
    const queue = Array.from({ length: assetCount }, (_, i) => i);
    const worker = async () => {
      for (;;) {
        if (Date.now() > deadline) return;
        const i = queue.shift();
        if (i === undefined) return;
        const a = await tryCall("assetAt", [["num", "0x" + i.toString(16)]], deadline);
        if (a == null || a.length < 6) {
          queue.push(i); // requeue: retry later within the budget instead of dropping the row
          await sleep(300);
          continue;
        }
        results.set(i, a);
      }
    };
    await Promise.all(Array.from({ length: Math.min(CONCURRENCY, Math.max(1, assetCount)) }, worker));

    const assets = [...results.entries()]
      .sort((x, y) => x[0] - y[0])
      .map(([i, a]) => {
        const [weight, basePrice, currentPrice, volatility, liquidity, riskState] = a.map(n);
        return {
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
        };
      });
    if (assets.length < assetCount) partial = true;

    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Cache-Control", "s-maxage=120, stale-while-revalidate=600");
    res.status(200).json({
      ok: true,
      partial,
      network: "testnet",
      core: ACTIVE,
      isCurrentDeployment: ACTIVE === CORE,
      ms: Date.now() - started,
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
    res.status(200).json({ ok: false, partial: true, ms: Date.now() - started, error: String(e?.message ?? e) });
  }
}
