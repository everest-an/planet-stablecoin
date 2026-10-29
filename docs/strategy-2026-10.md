# Strategy memo — which demand models hold, and what Planet is worth

Written 2026-10-29. No flattery, VC lens, current as of the live product.

---

## 1. The whitepaper's assets vs. what the market actually tokenised

The v1 whitepaper defined 14 assets across energy, metals, agriculture. Reality check per asset
class on Ethereum mainnet today:

| Class | Whitepaper assets | Credible holdable token? | Why |
|---|---|---|---|
| Metals | gold, silver, copper | gold: 4 issuers (done) · silver: 1 (done) · copper: **none** | value density |
| Energy | WTI, Brent, natural gas | **none** | see §2 |
| Agriculture | wheat, corn, soybean | LandX grain tokens only (yield-stream model, not vaulted grain) | see §2 |

The asset list was aspirational. The market answered with a hard filter: **only gold and silver got
tokenised**, and the reasons are physical, not technical.

## 2. Why oil has no token and never will — the physical economics

Gold: ~$65,000/kg, non-perishable, and people *hold it* as savings for decades. That is why Paxos
can custody it, charge for it, and get audited for it.

Crude: ~$0.5/kg, needs tanks, insurance, surveillance, and **nobody wants to take delivery** — the
demand is for price exposure, which futures already serve perfectly. Natural gas is worse
(cryogenic). Copper, wheat, corn: bulky, perishable, futures-dominated.

So "tokenised crude oil" is not a gap waiting to be filled — it is a market that economics
correctly rejected. When war spikes oil, the speculation flows into CL futures, USO, and
crypto-native perps (GMX, Hyperliquid, Synthetix), **not into a token that does not exist.**

## 3. The two demand models the user proposed, examined

### Model A — "war → people speculate on tokenised oil"

Demand: real. Supply: nonexistent, and cannot be created by us — custody of oil is a capital and
logistics business, not a code project.

What serves that demand today is **derivatives**, not RWA tokens. If Planet wants to serve it, the
honest route is a *commodity trading UI* — deep-linking users into existing perp venues for the
full 14-asset list (oil, gas, copper, wheat — all trade on GMX/Hyperliquid already). That is
buildable with near-zero capital, but it is a **different product**: trading, leverage, liquidations,
not "hold your ounces". Mixing it into the metals page would destroy the read-only/trust story.

Verdict: demand real, but it changes what the company is. Do not bolt it onto /metals.

### Model B — "people who cannot buy gold/silver traditionally, holding it through here"

This is the model that **holds**. Evidence: PAXG ~$600M and XAUT ~$580M AUM are heavily used in
Turkey, Argentina, Nigeria, and by China outbound flows — people who can buy USDT P2P but cannot
open an international brokerage. Their path is exactly ours: USDC → PAXG/XAUT.

What we add over Rango/1inch directly: multi-wallet aggregation, issuer-risk honesty, dual prices,
five-chain comparison, zh. Thin but real. The revenue is affiliate bps on flow — small, positive,
scales only with distribution.

Verdict: the only model that holds today. It is a distribution business, not a technology business.

### Model C — the whitepaper's own model: a commodity purchasing-power index

The PPI. The honest reading of the codebase: it works as a **price index** (oracle, feed, B2B), and
it does **not** work as a holdable token, because H-02 is unsolved — a stablecoin reserve cannot
track a commodity basket unless the reserve *earns* the basket's return. The one precedent that
solved this, FPI (Frax), did it by holding CPI-linked bonds as reserve. The Planet equivalent
would be a custodian holding commodity ETFs (GSG/DBC) and minting against NAV. That is a fund
launch: custodian, auditor, prospectus, capital. It is the only version of the whitepaper that is
fundable — and it is not a code problem.

## 4. VC lens — what this actually is and what could be funded

As it stands: **a feature, not a company.** Pre-revenue, no moat (any team rebuilds this in a
month — we did), market that caps at a lifestyle business through affiliate flow. A VC passes.

The three ways this becomes fundable, honestly ordered by odds:

1. **Distribution business (Model B)**: the only thing that works today. Needs: accounts in the
   target communities (Turkey/Argentina/China-outbound crypto groups), volume, and an affiliate
   programme live. Ceiling: $1–10k/month with real users. Fundable: no (lifestyle), but it pays the
   bills and builds the user base for #3.
2. **Commodity perps UI (Model A)**: serve war/oil demand via existing venues. Real product, real
   demand, near-zero capital, but it is a trading product — different trust, different users, and
   crowded (GMX/Hyperliquid UIs are good). Fundable: only with distribution it doesn't yet have.
3. **Backed index token (Model C)**: the whitepaper's ambition, correct only as an ETF-reserve fund.
   Fundable: yes, but it needs a custodian + legal + seed capital, i.e. a founder with a finance
   network. It is a fund, not a startup.

## 5. Recommendation

1. Keep /metals exactly as the trust product it is; do not add oil/derivatives to it.
2. Execute Model B now: the outreach assets exist (`docs/gtm-2026-10.md`); what is missing is the
   affiliate registration and posting. Distribution decides this model, nothing else.
3. If the whitepaper ambition stays: pursue it as Model C (fund/ETF-reserve), or as a separate
   "commodity perps UI" product line — never as more Solidity on Sepolia, which has no buyer.
4. The B2B feed remains a small real revenue line (Chainlink competes; our differentiation is the
   confirmation rule, which is thin).

**Bottom line:** of the models proposed, "people who cannot buy gold elsewhere hold it through
here" is the one that is true; "war oil speculation" is true demand with no supply we can create;
the whitepaper's 14-asset holdable basket is physically unfundable. The product that serves the
true model is already built — what is missing is distribution, not features.
