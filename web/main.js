// Live PPI ticker for the landing site. Reads PlanetCore's `ppi()` over the public TON
// testnet RPC. Falls back to the previous deployment while a freshly redeployed core is
// still being configured, and degrades gracefully (shows "—") if the RPC is unavailable.
const CORE = "kQA57Fa64OT_MXIqrJD0DGokcNaw36neL-aIWjWJHcIp2QfX"; // current
const CORE_FALLBACK = "kQAzxh1PoqeXWVYQrABxZky8_bAXddjoGTPbqN4tv8Zsfuul"; // previous (populated)
const ENDPOINT = "https://testnet.toncenter.com/api/v2/runGetMethod";

const el = document.getElementById("ppi");
const note = document.getElementById("ppi-note");

async function runGet(address, method) {
  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ address, method, stack: [] }),
  });
  if (!res.ok) throw new Error("HTTP " + res.status);
  const j = await res.json();
  // exit_code != 0 means the get-method failed (e.g. account not initialised) — treat as
  // a failure so the caller falls back instead of trusting a garbage stack.
  if (j?.result?.exit_code !== 0) throw new Error("exit " + j?.result?.exit_code);
  const hex = j?.result?.stack?.[0]?.[1];
  if (!hex) throw new Error("no stack");
  return Number(BigInt(hex));
}

// Prefer the current core, but only once it actually has a configured basket.
async function activeCore() {
  try {
    if ((await runGet(CORE, "assetCount")) > 0) return { address: CORE, live: true };
  } catch (_) {
    /* fall through to the previous deployment */
  }
  return { address: CORE_FALLBACK, live: false };
}

async function tick() {
  try {
    const { address, live } = await activeCore();
    const v = (await runGet(address, "ppi")) / 1e6;
    el.textContent = v.toFixed(6);
    note.textContent = "live · PlanetCore · TON testnet" + (live ? "" : " (previous deployment)");
  } catch (e) {
    el.textContent = "—";
    note.textContent = "RPC unavailable (rate-limited) — open the app";
  }
}

tick();
setInterval(tick, 60_000);
