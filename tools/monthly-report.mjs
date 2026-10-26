// Monthly basket report generator (dependency-free).
//
// Run by .github/workflows/monthly-report.yml on a schedule (and by hand). It reads the live
// basket straight from PlanetCore, writes a dated snapshot + a rendered report, refreshes the
// /reports index, and adds the new URLs to the sitemap. The workflow commits the result, so
// Vercel publishes it — no manual step.
//
// Design: it REFUSES to publish a partial read (a report with missing commodities would be
// wrong, not just incomplete). Every month is immutable once written: if the file exists we
// leave it alone unless FORCE=1.

import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = join(HERE, "..", "web");
const REPORTS = join(WEB, "reports");

const CORES = [process.env.EVM_CORE || "0x5b7537e800c4190f9Ee22FDBC1355Fbc0142952E"];
const NAMES = [
  "WTI Crude", "Brent Crude", "Natural Gas", "Gold", "Silver", "Copper",
  "Wheat", "Corn", "Soybean", "Coffee", "Lumber (ETF)", "Lithium (ETF)",
  "Water (ETF)", "Carbon (ETF)",
];
const SECTORS = [
  "energy", "energy", "energy", "metals", "metals", "metals",
  "agriculture", "agriculture", "agriculture", "agriculture",
  "industrial", "industrial", "industrial", "industrial",
];
const RPC = process.env.EVM_RPC || "https://sepolia-rollup.arbitrum.io/rpc";
// Getters are addressed by 4-byte selector on EVM; these are constants, no hashing at runtime.
const SEL = {
  assetCount: "0xeafe7a74",
  currentPpi: "0x3070b56b",
  totalSupply: "0x18160ddd",
  totalReserve: "0x4c68df67",
  lastOracleUpdate: "0xb609d0e6",
  assets: "0xcf35bdd0",
};
const SCALE = 1e6;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let ACTIVE = CORES[0];

async function runGet(method, arg, tries = 8) {
  let data = SEL[method];
  if (!data) throw new Error(`runGet: no selector for ${method}`);
  if (method === "assets") data += Number(arg).toString(16).padStart(64, "0");
  for (let a = 0; a < tries; a++) {
    try {
      const res = await fetch(RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: ACTIVE, data }, "latest"] }),
      });
      if (res.status === 429 || res.status >= 500) {
        await sleep(600 * (a + 1));
        continue;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const j = await res.json();
      if (j.error) throw new Error(j.error.message);
      const hex = j.result;
      if (!hex || hex === "0x") throw new Error("no data");
      const body = hex.slice(2);
      const out = [];
      for (let i = 0; i + 64 <= body.length; i += 64) out.push(Number(BigInt("0x" + body.slice(i, i + 64))));
      return out;
    } catch (e) {
      if (a === tries - 1) throw e;
      await sleep(600 * (a + 1));
    }
  }
  throw new Error(`runGet ${method}: exhausted retries`);
}

async function readBasket() {
  for (const c of CORES) {
    ACTIVE = c;
    try {
      if ((await runGet("assetCount"))[0] > 0) break;
    } catch {
      /* try the next */
    }
  }
  const assetCount = (await runGet("assetCount"))[0];
  if (!assetCount) throw new Error("no configured core found");
  const ppi = (await runGet("currentPpi"))[0] / SCALE;
  const supply = (await runGet("totalSupply"))[0];
  const reserve = (await runGet("totalReserve"))[0];
  const lastOracleUpdate = (await runGet("lastOracleUpdate"))[0];

  const assets = [];
  for (let i = 0; i < assetCount; i++) {
    await sleep(150);
    const st = await runGet("assets", i);
    const [weight, basePrice, currentPrice, , , riskState] = st;
    assets.push({
      index: i,
      name: NAMES[i] ?? `asset ${i}`,
      sector: SECTORS[i] ?? "other",
      weightPpm: weight,
      weightPct: weight / (SCALE / 100),
      basePrice: basePrice / SCALE,
      currentPrice: currentPrice / SCALE,
      riskState,
      sinceLaunchPct: basePrice ? (currentPrice / basePrice - 1) * 100 : 0,
    });
  }
  if (assets.length !== assetCount) {
    throw new Error(`incomplete read: ${assets.length}/${assetCount} assets — refusing to publish`);
  }
  return { core: ACTIVE, ppi, supply, reserve, lastOracleUpdate, assets };
}

function prevSnapshots() {
  if (!existsSync(REPORTS)) return [];
  return readdirSync(REPORTS)
    .filter((f) => /^\d{4}-\d{2}\.json$/.test(f))
    .sort()
    .map((f) => {
      try {
        return JSON.parse(readFileSync(join(REPORTS, f), "utf8"));
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const money = (n, d = 2) => Number(n).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const pct = (n) => (n >= 0 ? "+" : "") + Number(n).toFixed(2) + "%";
const cls = (n) => (n > 0.005 ? "up" : n < -0.005 ? "down" : "");

const NAV = `<header class="topbar">
      <a class="wordmark" href="/">Planet</a>
      <nav class="nav">
        <a href="/">home</a>
        <a href="/dashboard">dashboard</a>
        <a href="/reports">reports</a>
        <a href="/docs">docs</a>
        <a href="/methodology">methodology</a>
        <a class="btn" href="https://app.ppppp.space">open app</a>
      </nav>
    </header>`;

const STYLE = `<style>
      .doc { max-width: 980px; margin: 0 auto; padding: 32px 20px 76px; }
      .doc h1 { font-family: "Space Grotesk", sans-serif; font-size: 28px; margin: 24px 0 6px; }
      .doc .sub { color: var(--muted, #8a8a8a); font-family: "DM Mono", monospace; font-size: 12px; margin-bottom: 20px; }
      .doc h2 { font-family: "Space Grotesk", sans-serif; font-size: 18px; margin: 30px 0 10px; }
      .doc p { line-height: 1.7; }
      .doc .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin: 18px 0 24px; }
      .doc .card { border: 1px solid var(--muted, #2a2a2a); padding: 12px 14px; }
      .doc .card .k { font-family: "DM Mono", monospace; font-size: 11px; text-transform: uppercase; color: var(--muted, #8a8a8a); }
      .doc .card .v { font-family: "Space Grotesk", sans-serif; font-size: 22px; margin-top: 6px; }
      .doc table { width: 100%; border-collapse: collapse; font-family: "DM Mono", monospace; font-size: 12px; margin: 12px 0 18px; }
      .doc th, .doc td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--muted, #2a2a2a); }
      .doc th { color: var(--muted, #8a8a8a); font-weight: 400; text-transform: uppercase; letter-spacing: 0.05em; }
      .doc td.n, .doc th.n { text-align: right; }
      .doc .up { color: #2f9e44; } .doc .down { color: #e03131; }
      .doc a { color: inherit; }
      .doc .note { border-left: 2px solid var(--muted, #2a2a2a); padding-left: 12px; color: var(--muted, #8a8a8a); font-family: "DM Mono", monospace; font-size: 12px; }
    </style>`;

const HEAD = (title, desc, url) => `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>${esc(title)}</title>
    <meta name="description" content="${esc(desc)}" />
    <link rel="canonical" href="${url}" />
    <meta property="og:type" content="article" />
    <meta property="og:site_name" content="Planet" />
    <meta property="og:url" content="${url}" />
    <meta property="og:title" content="${esc(title)}" />
    <meta property="og:description" content="${esc(desc)}" />
    <meta property="og:image" content="https://ppppp.space/icon.png" />
    <meta name="twitter:card" content="summary_large_image" />
    <link rel="icon" href="/icon.png" />
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link href="https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=Space+Grotesk:wght@400;500;700&display=swap" rel="stylesheet" />
    <link rel="stylesheet" href="/styles.css" />
    ${STYLE}
  </head>
  <body>
    ${NAV}
    <main class="doc">`;

const FOOT = `    </main>
  </body>
</html>
`;

function reportPage(snap, prev) {
  const ym = snap.month;
  const rows = snap.assets
    .map((a) => {
      const p = prev?.assets?.find((x) => x.index === a.index);
      const mom = p && p.currentPrice ? (a.currentPrice / p.currentPrice - 1) * 100 : null;
      return `<tr>
        <td>${a.index}</td>
        <td>${esc(a.name)}</td>
        <td>${esc(a.sector)}</td>
        <td class="n">${a.weightPct.toFixed(0)}%</td>
        <td class="n">${money(a.basePrice, 4)}</td>
        <td class="n">${money(a.currentPrice, 4)}</td>
        <td class="n ${mom == null ? "" : cls(mom)}">${mom == null ? "—" : pct(mom)}</td>
        <td class="n ${cls(a.sinceLaunchPct)}">${pct(a.sinceLaunchPct)}</td>
      </tr>`;
    })
    .join("\n");

  const movers = [...snap.assets]
    .filter((a) => a.riskState === 0)
    .map((a) => {
      const p = prev?.assets?.find((x) => x.index === a.index);
      const mom = p && p.currentPrice ? (a.currentPrice / p.currentPrice - 1) * 100 : a.sinceLaunchPct;
      return { ...a, mom };
    })
    .sort((x, y) => y.mom - x.mom);
  const best = movers[0];
  const worst = movers[movers.length - 1];

  const ppiMom = prev?.ppi ? (snap.ppi / prev.ppi - 1) * 100 : null;

  return (
    HEAD(
      `Planet basket report — ${ym}`,
      `Commodity basket report for ${ym}: index level, per-commodity weights and prices${prev ? ", month-over-month changes" : ""} and the methodology behind them.`,
      `https://ppppp.space/reports/${ym}`
    ) +
    `
      <p class="notice" style="font-family: 'DM Mono', monospace">[ monthly basket report · TON testnet PoC · not a stablecoin ]</p>
      <h1>Basket report — ${ym}</h1>
      <p class="sub">generated ${esc(snap.generatedAt)} UTC · core <code>${esc(snap.core)}</code>${prev ? ` · compared with ${esc(prev.month)}` : " · launch report (baseline)"}</p>

      <div class="cards">
        <div class="card"><div class="k">PPI (index)</div><div class="v">${snap.ppi.toFixed(6)}</div></div>
        <div class="card"><div class="k">since launch</div><div class="v ${cls((snap.ppi - 1) * 100)}">${pct((snap.ppi - 1) * 100)}</div></div>
        ${prev ? `<div class="card"><div class="k">month over month</div><div class="v ${cls(ppiMom)}">${pct(ppiMom)}</div></div>` : ""}
        <div class="card"><div class="k">commodities</div><div class="v">${snap.assets.length}</div></div>
      </div>

      ${
        best && worst
          ? `<p>Strongest${prev ? " this month" : " since launch"}: <b>${esc(best.name)}</b> ${pct(best.mom)} ·
             weakest: <b>${esc(worst.name)}</b> ${pct(worst.mom)}.</p>`
          : ""
      }

      <h2>Basket</h2>
      <table>
        <thead><tr><th>#</th><th>commodity</th><th>sector</th><th class="n">weight</th><th class="n">base</th><th class="n">close</th><th class="n">MoM</th><th class="n">since launch</th></tr></thead>
        <tbody>
${rows}
        </tbody>
      </table>
      <p class="note">
        Prices are the last oracle-accepted values on-chain at generation time, not an exchange close.
        "since launch" compares each commodity with its immutable base price; "MoM" compares with the
        previous monthly snapshot. A commodity flagged frozen would be excluded from the index and
        renormalised — see the methodology.
      </p>

      <h2>Index</h2>
      <p>
        The index is the weighted average of each commodity's price relative to its base price, with
        frozen commodities excluded and the remaining weights renormalised. Weights sum to exactly
        100% and no single commodity exceeds 15%.
      </p>
      <p><a href="/methodology">Methodology →</a> · <a href="/dashboard">Live dashboard →</a> · <a href="/reports">All reports →</a></p>

      <p class="note">
        Planet is an unaudited proof of concept on the TON testnet. Nothing here is a price, a
        valuation, or investment advice; the report describes an on-chain measurement only.
      </p>
    ` +
    FOOT
  );
}

function indexPage(snaps) {
  const list = [...snaps]
    .sort((a, b) => (a.month < b.month ? 1 : -1))
    .map(
      (s) =>
        `<tr><td><a href="/reports/${s.month}">${s.month}</a></td><td class="n">${s.ppi.toFixed(6)}</td><td class="n">${s.assets.length}</td><td>${esc(s.generatedAt.slice(0, 10))}</td></tr>`
    )
    .join("\n");
  return (
    HEAD(
      "Planet — monthly basket reports",
      "Monthly reports on Planet's on-chain commodity basket: index level, weights and per-commodity moves, with the methodology behind them.",
      "https://ppppp.space/reports"
    ) +
    `
      <p class="notice" style="font-family: 'DM Mono', monospace">[ monthly basket reports · TON testnet PoC ]</p>
      <h1>Monthly basket reports</h1>
      <p class="sub">one snapshot per month, generated from the chain and committed by CI — nothing hand-edited</p>
      <table>
        <thead><tr><th>month</th><th class="n">PPI</th><th class="n">commodities</th><th>generated</th></tr></thead>
        <tbody>
${list}
        </tbody>
      </table>
      <p><a href="/methodology">Methodology →</a> · <a href="/dashboard">Live dashboard →</a></p>
    ` +
    FOOT
  );
}

function updateSitemap(months) {
  const p = join(WEB, "sitemap.xml");
  if (!existsSync(p)) return;
  let xml = readFileSync(p, "utf8");
  const want = ["https://ppppp.space/reports", ...months.map((m) => `https://ppppp.space/reports/${m}`)];
  let added = 0;
  for (const u of want) {
    if (xml.includes(`<loc>${u}</loc>`)) continue;
    xml = xml.replace(
      "</urlset>",
      `  <url>\n    <loc>${u}</loc>\n    <changefreq>monthly</changefreq>\n    <priority>0.6</priority>\n  </url>\n</urlset>`
    );
    added++;
  }
  if (added) writeFileSync(p, xml);
  return added;
}

async function main() {
  const now = new Date();
  const month = now.toISOString().slice(0, 7); // YYYY-MM
  mkdirSync(REPORTS, { recursive: true });

  const target = join(REPORTS, `${month}.json`);
  if (existsSync(target) && process.env.FORCE !== "1") {
    console.log(`report ${month} already exists — nothing to do (set FORCE=1 to overwrite)`);
    return;
  }

  const data = await readBasket();
  const prev = prevSnapshots().filter((s) => s.month < month).pop() ?? null;

  const snap = {
    month,
    generatedAt: now.toISOString(),
    core: data.core,
    ppi: data.ppi,
    supply: data.supply,
    reserve: data.reserve,
    lastOracleUpdate: data.lastOracleUpdate,
    assets: data.assets,
  };

  writeFileSync(target, JSON.stringify(snap, null, 2) + "\n");
  writeFileSync(join(REPORTS, `${month}.html`), reportPage(snap, prev));

  const all = prevSnapshots().filter((s) => s.month <= month);
  if (!all.some((s) => s.month === month)) all.push(snap);
  writeFileSync(join(REPORTS, "index.html"), indexPage(all));

  const added = updateSitemap(all.map((s) => s.month));
  console.log(`wrote reports/${month}.json + .html, refreshed reports/index.html, sitemap +${added ?? 0} urls`);
  console.log(`PPI ${snap.ppi.toFixed(6)} · ${all.length} report(s) on file`);

  // Announce it in the community chat(s) if a bot token is available — the report is also a
  // content loop, and nobody should have to remember to post it.
  const TOKEN = process.env.TG_BOT_TOKEN || "";
  const CHATS = (process.env.TG_ALERT_CHAT_ID || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (TOKEN && CHATS.length && prev) {
    const ppiMom = prev.ppi ? (snap.ppi / prev.ppi - 1) * 100 : 0;
    const movers = [...snap.assets]
      .filter((a) => a.riskState === 0)
      .map((a) => {
        const p = prev.assets?.find((x) => x.index === a.index);
        return { name: a.name, mom: p && p.currentPrice ? (a.currentPrice / p.currentPrice - 1) * 100 : a.sinceLaunchPct };
      })
      .sort((x, y) => y.mom - x.mom);
    const best = movers[0];
    const worst = movers[movers.length - 1];
    const text =
      `Planet basket report — ${month}\n` +
      `PPI ${snap.ppi.toFixed(6)} (${pct(ppiMom)} MoM) · ${snap.assets.length} commodities\n` +
      (best && worst ? `strongest ${best.name} ${pct(best.mom)} · weakest ${worst.name} ${pct(worst.mom)}\n` : "") +
      `https://ppppp.space/reports/${month}`;
    for (const chat of CHATS) {
      try {
        const res = await fetch(`https://api.telegram.org/bot${TOKEN}/sendMessage`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: false }),
        });
        const j = await res.json().catch(() => ({}));
        console.log(`telegram -> ${chat}: ok=${j.ok} ${j.description ?? ""}`);
      } catch (e) {
        console.log(`telegram -> ${chat} failed: ${e?.message ?? e}`);
      }
    }
  }
}

main().catch((e) => {
  console.error("report generation failed:", e?.message ?? e);
  process.exit(1);
});
