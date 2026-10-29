// POST /api/execute — the two write-ish steps of a Rango swap, proxied so the key stays server-side.
import { createHmac, timingSafeEqual } from "crypto";
//
//   { "action": "confirm", "requestId": "...", "selectedWallets": { "ARBITRUM": "0x…", "ETH": "0x…" }, "destination": "0x…" }
//   { "action": "create",  "requestId": "...", "step": 1 }
//
// WHY A PROXY: the API key must never reach the browser. Everything here is a thin, validated
// passthrough — the server decides nothing about the route, it only holds the credential.
//
// WHAT THIS DOES NOT DO: it does not sign. Every transaction this returns is sent by the user's own
// wallet, from the page. The sequence is:
//
//   quote (/api/quote) -> confirm -> create -> sign -> [if isApprovalTx: create again, sign again]
//                                              -> next step
//
// `isApprovalTx` is the field that matters: an approval is a separate round trip, not a property you
// can skip. Getting that wrong is why the first implementation silently did nothing.

const BASE = process.env.RANGO_BASE || "https://api.rango.exchange";
const KEY = process.env.RANGO_API_KEY || "";
const MAX_STEPS = 10;

const isAddress = (v) => typeof v === "string" && /^0x[0-9a-fA-F]{40}$/.test(v);

// This endpoint is uncacheable (POST) and every call spends our Rango quota, so it is the one
// place a free DoS can hurt. Sliding-window per-IP cap: warm serverless instances share nothing,
// so this blunts blunt spam rather than replacing a real WAF, which is the correct long-term fix.
const LIMIT_WINDOW_MS = 60 * 1000;
const LIMIT_MAX_CALLS = 30;
const hits = new Map();

function rateLimited(ip) {
  const now = Date.now();
  const arr = (hits.get(ip) || []).filter((t) => now - t < LIMIT_WINDOW_MS);
  arr.push(now);
  hits.set(ip, arr);
  if (hits.size > 5000) {
    const cutoff = now - LIMIT_WINDOW_MS;
    for (const [k, v] of hits) if (v.every((t) => t < cutoff)) hits.delete(k);
  }
  return arr.length > LIMIT_MAX_CALLS;
}

export default async function handler(req, res) {
  const origin = req.headers.origin || "";
  if (origin === "https://ppppp.space" || origin === "http://localhost:3000" || !origin) {
    res.setHeader("Access-Control-Allow-Origin", origin || "*");
  }
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "content-type");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "POST") {
    return res.status(405).json({ error: { code: "method_not_allowed", message: "POST only." } });
  }
  if (!KEY) {
    return res.status(503).json({
      error: { code: "not_configured", message: "RANGO_API_KEY is not set on this deployment." },
    });
  }
  if (rateLimited(req.headers["x-forwarded-for"] || req.socket?.remoteAddress || "unknown")) {
    return res.status(429).json({
      error: { code: "rate_limited", message: "too many requests — slow down." },
    });
  }

  let body;
  try {
    body = typeof req.body === "string" ? JSON.parse(req.body) : req.body;
  } catch {
    return res.status(400).json({ error: { code: "bad_json", message: "body must be JSON." } });
  }
  if (!body || typeof body !== "object") {
    return res.status(400).json({ error: { code: "bad_json", message: "body must be an object." } });
  }

  const { action, requestId, sig } = body;
  if (typeof requestId !== "string" || requestId.length < 8 || requestId.length > 80) {
    return res.status(400).json({ error: { code: "bad_request_id", message: "requestId is required." } });
  }

  // Every requestId forwarded here must be one OUR /api/quote issued. Anything else is rejected
  // before it can spend a single Rango call — this closes the quota-burn DoS regardless of how
  // many IPs or instances an attacker spreads across.
  if (typeof sig !== "string" || sig.length !== 32 || !/^[0-9a-f]{32}$/.test(sig)) {
    return res.status(401).json({ error: { code: "invalid_signature", message: "sig is required (from /api/quote)." } });
  }
  const expected = createHmac("sha256", KEY).update(requestId).digest("hex").slice(0, 32);
  if (!timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) {
    return res.status(401).json({ error: { code: "invalid_signature", message: "sig does not match this requestId." } });
  }

  let endpoint;
  let payload;

  if (action === "confirm") {
    const wallets = body.selectedWallets;
    if (!wallets || typeof wallets !== "object" || Array.isArray(wallets)) {
      // This is the exact mistake the old client made; say so instead of forwarding a request that
      // Rango will reject with an opaque 1201.
      return res.status(400).json({
        error: {
          code: "bad_wallets",
          message: "selectedWallets is required: { BLOCKCHAIN: address } for EVERY chain in the route.",
        },
      });
    }
    const entries = Object.entries(wallets);
    if (!entries.length || entries.length > 6) {
      return res.status(400).json({ error: { code: "bad_wallets", message: "1-6 wallets expected." } });
    }
    for (const [chain, addr] of entries) {
      if (!/^[A-Z0-9_]{2,16}$/.test(chain) || !isAddress(addr)) {
        return res.status(400).json({ error: { code: "bad_wallets", message: `invalid entry ${chain}` } });
      }
    }
    if (body.destination != null && !isAddress(body.destination)) {
      return res.status(400).json({ error: { code: "bad_destination", message: "destination must be an address." } });
    }
    endpoint = "/routing/confirm";
    payload = { requestId, selectedWallets: wallets, ...(body.destination ? { destination: body.destination } : {}) };
  } else if (action === "create") {
    const step = Number(body.step);
    if (!Number.isInteger(step) || step < 1 || step > MAX_STEPS) {
      return res.status(400).json({ error: { code: "bad_step", message: `step must be 1..${MAX_STEPS}` } });
    }
    endpoint = "/tx/create";
    payload = {
      requestId,
      step,
      userSettings: { slippage: String(body.slippage ?? "1.0"), infiniteApprove: false },
      // balance/fee are checked in the browser; leaving them true makes Rango re-check against
      // balances it has not refreshed, which fails on routes the user can actually afford.
      validations: { balance: false, fee: false, approve: true },
    };
  } else {
    return res.status(400).json({ error: { code: "bad_action", message: "action must be confirm or create." } });
  }

  try {
    const r = await fetch(`${BASE}${endpoint}?apiKey=${encodeURIComponent(KEY)}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
    const j = await r.json().catch(() => ({}));

    if (j?.ok === false || j?.error) {
      const message = String(j.error || `HTTP ${r.status}`);

      // Rango answers "Request contain invalid step(s)!" when you ask for the step AFTER the last
      // one. That is COMPLETION, not failure: a single-step route answers exactly this way once its
      // swap has landed. Treating it as an error made a successful swap report as broken.
      if (action === "create" && /invalid step/i.test(message)) {
        return res.status(200).json({ ok: true, done: true, transaction: null, note: "last step reached" });
      }

      return res.status(502).json({
        error: {
          code: action === "confirm" ? "confirm_failed" : "create_failed",
          message: message.slice(0, 200),
          upstreamCode: j.errorCode ?? null,
        },
      });
    }

    if (action === "confirm") {
      const route = j.result ?? {};
      // The steps live at different depths depending on the API version; check the shapes we have
      // actually seen rather than assuming one.
      const steps =
        route?.route ??
        route?.result?.route ??
        route?.result?.result?.route ??
        [];
      const validation = route?.validationStatus ?? null;

      // The chains come from the validation block when the steps are not enumerated - that block is
      // always present and lists every blockchain the route touches.
      const fromSteps = steps.flatMap((x) => [x?.from?.blockchain, x?.to?.blockchain]).filter(Boolean);
      const fromValidation = Array.isArray(validation) ? validation.map((v) => v?.blockchain).filter(Boolean) : [];
      const blockchains = [...new Set([...fromSteps, ...fromValidation])];

      // A wallet that cannot cover the input is the most common failure and the most confusing one:
      // report it here rather than letting the first create() fail with an opaque upstream error.
      const shortfalls = [];
      for (const v of Array.isArray(validation) ? validation : []) {
        for (const w of v?.wallets ?? []) {
          for (const asset of w?.requiredAssets ?? []) {
            if (asset?.ok === false) {
              shortfalls.push({
                blockchain: v?.blockchain ?? null,
                symbol: asset?.asset?.symbol ?? null,
                reason: asset?.reason ?? null,
                required: asset?.requiredAmount?.amount ?? null,
                current: asset?.currentAmount?.amount ?? null,
                decimals: asset?.requiredAmount?.decimals ?? null,
              });
            }
          }
        }
      }

      return res.status(200).json({
        ok: true,
        steps: steps.length,
        blockchains,
        validation,
        shortfalls,
        missing: route?.missingBlockchains ?? null,
      });
    }

    // The transaction is returned at the top level of the response (result holds other fields).
    const tx = j?.transaction ?? j?.result?.transaction ?? null;
    if (!tx) {
      // ok:true with no transaction is Rango saying "this step is finished".
      return res.status(200).json({ ok: true, done: true, transaction: null });
    }
    return res.status(200).json({
      ok: true,
      done: false,
      transaction: {
        chain: tx.blockChain ?? null,
        to: tx.to ?? null,
        data: tx.data ?? "0x",
        value: tx.value ?? null,
        gasLimit: tx.gasLimit ?? null,
        isApprovalTx: !!tx.isApprovalTx,
      },
    });
  } catch (e) {
    return res.status(503).json({
      error: { code: "upstream_error", message: "Rango did not answer. Retry shortly.", details: String(e.message).slice(0, 120) },
    });
  }
}
