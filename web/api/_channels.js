// Multi-channel price sources for the Planet oracle.
//
// WHY THIS EXISTS: one feed is an availability risk and two feeds give you a median that cannot tell
// which one is wrong. This module gathers up to FOUR independent channels per asset and publishes a
// price together with a confirmation count, so "we read multiple channels" is something the pushed
// data and the API can demonstrate rather than assert.
//
// THE RULE (deliberately not "median of everything"):
//   The primary channel sets the price. Every other channel is a CONFIRMATION if it lands within TOL
//   of that price. With at least one confirmation the reading is NORMAL; with none it is CAUTION and
//   the price stays the primary's. We do not average a disagreeing feed: a 1% gap between two channels
//   is usually two different contract expiries, and averaging those blends two different assets — the
//   exact bug that put natgas at 3.276 when the front month was 3.05.
//
//   Yahoo is primary because it is the only channel that covers all 14 instruments under the SAME
//   instrument definition. Its futures quotes are ~15 minutes delayed, which is irrelevant for an index
//   rebuilt hourly, whereas a mismatched expiry permanently biases the basket. The real-time venues
//   (Sina, Tencent, Eastmoney) are used as independent confirmations, where a stale-at-the-margin quote
//   costs nothing but disagreement is caught.
//
//   Natgas is configured single-source on purpose: Sina/Tencent quote ~3.50 and Eastmoney ~2.63 while
//   the front month (Yahoo NG=F) is 3.05. Those are later expiries, not confirmations.
//
// CLI: `node sources.mjs` prints the whole matrix (channels, spread, confirmations, state).

const UA = { "User-Agent": "Mozilla/5.0" };
const TOL = 0.005; // 0.5% — same-instrument channels agree far more tightly than this

// Verbatim readings taken on 2026-10-25 are noted where a symbol was rejected, because a wrong
// symbol silently poisons the index and the next person deserves to see why it is missing.
const ASSETS = [
  { i: 0,  sym: "CL=F",   name: "WTI Crude",    primary: "yahoo", srcs: [["sina", "hf_CL"], ["tencent", "hf_CL"], ["eastmoney", "102.CL00Y"]] },
  { i: 1,  sym: "BZ=F",   name: "Brent Crude",  primary: "yahoo", srcs: [["sina", "hf_OIL"], ["tencent", "hf_OIL"]] },
  { i: 2,  sym: "NG=F",   name: "Natural Gas",  primary: "yahoo", srcs: [] },
  { i: 3,  sym: "GC=F",   name: "Gold",         primary: "yahoo", srcs: [["sina", "hf_GC"], ["tencent", "hf_GC"], ["eastmoney", "101.GC00Y"]] },
  { i: 4,  sym: "SI=F",   name: "Silver",       primary: "yahoo", srcs: [["sina", "hf_SI"], ["tencent", "hf_SI"], ["eastmoney", "101.SI00Y"]] },
  { i: 5,  sym: "HG=F",   name: "Copper",       primary: "yahoo", srcs: [["sina", "hf_HG", 0.01], ["tencent", "hf_HG", 0.01], ["eastmoney", "101.HG00Y"]] },
  { i: 6,  sym: "ZW=F",   name: "Wheat",        primary: "yahoo", srcs: [["tencent", "hf_W"]] },
  { i: 7,  sym: "ZC=F",   name: "Corn",         primary: "yahoo", srcs: [["tencent", "hf_C"]] },
  { i: 8,  sym: "ZS=F",   name: "Soybean",      primary: "yahoo", srcs: [["tencent", "hf_S"]] },
  { i: 9,  sym: "KC=F",   name: "Coffee",       primary: "yahoo", srcs: [] },
  { i: 10, sym: "WOOD",   name: "Lumber (ETF)", primary: "yahoo", srcs: [["tencent", "usWOOD"]] },
  { i: 11, sym: "LIT",    name: "Lithium (ETF)", primary: "yahoo", srcs: [["tencent", "usLIT"]] },
  { i: 12, sym: "PHO",    name: "Water (ETF)",  primary: "yahoo", srcs: [["tencent", "usPHO"]] },
  { i: 13, sym: "KRBN",   name: "Carbon (ETF)", primary: "yahoo", srcs: [["tencent", "usKRBN"]] },
];

// ---------------------------------------------------------------- adapters
async function yahoo(symbol) {
  const r = await fetch(`https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?range=1d&interval=1d`, { headers: UA });
  if (!r.ok) throw new Error("HTTP " + r.status);
  const p = (await r.json())?.chart?.result?.[0]?.meta?.regularMarketPrice;
  if (!Number.isFinite(p) || p <= 0) throw new Error("bad price");
  return p;
}

async function sina(code) {
  const r = await fetch(`https://hq.sinajs.cn/list=${encodeURIComponent(code)}`, {
    headers: { ...UA, Referer: "https://finance.sina.com.cn" },
  });
  if (!r.ok) throw new Error("HTTP " + r.status);
  const m = (await r.text()).match(/"([^"]*)"/);
  if (!m?.[1]) throw new Error("no data");
  const p = Number(m[1].split(",")[0]);
  if (!Number.isFinite(p) || p <= 0) throw new Error("bad price");
  return p;
}

async function tencent(code) {
  const r = await fetch(`https://qt.gtimg.cn/q=${encodeURIComponent(code)}`, { headers: UA });
  if (!r.ok) throw new Error("HTTP " + r.status);
  const m = (await r.text()).match(/="([^"]*)"/);
  if (!m?.[1]) throw new Error("no data");
  const body = m[1];
  // hf_* (foreign futures) return one comma-separated record with the price first; us* (US equities)
  // return a tilde-separated record with the price at index 3.
  const p = body.includes("~") ? Number(body.split("~")[3]) : Number(body.split(",")[0]);
  if (!Number.isFinite(p) || p <= 0) throw new Error("bad price '" + p + "'");
  return p;
}

async function eastmoney(secid) {
  const r = await fetch(`https://push2.eastmoney.com/api/qt/stock/get?secid=${secid}&fields=f43,f58,f59`, {
    headers: { ...UA, Referer: "https://quote.eastmoney.com/" },
  });
  if (!r.ok) throw new Error("HTTP " + r.status);
  const d = (await r.json())?.data;
  if (!d || d.f43 == null) throw new Error("no data");
  // f59 is the number of decimals the venue quotes in (gold 1, copper 4, ...). Ignoring it is how a
  // 4010 quote becomes "40100" and silently inflates the basket.
  const p = d.f43 / 10 ** Number(d.f59 ?? 0);
  if (!Number.isFinite(p) || p <= 0) throw new Error("bad price");
  return p;
}

const CHANNELS = { yahoo, sina, tencent, eastmoney };

async function observe(asset) {
  const jobs = [["yahoo", asset.sym, 1], ...asset.srcs];
  const out = await Promise.all(
    jobs.map(async ([ch, code, scale]) => {
      try {
        const raw = await CHANNELS[ch](code);
        return { channel: ch, code, price: raw * (scale ?? 1) };
      } catch (e) {
        return { channel: ch, code, error: String(e.message).slice(0, 40) };
      }
    }),
  );
  return out;
}

export function aggregate(asset, observations) {
  const primaryObs = observations.find((o) => o.channel === asset.primary && Number.isFinite(o.price));
  if (!primaryObs) return { ok: false, reason: "primary_channel_unavailable", observations };

  const price = primaryObs.price;
  const confirming = [];
  const rejected = [];
  for (const o of observations) {
    if (o === primaryObs) continue;
    if (!Number.isFinite(o.price)) continue;
    const dev = Math.abs(o.price / price - 1);
    if (dev <= TOL) confirming.push({ ...o, dev });
    else rejected.push({ ...o, dev });
  }

  const spread = confirming.length ? Math.max(...confirming.map((c) => c.dev)) : 0;
  return {
    ok: true,
    price,
    confirmations: confirming.length,
    channelsOk: observations.filter((o) => Number.isFinite(o.price)).length,
    riskState: confirming.length >= 1 ? 0 : 1,
    spread,
    confirming,
    rejected,
    observations,
  };
}

export async function readAsset(asset) {
  return aggregate(asset, await observe(asset));
}

export { ASSETS, TOL };
