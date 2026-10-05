// Live PPI ticker for the landing site. Reads PlanetCore's `ppi()` over the public TON
// testnet RPC. Degrades gracefully (shows "—" + a note) if the RPC is unavailable.
const CORE = "kQAzxh1PoqeXWVYQrABxZky8_bAXddjoGTPbqN4tv8Zsfuul";
const ENDPOINT = "https://testnet.toncenter.com/api/v2/runGetMethod";

async function readPpi() {
  const body = JSON.stringify({ address: CORE, method: "ppi", stack: [] });
  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
  });
  if (!res.ok) throw new Error("HTTP " + res.status);
  const j = await res.json();
  const hex = j?.result?.stack?.[0]?.[1];
  if (!hex) throw new Error("no stack");
  return Number(BigInt(hex)) / 1e6;
}

const el = document.getElementById("ppi");
const note = document.getElementById("ppi-note");

async function tick() {
  try {
    const v = await readPpi();
    el.textContent = v.toFixed(6);
    note.textContent = "live · PlanetCore · TON testnet";
  } catch (e) {
    el.textContent = "—";
    note.textContent = "RPC unavailable (rate-limited) — open the app";
  }
}

tick();
setInterval(tick, 60_000);
