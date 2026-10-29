const U = "https://ppppp.space";
const W = "0xBf0D7119F553eB5f85C9806f0849f9c86a9B768C";
const step = (n, s) => console.log(`${s ? (s.pass ? "PASS" : "FAIL") : "..."}  ${n}${s?.note ? "  (" + s.note + ")" : ""}`);

// 1. deployed page carries the resume code
{
  const h = await (await fetch(U + "/metals", { headers: { "cache-control": "no-cache" } })).text();
  const pass = h.includes("planet.pendingRoute") && h.includes("createStep") && h.includes("executeSwap(false)");
  step("metals.html deployed with resume", { pass, note: pass ? "pendingRoute + createStep + fixed handler" : "MISSING" });
}

// 2. quote
let requestId = null, quote = null;
{
  const r = await fetch(`${U}/api/quote?symbol=PAXG&from=ARBITRUM&amount=5`, { headers: { "cache-control": "no-cache" } });
  const j = await r.json();
  requestId = j.requestId ?? null;
  globalThis.__sig = j.sig ?? null;
  quote = j.best ?? null;
  step("quote PAXG <- ARBITRUM 5 USDC", { pass: r.ok && quote?.outputAmount > 0 && !!requestId, note: `${quote?.outputAmount ?? "-"} PAXG, ${quote?.timeSeconds ?? "-"}s, req ${requestId ? requestId.slice(0, 8) : "none"}` });
}

// 3. confirm
if (requestId) {
  const r = await fetch(`${U}/api/execute`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ action: "confirm", requestId, sig: globalThis.__sig, selectedWallets: { ARBITRUM: W, ETH: W }, destination: W }),
  });
  const j = await r.json();
  step("confirm route", { pass: r.ok && !j.error, note: `chains ${(j.blockchains ?? []).join(",") || "-"} | shortfalls ${j.shortfalls?.length ?? 0}` });

  // 4. create step 1 -> must be an approval we could sign
  const c = await fetch(`${U}/api/execute`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ action: "create", requestId, sig: globalThis.__sig, step: 1 }),
  });
  const k = await c.json();
  const tx = k.transaction;
  step("create step 1", { pass: c.ok && !!tx?.to, note: tx ? `${tx.isApprovalTx ? "approve" : "swap"} on ${tx.chain} -> ${tx.to.slice(0, 10)}…` : JSON.stringify(k).slice(0, 90) });
}

// 5. oracle health
{
  const j = await (await fetch(`${U}/api/v1/oracle`, { headers: { "cache-control": "no-cache" } })).json();
  step("oracle health", { pass: j.healthy === true || j.ok === true, note: `lastUpdate ${j.lastUpdate ?? "?"}, stale ${j.stale?.length ?? "?"}, reasons ${(j.reasons ?? []).length}` });
}

// 6. index / status
{
  const j = await (await fetch(`${U}/api/v1/status`, { headers: { "cache-control": "no-cache" } })).json();
  const ppi = j.ppi ?? j.index ?? j.status?.ppi;
  step("index status", { pass: !!ppi, note: `ppi ${ppi ?? "?"}, supply ${j.totalSupply ?? j.supply ?? "?"}` });
}

// 7. per-channel audit trail
{
  const j = await (await fetch(`${U}/api/v1/sources`, { headers: { "cache-control": "no-cache" } })).json();
  const assets = j.assets ?? j.data ?? [];
  const chans = Array.isArray(assets) ? assets.reduce((n, a) => n + (a.channels?.length ?? 0), 0) : 0;
  step("sources audit trail", { pass: chans > 0, note: `${Array.isArray(assets) ? assets.length : "?"} assets, ${chans} channel reads` });
}
