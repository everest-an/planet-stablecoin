// Telegram webhook — the PPI in a chat. Works in any group or DM the bot is added to.
// Commands: /index, /asset <symbol|0-13>, /risk, /perp, /help. Read-only, answers from the public API.
const BASE = process.env.PPI_BASE || "https://ppppp.space";

function esc(s) {
  return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

async function api(path) {
  const r = await fetch(BASE + path, { headers: { "cache-control": "no-cache" } });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message || "api error");
  return j;
}

const RISK = ["normal", "caution", "frozen"];

async function reply(chatId, text, token) {
  await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, parse_mode: "HTML", disable_web_page_preview: true }),
  });
}

async function indexText() {
  const j = await api("/api/v1/ppi");
  const ppi = Number(j.ppi ?? 0).toFixed(6);
  const age = j.oracleAgeSeconds ?? 0;
  const level = age > 6 * 3600 ? 2 : age > 30 * 60 ? 1 : 0;
  const assets = (j.assets || []).slice().sort((a, b) => Math.abs(b.changePct ?? 0) - Math.abs(a.changePct ?? 0)).slice(0, 4);
  const movers = assets.map((a) => `${esc(a.symbol)} ${(a.changePct >= 0 ? "+" : "") + Number(a.changePct ?? 0).toFixed(2)}%`).join(" · ");
  return (
    `<b>PPI ${ppi}</b> (1.0 = inception)\n` +
    `data: <b>${RISK[level]}</b> · oracle ${Math.round(age / 60)}m ago\n` +
    `movers: ${movers}\n` +
    `14 assets · Arbitrum One\n` +
    `<a href="${BASE}/ppi">index</a> · <a href="${BASE}/history">history</a> · <a href="${BASE}/methodology">method</a>`
  );
}

async function assetText(q) {
  const j = await api("/api/v1/ppi");
  const u = String(q || "").toUpperCase();
  const a = /^\d+$/.test(u)
    ? (j.assets || []).find((x) => Number(x.index) === Number(u))
    : (j.assets || []).find((x) => String(x.symbol ?? "").toUpperCase() === u);
  if (!a) return `Unknown asset "${esc(q)}". Try /asset CL=F or /asset XAU.`;
  return (
    `<b>${esc(a.name)} (${esc(a.symbol)})</b>\n` +
    `weight ${(Number(a.weightPct) || 0).toFixed(1)}% · price ${(Number(a.currentPrice) / 1e6).toFixed(4)}\n` +
    `change ${(a.changePct >= 0 ? "+" : "") + Number(a.changePct ?? 0).toFixed(2)}% · state <b>${RISK[Number(a.riskState)] ?? a.riskState}</b>`
  );
}

async function riskText() {
  const j = await api("/api/v1/ppi");
  const age = j.oracleAgeSeconds ?? 0;
  const states = (j.assets || []).map((a) => Number(a.riskState ?? 0));
  let level = 0;
  if (age > 6 * 3600 || states.some((v) => v >= 2)) level = 2;
  else if (age > 30 * 60 || states.some((v) => v === 1)) level = 1;
  const meaning =
    level === 2 ? "frozen — do not open new risk; settlement uses the last known price"
    : level === 1 ? "caution — usable, raise margin / halve leverage"
    : "fresh — normal settlement";
  return `<b>data quality: ${RISK[level]}</b>\n${meaning}\nlast update ${Math.round(age / 60)}m ago · ${(j.assets || []).length} assets`;
}

async function perpText() {
  const j = await api("/api/v1/perp");
  const pool = Number(j.pool?.assets ?? 0);
  return (
    `<b>PPI perp</b> · price ${Number(j.market?.price ?? 0).toFixed(2)}\n` +
    `pool $${pool.toLocaleString()} · OI $${Math.abs(Number(j.pool?.netExposure ?? 0)).toLocaleString()}\n` +
    `risk ${esc(j.market?.riskLabel)} · max ${j.market?.maxLeverage}x · maint ${j.market?.maintenancePct}%\n` +
    (pool === 0 ? `pool empty — no position can open until an LP deposits\n` : "") +
    `<a href="${BASE}/perps">trade</a> · <a href="${BASE}/lp">provide liquidity</a>`
  );
}

export default async function handler(req, res) {
  const token = process.env.TG_BOT_TOKEN;
  if (req.method !== "POST") return res.status(200).json({ ok: true, bot: "planet-ppi" });
  if (!token) return res.status(200).json({ ok: false, error: "no token" });

  let update = req.body;
  if (typeof update === "string") { try { update = JSON.parse(update); } catch { return res.status(200).json({ ok: true }); } }
  const msg = update?.message || update?.edited_message || update?.channel_post;
  if (!msg?.text || !msg?.chat?.id) return res.status(200).json({ ok: true });

  const chatId = msg.chat.id;
  const parts = String(msg.text).trim().split(/\s+/);
  const cmd = parts[0].toLowerCase().replace(/@.*$/, "");
  const arg = parts[1] || "";

  let out;
  try {
    if (cmd === "/index" || cmd === "/ppi") out = await indexText();
    else if (cmd === "/asset") out = await assetText(arg);
    else if (cmd === "/risk") out = await riskText();
    else if (cmd === "/perp") out = await perpText();
    else out =
      `<b>Planet PPI</b> — a 14-commodity index on Arbitrum One.\n\n` +
      `/index — live value, movers, data quality\n` +
      `/asset &lt;symbol&gt; — one commodity (e.g. /asset CL=F)\n` +
      `/risk — is the data fresh enough to settle?\n` +
      `/perp — the perpetual market on the index\n\n` +
      `<a href="${BASE}/ppi">site</a> · <a href="${BASE}/history">history</a>`;
  } catch (e) {
    out = `temporarily unavailable: ${esc(e.message)}`;
  }

  try { await reply(chatId, out, token); } catch { /* ignore */ }
  return res.status(200).json({ ok: true });
}
