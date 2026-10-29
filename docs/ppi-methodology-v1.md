# PPI — Planet Commodity Index. Methodology, v1.0

Status: deployed on Arbitrum Sepolia; mainnet deployment pending. This document is the specification
a venue's risk team would read before listing a perp against PPI. It states the rules **and the
limitations**, because an index that hides its warts is not licensable.

---

## 1. What this index is

A **fixed-weight, base-locked price index** over 14 physical-commodity exposures, computed on-chain
from prices pushed by an authorised relayer. It measures *price change relative to a locked base*,
not an investable total return.

It is **not**: a futures index (no roll), a total-return index (no collateral yield), or a
deliverable basket (no warehouse receipts).

---

## 2. Composition (weights in ppm of 1,000,000)

| # | Sector | Asset | Price reference | Weight | Channels |
|---|---|---|---|---|---|
| 0 | Energy | WTI Crude | CL=F front month | 14.0% | Yahoo + Sina/Tencent/Eastmoney |
| 1 | Energy | Brent Crude | BZ=F front month | 11.0% | Yahoo + Sina/Tencent |
| 2 | Energy | Natural Gas | NG=F front month | 8.0% | Yahoo **only** |
| 3 | Metals | Gold | GC=F front month | 12.0% | Yahoo + Sina/Tencent/Eastmoney |
| 4 | Metals | Silver | SI=F front month | 7.0% | Yahoo + Sina/Tencent/Eastmoney |
| 5 | Metals | Copper | HG=F front month | 6.0% | Yahoo + Sina/Tencent/Eastmoney |
| 6 | Agriculture | Wheat | ZW=F front month | 9.0% | Yahoo + Tencent |
| 7 | Agriculture | Corn | ZC=F front month | 7.0% | Yahoo + Tencent |
| 8 | Agriculture | Soybean | ZS=F front month | 6.0% | Yahoo + Tencent |
| 9 | Softs | Coffee | KC=F front month | 4.0% | Yahoo + Sina |
| 10 | Industrial | Lumber | **WOOD ETF proxy** | 4.0% | Yahoo + Tencent |
| 11 | Industrial | Lithium | **LIT ETF proxy** | 3.0% | Yahoo + Tencent |
| 12 | Water | Water rights | **PHO ETF proxy** (CME NQH2O design) | 5.0% | Yahoo + Tencent |
| 13 | Carbon | Carbon credits | **KRBN ETF proxy** (CME GEO design) | 4.0% | Yahoo + Tencent |

Sector totals: Energy 33% · Metals 25% · Agriculture 22% · Industrial 7% · Water 5% · Softs 4% ·
Carbon 4%.

**Cap:** no single asset may exceed 15% (`MAX_ASSET_WEIGHT = 150_000` ppm, enforced on-chain).
The 15% cap is what prevents one market (oil) from dominating the index.

---

## 3. Price inputs

Each asset is fed by up to four independent channels. The rule is a **primary + confirmation** rule,
deliberately not a median:

1. The primary channel (Yahoo) sets the candidate price.
2. Another channel **confirms** only if it lands within **0.5%** of the primary.
3. A reading with no confirmation is published as **caution** (riskState = 1) at the primary price.
4. A dissenting channel is **never averaged in**. A 1% gap between venues is usually two different
   contract expiries; averaging those blends two different assets.

This is why `/api/v1/sources` publishes every channel's reading, verdict (`primary` / `confirmed` /
`rejected` / `unavailable`) and, for rejections, the distance from the primary. Any price can be
recomputed from published inputs.

**Natural gas is single-source on purpose** — the alternative venues quote a later expiry, so
confirming it would compare two different instruments. It therefore runs at caution by design.

---

## 4. Index formula (exact, as implemented)

```
PPI = Σ_i ( w_i × (P_i / P_i^0) × SCALE ) / Σ_i w_i        for assets with riskState ≠ FROZEN
SCALE = 1e6
```

where `w_i` is the weight in ppm, `P_i` the current price (1e6 fixed point), `P_i^0` the **locked**
base price. Frozen assets are excluded from both numerator and denominator, so the remaining weights
renormalise automatically — the index never "loses" 15% of itself when one market freezes.

Consequences of this formula, stated plainly:

- It is a **Laspeyres-type price-relative index**: weights are fixed, the base is locked.
- It tracks **front-month price levels**, not a rolled futures position. Contango/backwardation and
  roll cost are **not** in the index.
- Because the base is locked and weights do not rebalance, the effective weights drift from target as
  relative prices move. This is a known limitation (§8).

---

## 5. Edge cases and how they are handled

| Situation | Rule |
|---|---|
| Price older than **6 hours** | stale; `riskState` rises; mint gated on the oldest asset |
| Single update moves price **> 50%** | rejected on-chain (`priceJumpOk`) |
| A channel disagrees by **> 0.5%** | rejected, flagged, never averaged; the asset shows caution |
| One market is frozen | excluded from PPI; weights renormalise; frozen weight capped (40%) |
| Weekend / holiday (futures closed) | prices do not move; staleness and caution are the honest signal |
| Asset added or replaced | `setAsset` by owner; base price may only be set **before** `lockBasePrices` |

---

## 6. Governance and who can change what

| Action | Holder | Delay |
|---|---|---|
| `updatePrice` (normal push) | authorised relayer | none — hourly |
| `forcePrice` (bypass the 50% guard) | timelock owner | timelock delay |
| `setRelayer`, `setRiskState`, `setLimits`, `pause` | timelock owner | timelock delay |
| `setAsset` (weights) | timelock owner | timelock delay |
| `lockBasePrices` | timelock owner | one-way |

**Current state (Sepolia):** owner = timelock, timelock delay = 60 seconds, relayer = a single EOA,
oracle signer set = 1-of-1. For mainnet these must change: delay in hours, signer set 2-of-3 or
better, relayer key separated from the owner (§9).

---

## 7. Transparency and recomputation

- **On-chain events:** `PriceUpdated(asset, price, ppi, timestamp)`, `AssetSet`, `RiskStateSet`.
- **API:** `/api/v1/status` (PPI, accounting), `/api/v1/oracle` (health, staleness, reasons),
  `/api/v1/oracle?full=1` (weights, frozen/caution lists), `/api/v1/sources` (per-channel readings
  and verdicts).
- **Recompute:** with the locked base prices (published at deployment), the current prices from
  `/sources`, and the weights above, PPI is reproducible offline with the formula in §4. No
  proprietary inputs.

---

## 8. Known limitations (read before licensing)

1. **No roll, no carry.** Front-month price levels only. A perp settleable against PPI tracks spot
   price change, not futures returns. This must be disclosed to traders.
2. **Base-locked, no rebalancing.** Weights drift with relative prices; there is no quarterly
   reconstitution. A venue that needs rebalancing needs a v2 index.
3. **Four of fourteen exposures are ETF proxies** (lumber, lithium, water, carbon), not deliverable
   commodities. Water and carbon reference CME *design* markets; liquidity there is thin.
4. **Weekday-only updates.** Weekends and holidays are stale by construction.
5. **Oracle trust.** Today 1-of-1 signer, hourly pushes. The confidence signal is designed to make
   this visible, not to make it disappear.
6. **Not a return index.** Do not present PPI as an investable return series.

---

## 9. Before mainnet (pre-listing checklist)

- [ ] Deploy to Arbitrum One; publish addresses and verify source on Arbiscan
- [ ] Timelock delay raised from 60s to ≥ 6 hours
- [ ] Relayer key separated from owner key; oracle signer set raised to 2-of-3
- [ ] Base prices frozen and published with the deployment
- [ ] Relayer mainnet runbook: hourly push, alerting on failure, staleness SLA
- [ ] Independent review of this document against the deployed bytecode

---

## 10. Versioning

| Version | Change |
|---|---|
| v1.0 | 14 assets, 4 channels, confirmation rule, on-chain PPI, fixed base, no rebalancing |

Changes to composition, weights or channel rules bump the version and are announced before applying.
A venue listing PPI should pin the version it licensed.

---

*This document describes the deployed behaviour, including its limits. Where the document and the
bytecode disagree, the bytecode wins and the document is a bug.*
