# Peer review — what five comparable protocols do that we do not

Researched 2026-10-27. Sources are the projects' own docs plus one audit report; each claim below is
attributed rather than generalised.

The point of this pass was not "what do stablecoins usually have", but "what do the projects that
tried *this specific thing* have, that we are missing".

---

## The five

1. **Frax FPI** — a stablecoin pegged to the US CPI basket. The closest analogue to PLT: an index
   token whose unit is a basket, not a currency.
2. **Trusset Commodity Token** — ERC-20 backed by physical commodity reserves, MiCA-oriented.
3. **Shade SILK** — basket of global currencies *and* commodities on Secret Network.
4. **mStable** — 1:1 basket of same-peg assets, audited by ConsenSys Diligence.
5. **Universal Peg Framework** — a written spec for peg modules (redemption + oracle), useful as a
   checklist rather than a product.

---

## What they have, and where we stand

| Concern | FPI | Trusset | SILK | mStable | **Planet today** |
|---|---|---|---|---|---|
| Collateral ratio checked on-chain | 100% CR target, enforced via AMOs | `totalSupply × gramsPerToken ≤ totalGramsReserve` on every mint | over-collateralised mint | 1:1 basket | **counter only, never compared to the balance** |
| Reserve is productive | **yes — AMOs must earn ≥ CPI, or it sells its governance token to restore CR** | n/a (physical) | staking + bonds | deposits into Aave/Compound | **idle USDC** |
| Mint cap | `fpi_mint_cap` | per-address sub-issuer limits | — | — | **none** |
| Separate pause for mint vs redeem | `mints_paused`, `redeems_paused` | request modes | — | — | **one `paused` flag** |
| Redemption price | **accrues per second** from the CPI rate, refreshed monthly | oracle price | oracle | peg oracle | **discrete hourly push** |
| In-kind redemption | no (returns FRAX) | **physical delivery or cash** | — | basket assets | **no** |
| Reserve attestation on-chain | — | **attestation URI + vault hash, `isReserveCompliant()`** | — | — | **nothing** |
| KYC / transfer restrictions | no | **identity registry + compliance modules** | — | — | **no** |
| Oracle shape | Chainlink CPI, monthly | **one oracle per token, `maxOracleAge` 1h, monitor compliance off-chain** | — | peg feed | 4 channels, 0.5% confirmation, global 6h constant |
| Deficit / recapitalisation | governance token absorbs it | issuer | bonds | — | **nothing** |

---

## The finding that changes our plan

**FPI answers the exact problem F-14 describes, and it does not answer it with a better redemption
rule.** Its docs say: to hold a 100% collateral ratio, the balance sheet must grow at least at the
CPI rate, so the **AMO strategies must earn a yield proportional to CPI** — and when they earn less,
the protocol sells its governance token (FPIS) into a TWAMM to restore the ratio.

Translated: **the reserve has to earn what the liability owes.** Our liability grows with a commodity
index; our reserve earns nothing. That is not a redemption-mechanics bug, it is a missing yield leg.

We already added the honest fallback (pro-rata when the reserve cannot pay). FPI adds the thing that
makes the fallback rarely needed. The two are complementary, and together they are a coherent story:

> the reserve is deployed to earn, pro-rata is the backstop when earning is not enough, and the
> shortfall is visible rather than hidden in a revert.

---

## As a stablecoin specialist, having read these

1. **The reserve must be productive** (FPI). Idle USDC against an index liability loses the race by
   construction. This is the single biggest correction to our Stage 1.
2. **A hard collateral-ratio check on mint** (Trusset). Ours only compares a counter to itself.
3. **A mint cap** (FPI). Without one, one wallet can define the whole supply.
4. **Separate pause flags** (FPI). One `paused` means an oracle incident also stops redemptions.
5. **A deficit owner** (FPI's FPIS, SILK's bonds). Someone must absorb the shortfall by contract, or
   the last holder does. Pro-rata is fair but it is not a recapitalisation.
6. **Redemption in kind** (Trusset) — the difference between "tracks a basket" and "is a claim on a
   basket". Stage 2 in our own paper.

## As a blockchain engineer

1. **Per-asset oracle instance with its own `maxOracleAge`** (Trusset). Our 6h is one constant for
   fourteen instruments with very different liquidity.
2. **Compliance checked as a view, monitored off-chain** — `isReserveCompliant()` is a callable
   predicate, not an assertion buried in a transfer path. We have no such predicate; the monitor
   re-derives it externally, which is the same thing but less discoverable.
3. **Fees/limits as tunable state, not constants** — FPI's mint fee, caps and pause flags are all
   governance-settable. Ours are `constant`, so every policy change is a redeploy (we have done six).
4. **Request modes** (Trusset: INSTANT / MANUAL_APPROVAL / TIMELOCK / CONDITIONAL). A commodity token
   that can only mint instantly cannot ever serve a real issuer.
5. **Attestation pointer on-chain** — a URI plus an auditor identity is cheap and turns "trust us"
   into "here is the document".

## As the project owner

1. **A named counterparty for the shortfall.** FPI has FPIS. SILK has bonds. We have "pro-rata" and
   then nothing. An investor will ask who eats the loss; today the answer is "the last holder".
2. **A yield leg is also an answer to "why does this need capital".** Deploying the reserve is a
   concrete, auditable use of funds, unlike "marketing".
3. **KYC is a fork in the road, not a feature.** Trusset built MiCA compliance into the token. We
   built none, which is fine for a testnet PoC and disqualifying for an issuer partnership — decide
   which side we intend to be on before someone asks.
4. **Redemption terms** — the Universal Peg Framework lists eligibility, ratio, fees, minimum,
   settlement procedure, limits and emergency restrictions as the seven things a redemption spec must
   state. Ours states three of them.
5. **Oracle provenance** — the soybean blueprint publishes source URLs, timestamps and confidence
   intervals with every price. Our `/api/v1/sources` does this for the *reading*; nothing links a
   pushed on-chain price to its provenance.

---

## How to fold this in

The earlier plan (T0–T3) still holds; this pass changes two entries and adds one.

**T1 — economic model (unchanged in shape, changed in content)**
- ~~"decide hold / hedge / rename"~~ → **add a yield leg.** The decision is not only what the reserve
  *holds*, but that it *earns*. Options: T-bill wrapper, lending market, hedged futures basis. Any of
  them narrows the gap between a commodity-index liability and a dollar reserve. FPI's evidence is
  that without this the ratio decays by construction.
- Keep pro-rata as the backstop. It is the honest floor, not the plan.

**T2 — one redeploy, accumulated (additions marked ★)**
- F-13 fee sinks (or delete the labels)
- F-15 continuous fee curve
- F-16 digest binds the core
- F-17 proposal expiry
- F-18 on-chain solvency predicate (`isReserveCompliant()`-style, callable and cheap)
- F-19 max frozen weight
- ★ **mint cap** (supply and per-tx)
- ★ **`mintsPaused` / `redeemsPaused` split**
- ★ **fees/caps as settable state with timelock bounds**, so policy stops requiring redeploys
- ★ **attestation URI slot** (owner-settable string, emitted on change)

**T3 — operations**
- Multisig, key separation, bug bounty, runbook — plus ★ **a named shortfall counterparty** before any
  real money is involved.

---

## Two findings that soften our own review

**F-7 (redemption reverts beyond a 15% deviation) is not unusual.** FPI's controller calls
`require(within_range, "Peg band [Redeem]")` before it will redeem, so a live index stablecoin also
blocks redemptions outside its band. What FPI has that we do not is a **separate `redeems_paused`**,
so an oracle incident and a policy pause are different switches. The band is standard; the absence
of a second switch is ours.

**mStable validates at the entry point, not inside the pricing function.** Its audited design routes
mint and redeem through a `ForgeValidator` that runs every check in one place. Our checks are spread
across `feeBpsForPpi` (which reverts), `redeem` (staleness, supply, reserve) and `mint` (staleness,
collateral). The behaviour is roughly equivalent, but "why did this call fail" takes three files to
answer, and an auditor will say so.

**Not now:** KYC/transfer restrictions and in-kind redemption. Both are Stage 2/3 and both would
change the token contract's shape; adding them later is a migration, so the *decision* should be made
before the audit even if the code comes after.
