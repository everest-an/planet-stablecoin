// Daily index post to the Telegram group (Gavis). Reads the public API, formats a short post.
const BASE = process.env.PPI_BASE || "https://ppppp.space";
const TOKEN = process.env.TG_BOT_TOKEN;
const CHAT = process.env.TG_GROUP_CHAT_ID;

const j = await (await fetch(BASE + "/api/v1/ppi", { headers: { "cache-control": "no-cache" } })).json();
if (j.error) { console.error("api error", JSON.stringify(j).slice(0, 200)); process.exit(1); }

const ppi = Number(j.ppi).toFixed(6);
const age = j.oracleAgeSeconds ?? 0;
const states = (j.assets || []).map((a) => Number(a.riskState ?? 0));
let level = 0;
if (age > 6 * 3600 || states.some((v) => v >= 2)) level = 2;
else if (age > 30 * 60 || states.some((v) => v === 1)) level = 1;
const risk = ["normal", "caution", "frozen"][level];

const movers = (j.assets || [])
  .slice()
  .sort((a, b) => Math.abs(b.changePct ?? 0) - Math.abs(a.changePct ?? 0))
  .slice(0, 3)
  .map((a) => `${a.symbol} ${a.changePct >= 0 ? "+" : ""}${Number(a.changePct).toFixed(2)}%`)
  .join(" · ");

const flagged = (j.assets || []).filter((a) => Number(a.riskState) > 0);
const flagLine = flagged.length
  ? `\nflags: ${flagged.map((a) => `${a.symbol} ${["", "caution", "frozen"][Number(a.riskState)]}`).join(", ")}`
  : "";

const text =
  `<b>PPI ${ppi}</b> · data <b>${risk}</b> (${Math.round(age / 60)}m)\n` +
  `${movers}${flagLine}\n` +
  `<a href="${BASE}/ppi">index</a> · <a href="${BASE}/history">history</a>`;

const r = await fetch(`https://api.telegram.org/bot${TOKEN}/sendMessage`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ chat_id: Number(CHAT), text, parse_mode: "HTML", disable_web_page_preview: true }),
});
const res = await r.json();
console.log("sent:", res.ok, res.ok ? "msg " + res.result.message_id : res.description);
if (!res.ok) process.exit(1);
