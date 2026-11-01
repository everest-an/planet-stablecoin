---
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
- Source of truth: PlanetCore `0x61de052af7cb7dc957a07b1e6298152bb851cbbb` on Arbitrum One

## Columns

| column | meaning |
|---|---|
| `date` | UTC date of the snapshot |
| `ppi` | index value, 1.0 = inception (1e6 fixed point in the API, decimal here) |
| `asset_index` | 0–13 |
| `asset_symbol` | commodity symbol as published |
| `weight_ppm` | basket weight in parts-per-million (sum = 1,000,000) |
| `price_1e6` | asset price, 1e6 fixed point |
| `risk_state` | 0 normal / 1 caution / 2 frozen |

## Notes

- The index is **not** a stablecoin and there is no commodity reserve; it is a price index.
- Data quality is the point: `risk_state` is published with the price, so a model can down-weight
  or exclude an asset exactly when the oracle marks it degraded.
- The snapshot series starts 2026-10-31 (current rows: 2; latest
  2026-11-01, PPI 0.999013).
- Contracts are self-audited, not externally audited. Repo: https://github.com/everest-an/planet-stablecoin
