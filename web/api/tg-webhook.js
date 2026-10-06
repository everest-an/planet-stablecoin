// Telegram support bot webhook — answers the FAQ automatically, in chat, with no LLM.
//
// Design notes (why it is built this way):
//  - Webhook (not polling): Telegram pushes updates here; nothing runs when idle.
//  - Authenticated: Telegram echoes the secret we set in `setWebhook` in the
//    `X-Telegram-Bot-Api-Secret-Token` header — we reject anything else, so the endpoint
//    cannot be spammed by third parties even though the URL is public.
//  - No model, no free-form generation: replies are matched against the SAME FAQ page the
//    website serves (single source of truth), so the bot can never invent a financial claim.
//    That matters: a hallucinated "you can redeem for dollars" is a legal problem, not a bug.
//  - It NEVER asks for a seed phrase / private key and says so explicitly.
//
// Env: TG_BOT_TOKEN, TG_WEBHOOK_SECRET, FAQ_URL (default https://ppppp.space/faq)

const TOKEN = process.env.TG_BOT_TOKEN || "";
const SECRET = process.env.TG_WEBHOOK_SECRET || "";
const FAQ_URL = process.env.FAQ_URL || "https://ppppp.space/faq";
const API = "https://api.telegram.org";

let FAQ_CACHE = null; // { at, items: [{q, a}] }
const CACHE_MS = 10 * 60 * 1000;

function stripTags(s) {
  return String(s)
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

// Parse the FAQ page into {q, a} pairs: each question is an <h2>, its answer the first <p>
// in the same <article>.
function parseFaq(html) {
  const items = [];
  const articleRe = /<article[^>]*>([\s\S]*?)<\/article>/gi;
  let m;
  while ((m = articleRe.exec(html)) !== null) {
    const body = m[1];
    const h = /<h2[^>]*>([\s\S]*?)<\/h2>/i.exec(body);
    const p = /<p[^>]*>([\s\S]*?)<\/p>/i.exec(body);
    if (h && p) items.push({ q: stripTags(h[1]), a: stripTags(p[1]) });
  }
  return items;
}

async function faq() {
  const now = Date.now();
  if (FAQ_CACHE && now - FAQ_CACHE.at < CACHE_MS) return FAQ_CACHE.items;
  try {
    const res = await fetch(FAQ_URL, { headers: { "user-agent": "planet-bot" } });
    const html = await res.text();
    const items = parseFaq(html);
    if (items.length) FAQ_CACHE = { at: now, items };
    return items;
  } catch {
    return FAQ_CACHE ? FAQ_CACHE.items : [];
  }
}

// Cheap keyword scoring: overlap of significant words between the query and each question.
const STOP = new Set(["the", "a", "an", "is", "are", "do", "does", "i", "you", "we", "how", "what", "why", "can", "to", "of", "in", "on", "it", "and", "or", "for", "my", "me", "this", "that", "with"]);
function words(s) {
  return String(s)
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((w) => w.length > 2 && !STOP.has(w));
}
function bestMatch(text, items) {
  const qw = new Set(words(text));
  if (!qw.size) return null;
  let best = null;
  let bestScore = 0;
  for (const it of items) {
    const iw = words(it.q);
    let score = 0;
    for (const w of iw) if (qw.has(w)) score += 1;
    const frac = score / Math.max(1, iw.length);
    if (score > bestScore && frac >= 0.34) {
      bestScore = score;
      best = it;
    }
  }
  return best;
}

async function tg(method, payload) {
  const res = await fetch(`${API}/bot${TOKEN}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  return res.json().catch(() => ({}));
}

const FOOTER =
  "\n\n—\nPlanet is a TON testnet proof of concept: not a stablecoin, no reserve, no market " +
  "price, not investment advice. Full FAQ: https://ppppp.space/faq\n" +
  "I will never ask for your seed phrase or private key.";

const MENU = {
  inline_keyboard: [
    [
      { text: "Live dashboard", web_app: { url: "https://ppppp.space/dashboard" } },
      { text: "Open app", web_app: { url: "https://app.ppppp.space" } },
    ],
    [{ text: "FAQ", url: "https://ppppp.space/faq" }],
  ],
};

async function reply(chatId, text, extra = {}) {
  return tg("sendMessage", {
    chat_id: chatId,
    text,
    disable_web_page_preview: true,
    ...extra,
  });
}

async function liveStatusLine() {
  try {
    const res = await fetch("https://ppppp.space/api/v1/status", { headers: { "user-agent": "planet-bot" } });
    const j = await res.json();
    if (!j || typeof j.ppi !== "number") return null;
    const age = j.lastOracleUpdate ? Math.max(0, Math.floor(Date.now() / 1000) - j.lastOracleUpdate) : null;
    const ageTxt = age == null ? "unknown" : age < 3600 ? `${Math.floor(age / 60)}m ago` : `${Math.floor(age / 3600)}h ago`;
    return `PPI ${j.ppi.toFixed(6)} · ${j.assetCount} commodities · oracle ${ageTxt}`;
  } catch {
    return null;
  }
}

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ ok: false, error: "POST only" });
  // Authenticate Telegram's delivery (set via setWebhook's secret_token).
  if (SECRET && req.headers["x-telegram-bot-api-secret-token"] !== SECRET) {
    return res.status(401).json({ ok: false, error: "bad secret" });
  }
  if (!TOKEN) return res.status(500).json({ ok: false, error: "TG_BOT_TOKEN not set" });

  const update = req.body || {};
  const msg = update.message || update.edited_message;
  const chatId = msg?.chat?.id;
  const text = (msg?.text || "").trim();
  if (!chatId || !text) return res.status(200).json({ ok: true }); // nothing to answer

  const cmd = text.split(/\s+/)[0].toLowerCase().replace(/@.*$/, "");

  if (cmd === "/start" || cmd === "/help") {
    await reply(
      chatId,
      "Hi — I'm the Planet support bot. Ask me anything about the commodity index, the " +
        "basket, minting, fees, governance or risks, and I'll answer from the FAQ.\n" +
        "Commands: /status (live index) · /faq (full list) · /app (open the Mini App)" +
        FOOTER,
      { reply_markup: MENU }
    );
    return res.status(200).json({ ok: true });
  }

  if (cmd === "/app" || cmd === "/planet") {
    await reply(chatId, "Open the Mini App: https://app.ppppp.space — you sign in your own wallet." + FOOTER, {
      reply_markup: MENU,
    });
    return res.status(200).json({ ok: true });
  }

  if (cmd === "/faq") {
    const items = await faq();
    const list = items.map((it, i) => `${i + 1}. ${it.q}`).join("\n");
    await reply(chatId, `Frequently asked questions:\n${list}\n\nFull answers: https://ppppp.space/faq` + FOOTER, {
      reply_markup: MENU,
    });
    return res.status(200).json({ ok: true });
  }

  if (cmd === "/status") {
    const line = await liveStatusLine();
    await reply(chatId, (line ? line : "I couldn't read the chain just now — try again in a minute.") + "\n\nhttps://ppppp.space/dashboard" + FOOTER, {
      reply_markup: MENU,
    });
    return res.status(200).json({ ok: true });
  }

  // Free text -> best FAQ match.
  const items = await faq();
  const hit = bestMatch(text, items);
  if (hit) {
    await reply(chatId, `${hit.q}\n\n${hit.a}` + FOOTER, { reply_markup: MENU });
  } else {
    await reply(
      chatId,
      "I don't have an answer for that yet. Try /faq for the full list, or ask a different way " +
        "(for example \"is it a stablecoin?\", \"what fees?\", \"which network?\")." +
        FOOTER,
      { reply_markup: MENU }
    );
  }
  return res.status(200).json({ ok: true });
}
