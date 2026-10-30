# Self-audit — adversarial testing, not a review

2026-10-30. The team decided to audit internally and launch without a third-party firm. This document
records what "self-audit" actually means here, so nobody later mistakes it for one.

**It is not an audit.** It is: two manual adversarial reviews, 900 randomised state-transition steps
with invariants checked after every step, 12 guard tests, and 5 adversarial scenarios. That is a
stronger bar than reading the code, and a weaker bar than an independent firm with no stake in it.

---

## 1. Method

| Layer | What it does | Result |
|---|---|---|
| Manual review A | contract-level: accounting, access, parameters | 1 bug, 3 gaps — all fixed |
| Manual review B | perp-engineer lens: oracle path, keeper economics, margin sanity | 5 findings (1 critical) — all fixed |
| **Fuzz (seed 1337, 400 steps)** | 5 actors, random deposit/withdraw/open/close/liquidate/price/time | invariants held |
| **Fuzz (seed 7, 500 steps)** | same | invariants held |
| Guard suite | 12 targeted assertions | all pass |
| Adversarial suite | donation, replay, griefing, closed relayer path | all pass |

### The invariants, checked on-chain after EVERY fuzz step

```
I1  usdc.balanceOf(perp) == totalCollateral + poolAssets
I2  Σ position.collateral == totalCollateral
I3  Σ position.size      == netSize
I4  traders[] and positions[].open agree in both directions
I5  no underflow in poolAssets / totalShares / totalCollateral (uints revert)
```

These are the invariants that, if broken, mean someone can take money that is not theirs. A fuzz run
that never violates them is evidence; prose that says "the accounting is correct" is not.

## 2. What the adversarial suite proved

| Attack | Result |
|---|---|
| Donate USDC directly to the pool to inflate the share price | **No effect** — `sharePrice` stayed 1.000000. The pool prices off `poolAssets` (storage), never `balanceOf` |
| Donate and then withdraw | The donation stays orphaned in the contract; it is not counted and cannot be withdrawn. Value destroyed, not stolen |
| Replay a signed price payload | **Rejected** — `timestamp > lastOracleUpdate` is strictly enforced |
| Liquidate a healthy 2× position | **Rejected** — `NotLiquidatable` |
| Push a price with the deploy key after `relayer` is zeroed | **Rejected** — only the 2-of-3 signed path remains |
| Open at 10× while the feed is frozen | **Rejected** |
| Open at 10× while the feed is in caution | **Rejected** (max 5×) |
| Withdraw while open interest exceeds the pool multiple | **Rejected** |
| Keeper claims a position with equity ≤ 0 | Pays the keeper, so it actually happens (this was the bug that made bad debt permanent) |

## 3. Findings from the self-audit, all fixed

| # | Severity | Finding |
|---|---|---|
| 1 | Critical | The perp priced off `PlanetCore.currentPpi`, which the single-key `updatePrice` writes as readily as the 2-of-3 `updatePriceSigned`. The oracle work protected nothing that settled money. **Fixed:** the price source refuses a core with an active relayer |
| 2 | High | `riskLevel()` underflowed and reverted for two minutes after every push (the signer publishes `now + 120`), bricking open and liquidate |
| 3 | High | Keepers earned zero on negative-equity positions — exactly the ones that must be closed |
| 4 | High | No decimals check: an 18-decimal collateral token would be off by 1e12 and look fine until the first close |
| 5 | Medium | Liquidation ignored `riskLevel` — a frozen feed could liquidate a borderline position at a stale price |
| 6 | Medium | LPs could withdraw the whole pool while positions were open |
| 7 | Medium | Maintenance margin could be set above the initial margin, making every position instantly liquidatable |
| 8 | Medium | A two-hour-old commodity print was tradable against the pool (now 30 min) |
| 9 | Medium | Every fee went to the pool; the platform earned nothing |

## 4. What this self-audit CANNOT catch

1. **Author blindness.** Every finding above was found by the person who wrote the code, in a
   different frame of mind. That is not the same as a stranger trying to break it.
2. **Economic design risk.** A fuzz harness cannot tell you that the pool is structurally short
   commodities with no hedge, or that LP exit interacts badly with unrealised PnL.
3. **Operational risk.** Key custody, deployment mistakes, RPC failure during a liquidation cascade.
4. **Composability.** What happens when the index is consumed by a venue with its own risk engine.

## 5. Conditions for a limited launch

If this ships without an external audit, these are the conditions that make it defensible rather than
reckless:

1. **Hard caps on day one**: pool ≤ $10,000, open interest ≤ $5,000, max leverage 3×. Raise only after
   a month without incident.
2. **Timelock the perp owner** before any deposit. Today it is an EOA that can repoint the price
   source. This is non-negotiable.
3. **Two people, two keys.** The 2-of-3 signer set must contain keys held by different people, or it
   is a one-person system wearing a multisig costume.
4. **A pause switch reachable in minutes**, plus monitoring that alerts on the invariant and on
   `riskLevel` transitions.
5. **Public disclosure**: the self-audit document, the known-issues list, and a line that says no
   external audit exists.
6. **A written exit plan**: how LPs get out if the market is paused.

Without 2, 4 and 5 a launch is not defensible. With them, a capped beta is a risk the operator can
choose to take knowingly.

---

*This document exists so that the decision to launch without an audit is recorded as a decision, with
its conditions, and not as an oversight.*
