# Planet Feeds — product definition, pricing, and the first integration

Written 2026-10-27. This is the B2B product: the commodity price layer, sold to whoever is building
products on commodity prices. It is the only thing here that can be sold without custody, without a
licence, and without waiting for a backing model.

---

## 1. What is being sold

**A commodity price feed with an on-chain confidence signal.**

Most feeds give you a number. This one gives you a number **and** whether it could be confirmed, per
asset, with the raw readings behind it. That difference matters exactly when money is at risk: at the
moment a venue goes quiet, a contract rolls, or two sources disagree.

Live endpoints (already running):

```
GET /api/v1/status               basket + index + accounting
GET /api/v1/oracle               health: freshness, relayer, reasons[]
GET /api/v1/oracle?full=1        per-asset weights, frozen/caution lists, stale list
GET /api/v1/sources              every channel, its reading, its verdict, the rejection distance
```

## 2. The data model (why it is different)

| Field | Meaning |
|---|---|
| `price` | median-of-confirmed, but see below: **not** a blind median |
| `confirmations` | how many channels landed within 0.5% of the primary |
| `riskState` | `0` normal, `1` caution (no channel confirmed), `2` frozen |
| `lastUpdate` | per asset, not global |
| `channels[].verdict` | `primary` / `confirmed` / `rejected` / `unavailable` |
| `shortfall` (implied) | for a rejected channel, how far off it was |

The rule, stated plainly because integrators will ask:

> The primary channel sets the price; another channel is a confirmation only if it lands within
> 0.5%. A reading with no confirmation is published as caution at the primary price — never averaged
> with a dissenter. A 1% gap between venues is usually two contract expiries, and averaging those
> blends two different assets.

Today: 14 assets, 4 channels (Yahoo primary; Sina, Tencent, Eastmoney as confirmations), 34–36
channel reads per refresh, 13 of 14 assets with two or more channels. Natural gas is single-source
on purpose (its alternatives quote later expiries).

## 3. Who buys it, and what they do with `riskState`

**Perp DEX listing commodity markets** — the confidence signal maps directly onto margin:

```
confirmations >= 2   → full leverage
confirmations == 0   → reduced leverage (caution)
stale (older than the asset's own ceiling) → close-only
```

This is the differentiator nobody ships for commodities: a venue that widens or stops *before* the
liquidation engine fires on a bad print.

**RWA lenders accepting commodity collateral** — a mark price is the whole problem. A feed that says
"unconfirmed" is more useful than one that pretends.

**Structured products / funds** — a reproducible settlement record: every push can be re-derived from
`/sources`, so a NAV dispute has an answer that is not "ask the oracle operator".

## 4. Pricing (proposal — none of this is signed or advertised yet)

| Tier | Price | Includes |
|---|---|---|
| Free | $0 | current values, no archive, attribution required, best-effort |
| Starter | **$500 / month** | 5 assets, 12 months of history, 99% target |
| Growth | **$2,000 / month** | all 14, history, webhook push on change, 99.5% target, one custom asset |
| Index licence | **3–5 bps of AUM** | a product may use the name "Planet Index" and its published rule |
| On-chain delivery | setup + monthly | deploy the oracle + core on the buyer's chain |

**Do not quote a percentage for affiliate revenue or for uptime before it has been measured.** The
tiers above are a starting ask, not a published price list.

## 5. What we do not have (say it before they ask)

- **No mainnet index yet.** The on-chain basket lives on Arbitrum Sepolia. The HTTP feed is
  chain-independent and works today; an on-chain deployment on Arbitrum One is a cost, not a rewrite.
- **No SLA history.** "99.5% target" is an intention until the hourly monitor has months of data.
- **No third-party audit** (see `audit-simulated-2026-10.md`, which says in its first line that it is
  a simulated review).
- **No coverage for the hard commodities.** Coverage is 14 instruments with 2–4 channels; anything
  outside that list is a custom job.

## 6. The first conversation

Target, in order: (1) a perp venue that already lists or wants to list commodity markets, (2) an RWA
lender taking commodity collateral, (3) a fund issuing a commodity-linked note.

Opening message:

> We run a commodity price index on Arbitrum: 14 instruments, four independent channels per asset, and
> a confirmation rule instead of a median — so the feed publishes "this reading is unconfirmed"
> on-chain instead of guessing. Public per-channel audit trail at /api/v1/sources.
>
> If you are listing commodity perps or taking commodity collateral, the oracle is usually the slow
> part. Two things worth your time: (a) the confidence signal can drive margin instead of just being
> a display field, (b) every price is reproducible from published inputs, which is what you want in a
> dispute.
>
> Happy to send the feed spec. No integration cost to look.

## 7. What would make this real

1. **Mainnet index on Arbitrum One.** Until the index is on a chain people use, this is a demo feed.
2. **A monitor with history.** The hourly workflow exists; its uptime record is what an SLA claim
   rests on.
3. **One paying pilot.** Even $500/month changes the conversation from "interesting" to "in use".
