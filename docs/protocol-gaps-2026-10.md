# Protocol gaps — a second pass, from three angles

Follow-up to `security-review-2026-10.md`. That pass looked for ways to *steal*. This one looks at
what happens when nobody is attacking: what the system does over a year, and what a stablecoin
protocol is expected to have that this one does not.

Everything below is grounded in the deployed source. Numbers marked "measured" were read from the
live contract.

---

# Part A — additional audit findings

### F-13 — HIGH — the fee split is a label for half of it; nothing ever burns or distributes

`feesToBurn`, `feesToReserve` and `feesToStaking` are counters that are only ever incremented:

```
L416  feesToBurn    += burn;
L417  feesToReserve += reserve;
L418  feesToStaking += stake;
```

There is no burn call, no transfer to a staking contract, no sweep. Only `riskFund` has a sink
(`coverDeficit`).

**Consequence:** the documented 30 / 40 / 20 / 10 split is a bookkeeping entry for 50% of it. Supply
is not deflationary as §10.2 implies — the "burned" 30% is USDC sitting in the same contract balance
labelled "burn". A reader who believes the tokenomics is being told something that does not happen.

### F-14 — HIGH — structurally short the index; redemptions are first-come-first-served

The reserve holds **USDC**. The liability is **an index of commodity prices**. If the index rises 20%,
every PLT is worth 1.2× what it was, and the reserve still holds the original dollars:

```
redeem() → if (totalReserve < payout) revert Underflow();
```

So in a rising market the early redeemers are paid in full and the rest get a revert. The protocol
has no commodity exposure, no hedge, and no queue. This is not a code defect that a patch removes —
it is the absence of a backing model, and it is the largest single thing standing between this and
anything calling itself a stablecoin.

### F-15 — MEDIUM — fee schedule has two cliffs, both reachable

Measured on the live `feeBpsForPpi`:

| index deviation | fee |
|---|---|
| 4.99% | 100 bps |
| 5.00% | 100 bps |
| 5.01% | **201 bps** |
| 14.90% | 1190 bps |
| 15.00% | **1200 bps** |
| 15.01% | **revert BandReject** |

A 0.02% move at the 5% boundary doubles the fee. A 0.01% move at the 15% boundary takes the system
from "expensive" to "minting and redemption both impossible". Whoever can nudge the index across a
boundary — and the owner can, via weights or a forced price — controls everyone else's fees and
whether they can exit at all.

### F-16 — MEDIUM — the signed-oracle digest does not bind the consuming core

`SignedPriceOracle.digest` binds `DOMAIN ‖ address(this) ‖ block.chainid ‖ payload`. It does **not**
bind the core that will consume the price. Two cores pointed at the same oracle accept the same
signed payload; each one's own monotonic timestamp allows it. The core address belongs in the digest.

### F-17 — MEDIUM — timelock proposals never expire

`propose` sets `eta = now + delay` and nothing else. A proposal can sit for a year and be executed at
a moment nobody is watching. A grace window (execute within N days) is standard and missing.

### F-18 — MEDIUM — no on-chain solvency invariant

The core declares `balanceOf` in its `IERC20` interface and **never calls it**. `totalReserve` is a
counter, not a fact. Two ways this bites:

- A fee-on-transfer or rebasing deposit token: `transferFrom` delivers less than `deposit`, the
  counter is credited the full amount, and the reserve silently overstates.
- Nothing prevents a future `sweep`-style function (or a token upgrade) from making the counter lie.

The invariant `depositToken.balanceOf(core) >= totalReserve` should be checkable on-chain, and
monitored off-chain today.

### F-19 — LOW — `setAsset` can re-weight the basket without limit

Base prices are locked, weights are not. With a 60-second delay an owner can shift weight toward
whichever commodity just moved, changing the index both for existing holders and for the fee band.

### F-20 — LOW — no per-transaction or per-epoch mint cap

The TON build had a per-tx cap; the EVM core has none. One transaction can mint against any amount of
USDC the caller holds.

### F-21 — INFO — `assets` is unbounded and the index is O(n)

`computePpi` and `weightSum` loop the whole array, and `setAsset` can append. A large basket makes
every price update and every mint progressively more expensive.

---

# Part B — what each specialist would say is missing

## As a stablecoin specialist

1. **Backing model.** Commodity exposure with a dollar reserve is a short. Either hold the basket
   (custody/RWA), hedge it (futures), or stop calling it purchasing power and call it a
   dollar-denominated index tracker.
2. **Attestation.** Reserves attested by a third party, on a schedule, linked from the site.
3. **Redemption discipline.** A queue or pro-rata claim when the reserve is short, instead of a
   revert that rewards whoever was first.
4. **Peg defence that references a market price.** The fee band reacts to *index vs base*, not to
   *market price vs index*. An index is supposed to move; charging more when it does is not a peg
   defence, it is a volatility tax on the product's own core behaviour.
5. **Supply caps and throttles.** Per-tx and per-epoch limits, plus a global cap until the backing
   model exists.
6. **Recapitalisation path.** Who tops up the reserve, with what, and what happens to holders if
   nobody does.
7. **Freeze/blacklist** — only if the product is ever sold as a regulated instrument, and it should
   be stated now which side of that line the project intends to be on.

## As a blockchain engineer

1. **Source verification** — an auditor cannot start without it; it is a submission blocker, not a
   nice-to-have.
2. **Guardian pause.** Right now the only pause is an owner action behind a 60-second timelock. An
   incident needs a role that can pause *immediately* and do nothing else.
3. **Monitoring that actually alerts**: pending timelock proposals, oracle age, reserve vs counter
   mismatch, large mints, channel divergence, price jumps. A workflow that fails silently is not
   monitoring.
4. **Invariant fuzzing.** 72 unit tests prove specific paths. Nothing proves "supply × PPI ≤ reserve
   after any sequence of calls" — that needs a stateful fuzz suite.
5. **Deploy-key hygiene.** One secret can deploy, re-own, and push prices. Split it: a proposer key
   that can only propose, and a separate hot relayer key.
6. **Rate limiting** on `/api/v1/sources`, which fans out ~34 upstream requests per cache miss.
7. **Domain separation across cores** (F-16) and **proposal expiry** (F-17).

## As the project owner

1. **A one-line answer to "what am I buying?"** Today it is: a token whose price tracks a commodity
   index, redeemable for test USDC held by a contract that has no commodity exposure. That is a
   testnet demo, and the site says so — but a fundraise needs the next sentence.
2. **Liquidity plan.** There is no market. Mint and redeem are the only exit, and redeem depends on a
   reserve that is not hedged.
3. **Incident response.** Who pauses, within what time, who speaks publicly, where the post-mortem
   lives. Missing entirely.
4. **Legal wrapper + custodian** before any real collateral. Already stated as out of scope; it stays
   the gate for mainnet.
5. **Bug bounty** once there is anything worth stealing.
6. **Status page / SLA** for the oracle, since the index is the product.

---

# Part C — how to combine it into a sequence

The mistake would be to fix these in the order they are listed above. They have different
dependencies and very different costs.

### T0 — before the next thing you say publicly (days, no contract change)
- Verify source on Arbiscan.
- Monitoring workflow: oracle age, reserve vs counter, pending proposals, large mints.
- Guardian-pause design note (contract change, but specify it before building).
- Correct §10.2 of the whitepaper: the "burn" is a label, not a burn (F-13).

### T1 — the economic model (weeks, mostly design)
- Decide the backing: hold, hedge, or rename the product.
- Redemption queue / pro-rata rule.
- Fee-band redesign: continuous curve, no cliffs, and decide whether the band is a volatility tax or
  a peg defence — it cannot honestly be both.
- Supply caps.

### T2 — contract changes worth batching into one redeploy
- F-13 burn/staking sinks (or delete the labels and say so).
- F-15 continuous fee curve.
- F-16 digest binds the core.
- F-17 proposal expiry.
- F-18 on-chain solvency view.
- F-19 max frozen weight.

### T3 — operations, after the audit
- Multisig as timelock owner; key separation for the relayer.
- Bug bounty, status page, incident runbook.

**The one thing to decide now, because everything else depends on it:** is PLT a claim on a commodity
basket (needs custody or a hedge) or a dollar-denominated index tracker (needs a different name and
different marketing)? F-14 cannot be patched; it has to be chosen.
