// Live PPI ticker for the landing site. Reads PlanetCore.currentPpi() over the public Arbitrum
// Sepolia RPC, straight from the browser — no API in front of it, so the number on the landing page
// is the chain's own number. Degrades to "—" if the RPC is unavailable.
//
// EVM note: getters are addressed by 4-byte selector, not by name. The selector is a compile-time
// constant (keccak256("currentPpi()")[0:4]) so no hashing library is needed at runtime — same reason
      // web/api/_evm.js hardcodes them. The previous build called runGetMethod("ppi"); there is no
// ppi() on the EVM core, and asking for it reverts.
const CORE = "0xCEcad784A6cEB1aF12c69639a5027D935651F946";
const RPC = "https://sepolia-rollup.arbitrum.io/rpc";
const SEL = {
  assetCount: "0xeafe7a74",
  currentPpi: "0x3070b56b",
};

const el = document.getElementById("ppi");
const note = document.getElementById("ppi-note");

// A single uint256 return: one 32-byte word. A function that does not exist returns "0x" (empty),
// which must be treated as failure rather than as zero.
async function call(data) {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: CORE, data }, "latest"] }),
  });
  if (!res.ok) throw new Error("HTTP " + res.status);
  const j = await res.json();
  if (j.error) throw new Error(j.error.message || "rpc error");
  const hex = j.result;
  if (!hex || hex === "0x") throw new Error("no data");
  return Number(BigInt(hex));
}

async function tick() {
  try {
    const [count, ppi] = await Promise.all([call(SEL.assetCount), call(SEL.currentPpi)]);
    if (!count) {
      el.textContent = "—";
      note.textContent = "basket not configured";
      return;
    }
    el.textContent = (ppi / 1e6).toFixed(6);
    note.textContent = "live · PlanetCore · Arbitrum Sepolia";
  } catch (e) {
    el.textContent = "—";
    note.textContent = "RPC unavailable — open the app";
  }
}

tick();
setInterval(tick, 60_000);
