// Export the daily PPI snapshots into a Hugging Face / Kaggle-ready dataset bundle.
// Output: docs/data/hf/ppi.csv + docs/data/hf/README.md (dataset card). Re-run after each snapshot.
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";

const SRC = "../docs/data/ppi";
const OUT = "../docs/data/hf";
if (!existsSync(OUT)) mkdirSync(OUT, { recursive: true });

const files = existsSync(SRC) ? readdirSync(SRC).filter((f) => /^\d{4}-\d{2}-\d{2}\.json$/.test(f)).sort() : [];
const rows = [];
for (const f of files) {
  const r = JSON.parse(readFileSync(`${SRC}/${f}`, "utf8"));
  for (const a of r.assets || []) {
    rows.push([r.date, r.ppi ?? "", a.index, a.symbol ?? "", a.weight ?? "", a.price ?? "", a.riskState ?? ""].join(","));
  }
}
const header = "date,ppi,asset_index,asset_symbol,weight_ppm,price_1e6,risk_state";
writeFileSync(`${OUT}/ppi.csv`, [header, ...rows].join("\n") + "\n");

const first = files.length ? JSON.parse(readFileSync(`${SRC}/${files[0]}`, "utf8")) : null;
const last = files.length ? JSON.parse(readFileSync(`${SRC}/${files[files.length - 1]}`, "utf8")) : null;

const card = `---
license: cc-by-4.0
task_categories:
  - tabular-regression
tags:
  - commodities
  - finance
  - on-chain
  - index
  - time-series
pretty_name: Planet PPI — on-chain commodity purchasing-power index
size_categories:
  - n<1K
---

# Planet PPI — on-chain commodity purchasing-power index

Daily snapshots of a 14-asset commodity index published on Arbitrum One. Each row is one asset on
one day: its weight in the basket, its price (1e6 fixed point, USD), and its **risk state**
(0 = normal, 1 = caution, 2 = frozen) as published by the on-chain oracle.

- Live index: https://ppppp.space/ppi
- JSON API: https://ppppp.space/api/v1/ppi
- Methodology: https://ppppp.space/methodology
- Source of truth: PlanetCore \`0x61de052af7cb7dc957a07b1e6298152bb851cbbb\` on Arbitrum One

## Columns

| column | meaning |
|---|---|
| \`date\` | UTC date of the snapshot |
| \`ppi\` | index value, 1.0 = inception (1e6 fixed point in the API, decimal here) |
| \`asset_index\` | 0–13 |
| \`asset_symbol\` | commodity symbol as published |
| \`weight_ppm\` | basket weight in parts-per-million (sum = 1,000,000) |
| \`price_1e6\` | asset price, 1e6 fixed point |
| \`risk_state\` | 0 normal / 1 caution / 2 frozen |

## Notes

- The index is **not** a stablecoin and there is no commodity reserve; it is a price index.
- Data quality is the point: \`risk_state\` is published with the price, so a model can down-weight
  or exclude an asset exactly when the oracle marks it degraded.
- The snapshot series starts ${first?.date ?? "n/a"} (current rows: ${files.length}; latest
  ${last?.date ?? "n/a"}, PPI ${last?.ppi ?? "n/a"}).
- Contracts are self-audited, not externally audited. Repo: https://github.com/everest-an/planet-stablecoin
`;
writeFileSync(`${OUT}/README.md`, card);
console.log(`exported ${files.length} days, ${rows.length} rows -> docs/data/hf/{ppi.csv,README.md}`);
