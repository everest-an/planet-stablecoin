// Minimal Ethereum read layer for the Planet public API — deliberately dependency-free.
//
// WHY NO VIEM HERE: the deployment used to be TON, where every read was a `runGetMethod` with a
// method NAME, so no encoding was needed. EVM getters are addressed by a 4-byte selector, and the
// first instinct is "we need keccak at runtime, so we need a library". We do not: the selectors are
// COMPILE-TIME CONSTANTS. Hardcoding them (each one verified against the live contract) keeps this
// project's oldest invariant — the API has no dependencies and no build step — and removes the
// Vercel framework-detection risk that adding package.json to a static site would introduce.
//
// Every response here is a tuple of 32-byte STATIC words (no dynamic types, no strings, no arrays),
// so decoding is word slicing. If a future getter returns a string/bytes/dynamic array this helper
// must grow an offset-following decoder — do not silently extend `words()` and assume it works.
//
// ENV: EVM_CORE / EVM_RPC (NOT PLANET_CORE — that variable still holds a TON address in the Vercel
// project, and inheriting it would point every read at a base64 TON address and fail silently).

// Arbitrum Sepolia = 421614. The RPC is public and needs no key.
export const RPC = process.env.EVM_RPC || "https://sepolia-rollup.arbitrum.io/rpc";
export const CORE = process.env.EVM_CORE || "0xB3FC376FF511B379fdC88A01406888Bd63F76C9A";
export const CHAIN = { name: "arbitrum-sepolia", id: 421614 };
export const SCALE = 1e6;
// PlanetCore.MAX_ORACLE_AGE == 6 hours, and mint()/redeem() revert StaleOracle past it. This is a
// CONTRACT constant, not a policy knob: if the contract changes, this must change with it.
export const MAX_ORACLE_AGE = 21600;

// keccak256("<signature>")[0:4], verified with eth_call against the live deployment.
export const SEL = {
  assetCount: "0xeafe7a74",
  currentPpi: "0x3070b56b",
  lastOracleUpdate: "0xb609d0e6",
  oldestActiveUpdate: "0xb6ef7e0f",
  oracle: "0x7dc0d1d0",
  baseLocked: "0x7b082610",
  weightSum: "0x8195c3f8",
  totalSupply: "0x18160ddd",
  totalReserve: "0x4c68df67",
  riskFund: "0x7cf89030",
  feesToBurn: "0xabb62e92",
  feesToReserve: "0x37530832",
  feesToStaking: "0xf8134597",
  relayer: "0x8406c079",
  owner: "0x8da5cb5b",
  token: "0xfc0c546a",
  paused: "0x5c975abb",
  // assets(uint256) — the auto-generated getter for `Asset[] public assets`
  assets: "0xcf35bdd0",
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// One JSON-RPC batch = one round trip for the whole basket. The public endpoint is rate-limited and
// a cold function used to spend ~20s on sequential TON get-methods; this is ~1-2s.
export async function ethCallMany(items, { tries = 4, timeoutMs = 12000 } = {}) {
  if (!items.length) return [];
  const body = items.map((it, i) => ({
    jsonrpc: "2.0",
    id: i,
    method: "eth_call",
    params: [it, "latest"],
  }));

  for (let attempt = 0; attempt < tries; attempt++) {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      const res = await fetch(RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: controller.signal,
      }).finally(() => clearTimeout(timer));

      if (res.status === 429 || res.status >= 500) {
        await sleep(300 * (attempt + 1));
        continue;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const json = await res.json();
      const arr = Array.isArray(json) ? json : [json];
      const out = new Array(items.length).fill(null);
      for (const r of arr) {
        if (r && typeof r.id === "number" && !r.error) out[r.id] = r.result;
      }
      return out;
    } catch {
      if (attempt === tries - 1) return new Array(items.length).fill(null);
      await sleep(300 * (attempt + 1));
    }
  }
  return new Array(items.length).fill(null);
}

export async function ethCall(data, opts) {
  const [res] = await ethCallMany([{ to: CORE, data }], opts);
  return res;
}

// Split a return blob into 32-byte words. `0x` (empty return) decodes to [] — which is what a
// call to a function that does not exist returns, so callers must treat missing words as "no data"
// rather than as zero.
export function words(hex) {
  if (!hex || hex === "0x") return [];
  const body = hex.slice(2);
  const out = [];
  for (let i = 0; i + 64 <= body.length; i += 64) out.push(BigInt("0x" + body.slice(i, i + 64)));
  return out;
}

export const toNum = (v) => (v == null ? null : Number(v));
export const toAddress = (v) => (v == null ? null : "0x" + v.toString(16).padStart(40, "0"));

// Read a set of scalar getters in one batch. Returns an object of raw BigInts (null = failed).
export async function readScalars(selectors, opts) {
  const results = await ethCallMany(
    selectors.map((s) => ({ to: CORE, data: SEL[s] })),
    opts,
  );
  const out = {};
  selectors.forEach((name, i) => {
    const w = words(results[i]);
    out[name] = w.length ? w[0] : null;
  });
  return out;
}

function decodeAsset(hex, index) {
  const w = words(hex);
  if (w.length < 6) return null;
  return {
    index,
    weight: toNum(w[0]),
    basePriceRaw: toNum(w[1]),
    currentPriceRaw: toNum(w[2]),
    volatility: toNum(w[3]),
    liquidity: toNum(w[4]),
    riskState: toNum(w[5]),
    // Appended to the struct in the per-asset-staleness upgrade; older cores do not return it.
    lastUpdate: w.length > 6 ? toNum(w[6]) : null,
  };
}

// Scalars AND the basket in ONE round trip: assetCount is only known after reading it, so the
// alternative is two sequential batches. On a public RPC the round trips dominate (~330ms each) and
// each request costs rate-limit budget, so the common case (assetCount <= maxAssets) is folded into a
// single batch here. Slots past the real assetCount simply revert (out of bounds) and decode to null.
export async function readScalarsAndAssets(selectors, maxAssets, opts) {
  const items = selectors.map((s) => ({ to: CORE, data: SEL[s] }));
  for (let i = 0; i < maxAssets; i++) {
    items.push({ to: CORE, data: SEL.assets + i.toString(16).padStart(64, "0") });
  }
  const results = await ethCallMany(items, opts);
  const scalars = {};
  selectors.forEach((name, i) => {
    const w = words(results[i]);
    scalars[name] = w.length ? w[0] : null;
  });
  const assets = [];
  for (let i = 0; i < maxAssets; i++) assets.push(decodeAsset(results[selectors.length + i], i));
  return { scalars, assets };
}

// Read assets(i) for i in [0, n). Each row is
// (weight, basePrice, currentPrice, volatility, liquidity, riskState).
export async function readAssets(n, opts) {
  const results = await ethCallMany(
    Array.from({ length: n }, (_, i) => ({
      to: CORE,
      data: SEL.assets + i.toString(16).padStart(64, "0"),
    })),
    opts,
  );
  return results.map((hex, i) => decodeAsset(hex, i));
}

// FNV-1a — a short ETag, same function the TON version used.
export function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = (h * 0x01000193) >>> 0;
  }
  return h.toString(16);
}

// Shared HTTP envelope so /status and /oracle stay identical in their error contract.
//
// `volatile` lists top-level keys that MUST NOT feed the ETag. Without this, a body containing a
// per-request timing field (readMs) or a clock field (checkedAt/ageSeconds) would hash differently on
// every call, so If-None-Match could never match and 304 would never fire — the TON edition of these
// endpoints had exactly that defect: it advertised ETag/304 and, in practice, always sent a full body.
export function sendJson(req, res, requestId, data, { maxAge, volatile = [] }) {
  const basis = volatile.length
    ? JSON.stringify(data, (k, v) => (volatile.includes(k) && typeof k === "string" ? undefined : v))
    : JSON.stringify(data);
  const body = JSON.stringify(data);
  const etag = `W/"${fnv1a(basis)}"`;
  res.setHeader("Cache-Control", `public, s-maxage=${maxAge}, stale-while-revalidate=${maxAge * 2}`);
  res.setHeader("ETag", etag);
  res.setHeader("Vary", "Accept-Encoding");
  if (req.headers["if-none-match"] === etag) return res.status(304).end();
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  return res.status(200).send(body);
}

export function sendUpstreamError(res, requestId, code, message) {
  res.setHeader("Retry-After", "30");
  return res.status(503).json({ error: { code, message, request_id: requestId } });
}

export function newRequestId() {
  return "req_" + Math.random().toString(36).slice(2, 10);
}
