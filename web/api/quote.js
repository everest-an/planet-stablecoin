// GET /api/quote?from=ARBITRUM&to=ETH&amount=100&symbol=PAXG
//
// Live cross-chain quote from Rango. The API key lives ONLY here, on the server — the browser never
// sees it. That is the one hard rule for this endpoint: an aggregator key in a client bundle is a
// free pass to someone else's rate limits and, depending on the provider, their affiliate revenue.
//
// Scope note: this returns a QUOTE, not a transaction. Executing a cross-chain route means confirming
// it and then sending one transaction per step (approve, swap, bridge) from the user's wallet, and
// that flow already exists and works in the Protocol Bank project (`components/cross-chain-swap.tsx`
// + `lib/rango.ts`). Re-implementing it here without a funded wallet to verify against would be
// shipping an unverified money path, so this endpoint deliberately stops at the quote.
//
// Env: RANGO_API_KEY (required). Optional: RANGO_BASE (default https://api.rango.exchange).

const BASE = process.env.RANGO_BASE || "https://api.rango.exchange";
const KEY = process.env.RANGO_API_KEY || "";

// Revenue, without custody and without a fee contract: Rango pays registered affiliates out of the
// route fee they already charge. We never touch the user's money and never add a hidden markup.
// Both values are required for it to do anything - an unregistered ref is silently ignored by Rango,
// so this must be set up on their side before it earns a cent.
const AFFILIATE_REF = process.env.RANGO_AFFILIATE_REF || "";
const AFFILIATE_WALLET = process.env.RANGO_AFFILIATE_WALLET || "";

// Verified canonical addresses only. A same-symbol token at another address is a different asset.
const ASSETS = {
  PAXG: { blockchain: "ETH", symbol: "PAXG", address: "0x45804880De22913dAFE09f4980848ECE6EcbAf78" },
  XAUT: { blockchain: "ETH", symbol: "XAUT", address: "0x68749665FF8D2d112Fa859AA293F07A622782F38" },
  KAG: { blockchain: "ETH", symbol: "KAG", address: "0x56Ba8B58B7d1f6d384A1C4dD553F39ebc8741B8e" },
};

// Where the money comes from if the caller does not say. USDC is the default because it is what a
// buyer of metal is holding.
const SOURCES = {
  ARBITRUM: { blockchain: "ARBITRUM", symbol: "USDC", address: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831" },
  ETH: { blockchain: "ETH", symbol: "USDC", address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" },
  BASE: { blockchain: "BASE", symbol: "USDC", address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" },
  POLYGON: { blockchain: "POLYGON", symbol: "USDC", address: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359" },
  OPTIMISM: { blockchain: "OPTIMISM", symbol: "USDC", address: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85" },
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "GET" && req.method !== "HEAD") {
    return res.status(405).json({ error: { code: "method_not_allowed", message: "GET only." } });
  }

  if (!KEY) {
    // Fail loudly and usefully: a missing key is a deployment mistake, not an outage.
    return res.status(503).json({
      error: {
        code: "not_configured",
        message: "RANGO_API_KEY is not set on this deployment. Quotes are unavailable until it is.",
      },
    });
  }

  const url = new URL(req.url, "https://ppppp.space");
  const toSymbol = (url.searchParams.get("symbol") || "PAXG").toUpperCase();
  const fromChain = (url.searchParams.get("from") || "ARBITRUM").toUpperCase();
  const amount = String(url.searchParams.get("amount") || "100");
  const fromAddress = url.searchParams.get("address") || "";

  const to = ASSETS[toSymbol];
  const from = SOURCES[fromChain];
  if (!to) return res.status(400).json({ error: { code: "bad_symbol", message: `unknown symbol ${toSymbol}` } });
  if (!from) return res.status(400).json({ error: { code: "bad_chain", message: `unsupported source chain ${fromChain}` } });
  if (!/^\d+(\.\d+)?$/.test(amount) || Number(amount) <= 0) {
    return res.status(400).json({ error: { code: "bad_amount", message: "amount must be a positive number" } });
  }
  if (fromAddress && !/^0x[0-9a-fA-F]{40}$/.test(fromAddress)) {
    return res.status(400).json({ error: { code: "bad_address", message: "address must be 20-byte hex" } });
  }

  let lastErr = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await fetch(`${BASE}/routing/bests?apiKey=${encodeURIComponent(KEY)}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          from,
          to,
          amount,
          fromAddress: fromAddress || undefined,
          slippage: "1",
          // One EVM address works on every EVM chain, so the same wallet is offered for each.
          ...(AFFILIATE_REF
            ? { affiliateRef: AFFILIATE_REF }
            : {}),
          ...(AFFILIATE_WALLET
            ? {
                affiliateWallets: Object.fromEntries(
                  Object.keys(SOURCES).map((chain) => [chain, AFFILIATE_WALLET]),
                ),
              }
            : {}),
        }),
      });
      if (r.status === 429 || r.status >= 500) { await sleep(400 * (attempt + 1)); continue; }
      const j = await r.json();
      if (!r.ok || j.error) {
        lastErr = j.error || `HTTP ${r.status}`;
        // An upstream 4xx that is not a rate limit will not improve by retrying.
        if (r.status < 500 && r.status !== 429) break;
        continue;
      }

      const routes = j.results || [];
      if (!routes.length) {
        return res.status(503).json({
          error: { code: "no_route", message: "Rango returned no route for this pair right now." },
        });
      }
      const best = routes[0];
      const swappers = (best.swaps || []).map((s) => s.swapperId);
      const out = Number(best.outputAmount);

      res.setHeader("Cache-Control", "public, s-maxage=20, stale-while-revalidate=40");
      res.setHeader("Content-Type", "application/json; charset=utf-8");
      return res.status(200).send(
        JSON.stringify({
          rev: "quote-1",
          from: { chain: from.blockchain, symbol: from.symbol, amount },
          to: { chain: to.blockchain, symbol: to.symbol },
          best: {
            outputAmount: Number.isFinite(out) ? out : best.outputAmount,
            timeSeconds:
              best.estimatedTimeInSeconds ??
              (Array.isArray(best.swaps) && best.swaps.length
                ? best.swaps.reduce((a, x) => a + (Number(x.estimatedTimeInSeconds) || 0), 0)
                : null),
            feeUsd: best.totalFeeUsd ?? null,
            priceImpact: best.priceImpact ?? null,
            route: swappers.join(" → "),
            steps: Array.isArray(best.swaps) && best.swaps.length ? best.swaps.length : 1,
          },
          alternatives: Math.max(0, routes.length - 1),
          affiliate: AFFILIATE_REF && AFFILIATE_WALLET ? AFFILIATE_REF : null,
          // Needed to confirm later; not a transaction, and not usable without the wallet.
          requestId: best.requestId ?? null,
          routeId: j.routeId ?? null,
        }),
      );
    } catch (e) {
      lastErr = e.message;
      if (attempt === 2) break;
      await sleep(400 * (attempt + 1));
    }
  }

  return res.status(503).json({
    error: { code: "upstream_error", message: "Rango did not answer. Retry shortly.", details: String(lastErr).slice(0, 120) },
  });
}
