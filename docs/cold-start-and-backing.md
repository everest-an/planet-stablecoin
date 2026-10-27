# Cold start, ETF backing, and who pays whom

Written 2026-10-27. Answers four questions that only look separate: how the basket anchors to real
ETFs, where a customer's profit comes from, where the protocol's profit comes from, and what
"automatic buying" can actually mean.

---

## 1. Today the anchor is a price, not an asset

The basket's 14 legs each have a **price feed** (four channels, §7.1) and, in §3.1, an **ETF proxy**
column. What the contract holds is `depositToken` — test USDC. Nothing in the deployed system owns a
share of GLD, USO, WOOD or any other instrument.

So the honest sentence is: *PLT tracks the price of a basket; it is not a claim on the basket.*
That is Stage 1 in §1.2, and "how do we anchor to real ETFs" is precisely the Stage 1 → Stage 2 move.

There are three ways to make the anchor real, and they differ by an order of magnitude in cost.

---

## 2. Three routes to a real anchor

| | A. Synthetic + hedge | B. Hold the ETFs | C. Tokenised ETFs |
|---|---|---|---|
| Reserve holds | USDC + long futures position | the 14 ETFs at a broker | on-chain tokenised fund shares |
| Value tracks the index | yes, if the hedge is delta-matched | yes, by construction | yes, by construction |
| Needs | a futures broker, margin, roll management | broker/custodian, entity, KYC | an issuer relationship (Ondo/Backed/Superstate class) |
| Running cost | roll + margin financing + basis risk | ETF expense ratios (≈0.15–0.9% p.a., confirm per fund) | issuer fee + on-chain liquidity |
| Legal weight | medium (derivatives) | **heavy** (you are running a fund) | medium (you are a distributor) |
| Cold start | cheapest to start, hardest to explain | simplest to explain, 14 line items to trade | fewest moving parts, depends on a third party |
| "Automatic" | bot rebalances futures margins | operator rebalances at the broker | contract swaps, genuinely on-chain |

**Recommendation for cold start: B, with a smaller basket.** Not because it is elegant, but because
it removes the two things that kill early products: the protocol no longer has to be short its own
index (which today means every customer gain is a reserve loss), and the price feed becomes NAV
rather than a proxy. Start with the four or five ETFs that are cheap, liquid and unambiguous
(GLD, SLV, CPER, CORN, WEAT), and add legs as AUM justifies the trading.

Route A is what a trading desk would do and what FPI does in spirit (its reserve is deployed into
yield strategies). It is faster to start and much harder to run. Route C is the end state and is
blocked on an issuer, not on code.

---

## 3. Where does a customer's profit come from?

A customer who wants ETF-like exposure mints PLT with USDC and later redeems at the index. In three
different worlds that money comes from three different places:

| World | The customer's +10% comes from | Who loses |
|---|---|---|
| **Today** (USDC reserve, no hedge) | the reserve, which did not rise | the protocol, and the last redeemer (pro-rata) |
| **With a hedge or held basket** | the commodity market itself | a counterparty in the futures market, or nobody — it is real appreciation of a real asset |
| **With a tokenised ETF reserve** | the ETF's NAV | nobody |

This is the whole argument for Stage 2 in one table. Right now the product is a **subsidy**: the
first customers are paid out of the reserve, which is exactly why the pro-rata fallback exists. You
cannot market "earn ETF upside" on top of a dollar reserve without saying who funds it.

There is a fourth, legitimate answer: **the customer is not earning ETF upside at all, they are
hedging against commodity inflation** — they want PLT's *purchasing power* to stay constant, and
they accept that its dollar price moves. That framing works even in Stage 1, but then the product
must not be sold as an investment and the reserve must not promise index returns. Pick one story.

---

## 4. Where does the protocol's profit come from?

Today: **nowhere.** `_routeFees` sends 90% of the fee to the reserve and 10% to the risk fund. The
operator (the entity behind the relayer) has no revenue line at all. That is not a business; it is a
subsidy with extra steps.

A working model has three lines, in order of reliability:

1. **Management fee on AUM** — e.g. 0.5–1.0% p.a., accrued per block on `totalSupply × index`. This
   is the line every ETF has, and it is the one that survives quiet markets. It requires a treasury
   address and a governance-set rate; neither exists in the contract today.
2. **Mint/redeem fees** — already there (50 bps rising to 300 bps at the band edge). Today all of it
   accrues to the reserve; a treasury share would need to be carved out of `_routeFees`.
3. **Float / reserve yield** — if the reserve sits in T-bills or a lending market, the yield is
   revenue *and* the thing that keeps the collateral ratio from decaying (the FPI lesson). Split it
   between treasury and reserve by policy.

Note what is **not** on the list: spread on a market we do not run, and "token appreciation". PLT is
a claim, not equity.

---

## 5. What "automatic buying" can actually mean

A smart contract cannot open a brokerage account. Buying an ETF requires a legal entity, a KYC'd
account, and T+1 settlement — none of which a `call` can do. So "automatic" splits into three
honest patterns:

**Pattern 1 — chain decides, operator executes, attestation reconciles (route B).**
The target is `weight_i × totalReserve`. A keeper reads the chain, computes the drift (the RTRA
formula, §8), places orders at the broker, waits for settlement, then writes the resulting holdings
hash to `reserveAttestation` and the reserve total to the core. The chain cannot verify the trade; it
can verify that the *declared* reserve is ≥ the liability (`isSolvent()`), and a monitor can flag
drift between the attestation and the last known state. This is the only pattern that works with
ordinary ETFs, and it is genuinely semi-automatic: human-free in steady state, human in exceptions.

**Pattern 2 — tokenised ETFs, so the rebalance is a swap (route C).**
If the reserve holds tokenised fund shares, then "buy" is a DEX swap or an issuer mint, and a keeper
contract can do it with no broker. This is the only truly on-chain version. It is blocked on the
issuer, not on us.

**Pattern 3 — futures margin (route A).**
A bot maintains a delta-neutral-to-index position: it must post margin, roll before expiry, and top
up on adverse moves. Fully automatable in principle, but now the operator runs a leveraged position
for strangers, which is a risk and probably a licence.

The pieces we already have map onto Pattern 1: `reserveAttestation` (the pointer), `isSolvent()` (the
check), the hourly monitor (the alert). What is missing is the keeper that computes drift and the
broker integration behind it.

---

## 6. A cold start that does not require pretending

| Stage | AUM | Basket | What is true | What breaks next |
|---|---|---|---|---|
| 0 | $0 | 14 price feeds | site is honest about being a tracker | nothing to trade against |
| 1 | $10–50k | **5 ETFs**, held | first real anchor; redemption is a sale | entity + broker + attestation cadence |
| 2 | $100k+ | 8–10 ETFs | weights approach the paper's basket | rebalancing cost, tracking error |
| 3 | $1M+ | 14 legs, some futures | full basket, hedge where no ETF exists | custody, audit, licence |

At every stage the rule is the same: **only promise what the reserve can deliver.** Stage 1 can
promise "redeemable for the ETF value we hold". It cannot promise index returns it has not hedged —
and the pro-rata rule is the contract's way of admitting that.

---

## 7. What this means for the next commit

Nothing in this document is a code change except one:

- **a treasury fee line** in `_routeFees` (owner-settable rate, bounded). Everything else is entity,
  broker, and custody work — and the contract already has the hooks (`reserveAttestation`,
  `isSolvent`, `setLimits`).

The decision this document asks for is not technical: **is PLT an investment product (needs a fund
wrapper, custody, and probably a licence) or a purchasing-power unit (needs no yield promises, and the
reserve is a backstop)?** Stage 1 works for the second. Stage 2 is required for the first, and Stage 2
is a company, not a commit.
