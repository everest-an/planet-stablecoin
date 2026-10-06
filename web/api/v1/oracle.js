// Planet public API — v1: oracle health.
//
// GET /api/v1/oracle[?full=1]
//
// Why this exists: an index is only as good as its oracle. This endpoint answers "is the
// price feed alive and sane right now?" in a form a monitor or an auditor can poll.
//
// Design: the DEFAULT response is deliberately cheap (a handful of get-methods, a couple of
// seconds) so it can be polled frequently — a health check that costs 20s is useless. The
// per-commodity scan (weights sum, frozen/caution lists, signer keys) only runs with
// `?full=1`. It never reports "healthy" when it could not actually read the chain: an
// unreachable core is a 503 with the standard error envelope.
//
// Conventions match /api/v1/status: versioned path, one error envelope, ETag/304,
// Retry-After on 503. Cache is shorter here (30s) because freshness is the whole point.

const CORE = process.env.PLANET_CORE || "kQAwzh3O-52-QBtB8JFFTjtNaKFhw-uJMkd-zdnoHoGibzcU";
const CORE_FALLBACK = "kQBUZM0RwN4SXnQDO1q9WzmG2aaiOSD6ybkpaG9LSQ1Aj3Jf";
const ENDPOINT = process.env.TON_ENDPOINT || "https://testnet.toncenter.com/api/v2/runGetMethod";
const API_KEY = process.env.TON_API_KEY || "";
const PPI_SCALE = 1e6;
const WEIGHT_SCALE = 1e6;
const MAX_ORACLE_AGE = 21600; // 6h — mirrors the on-chain MAX_ORACLE_AGE (mint staleness guard)
const MAX_SIGNER_KEYS = 8;
const BUDGET_MS = 45000;
const TRIES = 6;
const BACKOFF_MS = 350;

let ACTIVE = CORE;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = (h * 0x01000193) >>> 0;
  }
  return h.toString(16);
}

async function runGet(method, stack = [], deadline = Infinity) {
  for (let a = 0; a < TRIES; a++) {
    if (Date.now() > deadline) return null;
    try {
      const res = await fetch(ENDPOINT, {
        method: "POST",
        headers: { "content-type": "application/json", ...(API_KEY ? { "X-API-Key": API_KEY } : {}) },
        body: JSON.stringify({ address: ACTIVE, method, stack }),
      });
      if (res.status === 429 || res.status >= 500) {
        await sleep(BACKOFF_MS * (a + 1));
        continue;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const j = await res.json();
      if (j?.result?.exit_code !== 0) throw new Error(`exit ${j?.result?.exit_code}`);
      return (j?.result?.stack ?? []).map((e) => (e[0] === "num" ? Number(BigInt(e[1])) : null));
    } catch {
      if (a === TRIES - 1) return null;
      await sleep(BACKOFF_MS * (a + 1));
    }
  }
  return null;
}
const one = async (m, d) => {
  const arr = await runGet(m, [], d);
  return arr && arr.length ? arr[0] : null;
};

async function readOracle(full) {
  const deadline = Date.now() + BUDGET_MS;

  let assetCount = await one("assetCount", deadline);
  if (assetCount === 0) {
    ACTIVE = CORE_FALLBACK;
    assetCount = await one("assetCount", deadline);
  }
  const lastOracleUpdate = await one("lastOracleUpdate", deadline);
  if (assetCount == null || lastOracleUpdate == null) return { unreachable: true };

  const [ppi, signerCount, threshold, baseLockedN] = await Promise.all([
    one("ppi", deadline),
    one("signerCount", deadline),
    one("threshold", deadline),
    one("baseLocked", deadline),
  ]);

  const signers = signerCount == null ? null : signerCount;
  const thr = threshold == null ? null : threshold;
  const baseLocked = baseLockedN === 1 || baseLockedN === true;

  const now = Math.floor(Date.now() / 1000);
  const ageSeconds = Math.max(0, now - lastOracleUpdate);

  const reasons = [];
  const warnings = [];

  if (lastOracleUpdate === 0) reasons.push("oracle_never_pushed");
  else if (ageSeconds > MAX_ORACLE_AGE) reasons.push(`oracle_price_stale:${ageSeconds}s`);
  if (!signers) reasons.push("no_oracle_signer_configured");
  if (signers && thr != null && (thr < 1 || thr > signers))
    reasons.push(`threshold_unsatisfiable:${thr}of${signers}`);
  if (!baseLocked) warnings.push("base_prices_not_locked");
  if (!assetCount) warnings.push("empty_basket");

  const data = {
    network: "testnet",
    core: ACTIVE,
    isCurrentDeployment: ACTIVE === CORE,
    checkedAt: now,
    lastOracleUpdate,
    ageSeconds,
    maxAgeSeconds: MAX_ORACLE_AGE,
    fresh: lastOracleUpdate > 0 && ageSeconds <= MAX_ORACLE_AGE,
    ppi: ppi == null ? null : ppi / PPI_SCALE,
    signers: { count: signers, threshold: thr, configured: !!signers && !!thr },
    baseLocked,
    assetCount,
    healthy: reasons.length === 0,
    reasons,
    warnings,
  };

  if (full) {
    const keys = [];
    if (signers) {
      for (let i = 0; i < Math.min(signers, MAX_SIGNER_KEYS); i++) {
        const st = await runGet("signerAt", [["num", "0x" + i.toString(16)]], deadline);
        // signerAt returns a uint256, which the RPC hands back as a 256-bit num.
        keys.push(st && st.length ? "0x" + BigInt.asUintN(256, BigInt(st[0])).toString(16).padStart(64, "0") : null);
        await sleep(120);
      }
    }
    data.signerKeys = keys;

    const frozen = [];
    const caution = [];
    let weightSum = 0;
    let read = 0;
    for (let i = 0; i < assetCount; i++) {
      if (Date.now() > deadline) break;
      const a = await runGet("assetAt", [["num", "0x" + i.toString(16)]], deadline);
      if (!a || a.length < 6) continue;
      read++;
      weightSum += a[0];
      if (a[5] === 2) frozen.push(i);
      else if (a[5] === 1) caution.push(i);
      await sleep(120);
    }
    const complete = read === assetCount;
    data.basket = {
      weightsSum: weightSum,
      expectedSum: WEIGHT_SCALE,
      complete,
      weightsValid: complete && weightSum === WEIGHT_SCALE,
      frozen,
      caution,
    };
    if (!complete) warnings.push(`basket_scan_incomplete:${read}of${assetCount}`);
    if (complete && weightSum !== WEIGHT_SCALE) reasons.push(`weights_do_not_sum:${weightSum}`);
    if (frozen.length) warnings.push(`frozen_commodities:${frozen.length}`);
    data.healthy = reasons.length === 0;
    data.reasons = reasons;
    data.warnings = warnings;
  }

  return { data };
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

  const url = new URL(req.url, "https://ppppp.space");
  const full = url.searchParams.get("full") === "1";

  let out;
  try {
    out = await readOracle(full);
  } catch {
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
  // Short cache: a health reading that is a minute old is still a health reading, but no longer.
  res.setHeader("Cache-Control", "public, s-maxage=30, stale-while-revalidate=120");
  res.setHeader("ETag", etag);
  if (req.headers["if-none-match"] === etag) return res.status(304).end();
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  return res.status(200).send(body);
}
