// Daily PPI snapshot -> docs/data/ppi/<date>.json + index.json.
// The track record IS the product asset for index licensing: a public, timestamped, reproducible
// series of the index value and each asset's risk state. Runs from GitHub Actions once a day.
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";

const API = process.env.API || "https://ppppp.space/api/v1/ppi";
const res = await fetch(API, { headers: { "cache-control": "no-cache" } });
if (!res.ok) { console.error("api HTTP", res.status); process.exit(1); }
const j = await res.json();
if (j.error) { console.error("api error:", JSON.stringify(j).slice(0, 300)); process.exit(1); }

const day = new Date().toISOString().slice(0, 10);
const dir = "../docs/data/ppi";
if (!existsSync(dir)) mkdirSync(dir, { recursive: true });

const ppi = j.ppi ?? j.currentPpi ?? j.index ?? null;
const assets = j.assets || [];
const rec = {
  date: day,
  capturedAt: new Date().toISOString(),
  ppi,
  oracle: j.oracle ?? null,
  assets: assets.map((a) => ({
    index: a.index, symbol: a.symbol ?? a.name ?? null, weight: a.weight,
    price: a.price ?? a.currentPrice ?? null, riskState: a.riskState ?? a.risk ?? null,
  })),
};
writeFileSync(`${dir}/${day}.json`, JSON.stringify(rec, null, 1));

const idxPath = `${dir}/index.json`;
const idx = existsSync(idxPath) ? JSON.parse(readFileSync(idxPath, "utf8")) : [];
const row = { date: day, ppi, risk: rec.oracle?.riskLevel ?? rec.oracle?.risk ?? null, assets: assets.length };
const at = idx.findIndex((x) => x.date === day);
if (at >= 0) idx[at] = row; else idx.push(row);
idx.sort((a, b) => a.date.localeCompare(b.date));
writeFileSync(idxPath, JSON.stringify(idx, null, 1));
console.log(`snapshot ${day}: ppi ${ppi}, ${assets.length} assets, ${idx.length} rows`);
