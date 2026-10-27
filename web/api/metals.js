// GET /api/metals?address=0x… — how much tokenised metal a wallet holds, in ounces.
//
// The MVP for "one place to hold on-chain metals". It is deliberately READ-ONLY: no custody, no
// signing, no token. The page shows what you hold; the buy button hands off to a DEX/aggregator the
// user already trusts. That keeps this endpoint outside every regulatory question the earlier designs
// ran into.
//
// WHY OUNCES: every one of these tokens has a fixed metal content (PAXG and XAUT are 1 fine troy
// ounce), so the ounce figure is exact from balances alone — no price feed involved. USD is shown
// as a convenience and is explicitly allowed to be null if the price source is unavailable; a
// missing price must never look like a zero holding.
//
// ONLY VERIFIED CONTRACTS. A token called "PAX Gold" with a different address is a scam token; the
// two below are the canonical deployments (Paxos and Tether), cross-checked against the issuers'
// own pages. Nothing unverified goes in this list, and bridged copies are excluded on purpose:
// Paxos states there is no official PAXG on Arbitrum, so a bridged representation carries bridge
// risk on top of issuer risk and does not belong in a "what do I own" view.

const ETH_RPC = process.env.ETH_RPC || "https://ethereum-rpc.publicnode.com";
const PRICE_URL = "https://api.coingecko.com/api/v3/simple/price";
const SCALE = 1e18;

// ozPerToken is a property of the instrument, not a price. PAXG/XAUT = 1 troy oz exactly.
const TOKENS = [
  {
    symbol: "PAXG",
    address: "0x45804880De22913dAFE09f4980848ECE6EcbAf78",
    ozPerToken: 1,
    metal: "gold",
    priceId: "pax-gold",
    issuer: "Paxos Trust Company, N.A. (US, OCC)",
    note: "Unavailable to EU residents under MiCA as of 2026-10.",
  },
  {
    symbol: "XAUT",
    address: "0x68749665FF8D2d112Fa859AA293F07A622782F38",
    ozPerToken: 1,
    metal: "gold",
    priceId: "tether-gold",
    issuer: "TG Commodities Limited (BVI), Swiss vaults",
    note: null,
  },
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function rpcBatch(calls, { tries = 3, timeoutMs = 9000 } = {}) {
  const body = calls.map((c, id) => ({ jsonrpc: "2.0", id, method: "eth_call", params: [c, "latest"] }));
  for (let a = 0; a < tries; a++) {
    try {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), timeoutMs);
      const res = await fetch(ETH_RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: ctrl.signal,
      }).finally(() => clearTimeout(t));
      if (res.status === 429 || res.status >= 500) { await sleep(300 * (a + 1)); continue; }
      if (!res.ok) throw new Error("HTTP " + res.status);
      const j = await res.json();
      const arr = Array.isArray(j) ? j : [j];
      const out = new Array(calls.length).fill(null);
      for (const r of arr) if (r && typeof r.id === "number" && !r.error) out[r.id] = r.result;
      return out;
    } catch {
      if (a === tries - 1) return new Array(calls.length).fill(null);
      await sleep(300 * (a + 1));
    }
  }
  return new Array(calls.length).fill(null);
}

async function prices() {
  try {
    const ids = [...new Set(TOKENS.map((t) => t.priceId))].join(",");
    const r = await fetch(`${PRICE_URL}?ids=${ids}&vs_currencies=usd`, { headers: { accept: "application/json" } });
    if (!r.ok) return null;
    return await r.json();
  } catch {
    return null;
  }
}

function sendJson(res, data, maxAge) {
  const body = JSON.stringify(data);
  res.setHeader("Cache-Control", `public, s-maxage=${maxAge}, stale-while-revalidate=${maxAge * 2}`);
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  return res.status(200).send(body);
}

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "GET" && req.method !== "HEAD") {
    return res.status(405).json({ error: { code: "method_not_allowed", message: "GET only." } });
  }

  const url = new URL(req.url, "https://ppppp.space");
  const raw = (url.searchParams.get("address") || "").trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) {
    return res.status(400).json({
      error: { code: "bad_address", message: "address must be a 20-byte hex address." },
    });
  }
  const address = raw.toLowerCase();

  // one batch: balanceOf for every token
  const calls = TOKENS.map((t) => ({ to: t.address, data: "0x70a08231" + address.slice(2).padStart(64, "0") }));
  const results = await rpcBatch(calls);
  const priceMap = await prices();

  const tokens = TOKENS.map((t, i) => {
    const hex = results[i];
    const balance = hex && hex !== "0x" ? Number(BigInt(hex)) / SCALE : null;
    const oz = balance == null ? null : balance * t.ozPerToken;
    const priceUsd = priceMap?.[t.priceId]?.usd ?? null;
    return {
      symbol: t.symbol,
      address: t.address,
      metal: t.metal,
      issuer: t.issuer,
      note: t.note,
      balance,
      oz,
      priceUsd,
      usd: oz != null && priceUsd != null ? oz * priceUsd : null,
    };
  });

  const readable = tokens.filter((t) => t.balance != null);
  if (readable.length === 0) {
    // Never report "you own nothing" when the truth is "we could not read". That distinction is the
    // whole difference between a dashboard and a liability.
    return res.status(503).json({
      error: { code: "chain_unavailable", message: "Could not read balances right now. Retry shortly." },
    });
  }

  const sum = (arr) => arr.reduce((a, b) => a + b, 0);
  const gold = readable.filter((t) => t.metal === "gold");
  const silver = readable.filter((t) => t.metal === "silver");
  const anyUsd = readable.some((t) => t.usd != null);

  return sendJson(
    res,
    {
      rev: "metals-1",
      address,
      chain: { id: 1, name: "ethereum" },
      tokens,
      totals: {
        goldOz: sum(gold.map((t) => t.oz ?? 0)),
        silverOz: sum(silver.map((t) => t.oz ?? 0)),
        usd: anyUsd ? sum(readable.map((t) => t.usd ?? 0)) : null,
      },
      priceSource: priceMap ? "coingecko" : "unavailable",
      notes: [
        "Ounces are exact: PAXG and XAUT each represent one fine troy ounce.",
        "USD is indicative and may be null if the price source is unavailable.",
        "Only canonical issuer deployments are read; bridged copies are excluded on purpose.",
      ],
    },
    60,
  );
}
