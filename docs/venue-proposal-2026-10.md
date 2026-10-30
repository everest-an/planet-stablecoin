# PPI — a commodity index you can list. One page.

## What it is

A 14-commodity price index, live on Arbitrum One, computed on-chain from four independent price
channels. It exists to be a settlement reference for commodity perpetuals — the same role an equity
index plays for an index future.

- **Live now:** `PPI = 1.009055`, 14 assets, weights locked, contracts verified on Arbiscan.
- **Oracle:** 2-of-3 signed pull feed. Publishing is free; whoever consumes a price submits it and
  pays that one transaction. There is no scheduled push and no keeper to trust.
- **Rulebook:** public (`/methodology`, `docs/ppi-methodology-v1.md`), including the limitations.

## Why this is different from a single-commodity perp

Single-commodity perps exist (GOLD on Hyperliquid, XAU/XAG/WTI/Brent on GMX). A **basket** perp does
not, and it is the difference between a trade and a hedge: one instrument for "commodities" instead
of a decision about which one.

The second difference is the confidence signal. Every asset carries a state derived from how many
channels confirmed its price in the last push:

```
confirmations >= 2   normal margin
confirmations == 0   caution: margin requirement doubles, new risk throttled
feed stale > 30 min  caution
feed stale > 6 h     frozen: close-only
```

A venue can map that directly onto margin and funding. When the four oil channels disagree, the market
tightens before the liquidation engine fires on a bad print — which is the failure mode that hurts
both traders and the pool.

## What you get

| | |
|---|---|
| Index licence | the right to list a perp settled against PPI, version-pinned (v1.0) |
| Data feed | `/api/v1/ppi`, `/api/v1/price-signed`, `/api/v1/sources` (per-channel audit trail) |
| Risk signal | `riskLevel()` 0/1/2, already implemented in the reference market |
| Reference implementation | `PPIPerp.sol` — LP-pool counterparty, funding, liquidation, riskState margin. Audited? Not yet; see below |

## Commercials (negotiable)

- Index licence: **bps of notional** traded against PPI, or a flat annual fee while volume is small.
- Data: monthly subscription once there is an SLA.
- Non-exclusive by design: an index that is only available to one venue is not an index.

## What we are not claiming

- **No audit yet.** We have three rounds of self-review and a scope pack ready for a firm; we will not
  present self-review as audit.
- **No consumer yet.** We are not going to pretend there is demand we have not seen.
- **No track record.** The index has been live for days, not years.

What you can verify today: the contracts on Arbiscan, the methodology against the bytecode, and the
per-channel audit trail behind every published number.

## The ask

A 30-minute call to see whether a commodity basket fits your listing roadmap. If it does, we will send
the methodology, the feed spec, and the reference market; if it does not, that is a useful answer too.

---

*Contact: the owner of the GitHub repository `everest-an/planet-stablecoin`.*
