// Planet public read API — v1 (white paper appendix III: `/get_ppi`, `/reserves`).
//
// GET /api/v1/status -> JSON snapshot of the on-chain basket + PPI + reserve/supply/fees.
//
// Conventions (mirroring common public-API practice):
//   - URL-path versioning (`/api/v1/...`); additive changes stay in v1.
//   - One error envelope everywhere: { error: { code, message, request_id, details? } }.
//     A non-2xx status ALWAYS carries this envelope; a 2xx NEVER does.
//   - Cache-Control + ETag so clients can revalidate (304 Not Modified).
//   - 503 + Retry-After when the upstream RPC is unavailable (transient).
//
// Serverless (Vercel Node runtime), no dependencies: it calls the public TON testnet
// `runGetMethod` RPC directly and decodes the returned stack (ints + tuples).

const CORE = process.env.PLANET_CORE || "kQAwzh3O-52-QBtB8JFFTjtNaKFhw-uJMkd-zdnoHoGibzcU";
const CORE_FALLBACK = "kQBUZM0RwN4SXnQDO1q9WzmG2aaiOSD6ybkpaG9LSQ1Aj3Jf";
const ENDPOINT = process.env.TON_ENDPOINT || "https://testnet.toncenter.com/api/v2/runGetMethod";
const API_KEY = process.env.TON_API_KEY || "";
const PPI_SCALE = 1e6;
const WEIGHT_SCALE = 1e6;
const CONCURRENCY = 3;
const BUDGET_MS = 50000;
const TRIES = 5;
const BACKOFF_MS = 350;

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

let ACTIVE = CORE;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A short, dependency-free hash for the ETag.
function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = (h * 0x01000193) >>> 0;
  }
  return h.toString(16);
}

function decode(entry) {
  if (!entry) return null;
  const [type, value] = entry;
  // toncenter returns negative values as "-0x...", which BigInt() rejects — decode explicitly.
  if (type === "num") {
    const s = String(value);
    const neg = s[0] === "-";
    const v = BigInt("0x" + (neg ? s.slice(1) : s).replace(/^0x/i, ""));
    return (neg ? -v : v).toString();
  }
  if (type === "tuple") return value.map(decode);
  return null;
}

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

async function readStatus() {
  let partial = false;
  const started = Date.now();
  const deadline = started + BUDGET_MS;

  ACTIVE = CORE;
  let assetCount = n(await one("assetCount"));
  if (assetCount === 0) {
    ACTIVE = CORE_FALLBACK;
    assetCount = n(await one("assetCount"));
  }

  const ppi = await one("ppi");
  const lastOracleUpdate = await one("lastOracleUpdate");
  if (ppi == null || lastOracleUpdate == null) {
    return { unreachable: true };
  }

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

  const results = new Map();
  const queue = Array.from({ length: assetCount }, (_, i) => i);
  const worker = async () => {
    for (;;) {
      if (Date.now() > deadline) return;
      const i = queue.shift();
      if (i === undefined) return;
      const a = await tryCall("assetAt", [["num", "0x" + i.toString(16)]], deadline);
      if (a == null || a.length < 6) {
        queue.push(i);
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

  return {
    data: {
      network: "testnet",
      core: ACTIVE,
      isCurrentDeployment: ACTIVE === CORE,
      readMs: Date.now() - started,
      partial,
      ppi: n(ppi) / PPI_SCALE,
      supply: n(supply),
      reserve: n(reserve),
      assetCount,
      assetsReturned: assets.length,
      lastOracleUpdate: n(lastOracleUpdate),
      riskFund: n(riskFund),
      signerThreshold: n(threshold),
      fees: { burn: n(feesBurn), reserve: n(feesReserve), staking: n(feesStaking) },
      assets,
      links: {
        dashboard: "https://ppppp.space/dashboard",
        openapi: "https://ppppp.space/openapi.json",
      },
    },
  };
}

export default async function handler(req, res) {
  const requestId = "req_" + Math.random().toString(36).slice(2, 10);
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
  res.setHeader("X-Request-Id", requestId);
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.setHeader("Allow", "GET, HEAD, OPTIONS");
    return res.status(405).json({
      error: { code: "method_not_allowed", message: "Only GET/HEAD/OPTIONS are supported.", request_id: requestId },
    });
  }

  let out;
  try {
    out = await readStatus();
  } catch (e) {
    res.setHeader("Retry-After", "30");
    return res.status(503).json({
      error: { code: "upstream_error", message: "Could not read the chain right now.", request_id: requestId },
    });
  }
  if (out.unreachable) {
    res.setHeader("Retry-After", "30");
    return res.status(503).json({
      error: {
        code: "chain_unavailable",
        message: "PlanetCore did not respond to get-methods (public RPC rate-limited or unavailable). Retry shortly.",
        request_id: requestId,
      },
    });
  }

  const body = JSON.stringify(out.data);
  const etag = `W/"${fnv1a(body)}"`;
  // The public RPC is slow (~1 req/s without a key), so the cold read takes ~20s. The cache
  // window is deliberately wide and a scheduled warmer (see .github/workflows/cache-warmer.yml,
  // which runs from a CI IP that is not rate-limited) keeps the edge copy hot — users then
  // always hit the fast cached response. Set TON_API_KEY to make even a cold read fast.
  res.setHeader("Cache-Control", "public, s-maxage=900, stale-while-revalidate=1800");
  res.setHeader("ETag", etag);
  res.setHeader("Vary", "Accept-Encoding");
  if (req.headers["if-none-match"] === etag) return res.status(304).end();
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  return res.status(200).send(body);
}
