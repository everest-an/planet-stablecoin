# Launch runbook — limited beta, and how LPs get out

2026-10-30. Written because a launch without an exit plan is a trap, and because the mainnet perp
cannot be deployed until `core.relayer == 0` (08:29 UTC), which the price source enforces in code.

## 1. Configuration (day one)

| Parameter | Value | Why |
|---|---|---|
| Collateral | USDC on Arbitrum One (`0xaf88…5831`) | the only asset a real user holds |
| Max leverage | **3×** | a 33% adverse move empties a position; the pool survives |
| Maintenance margin | 10% of notional | below 1/leverage, enforced by the contract |
| Open / close fee | 0.10% | the platform's cut is 30% of it |
| Protocol share | 30% | the rake; the rest accrues to LPs |
| Max open interest | **$5,000** | hard cap, independent of pool size |
| OI / pool multiple | **2×** | exposure can never exceed twice the LP capital |
| Oracle | 2-of-3 signed pull feed | the single-key path is closed |
| Owner | a dedicated 6h timelock | `setParams` needs propose → wait → execute |

**Pool target: $1,000–$5,000 of LP capital.** At 2× OI, a $2,000 pool supports $4,000 of notional — a
real market at a size where a total loss is survivable.

## 2. Deployment order

```
1. core.relayer == 0                        ← enforced; the price source refuses otherwise
2. deploy PlanetTimelock(owner, delay)      ← delay 6h for production, shorter only for a rehearsal
3. deploy PPIPriceSource(core, usdPerIndex=1000)
4. deploy PPIPerp(USDC, priceSource, owner=timelock)
5. propose setParams / setTreasury / setMaxOiToPool / setMaxOpenInterest*   ← owner = timelock
6. wait delay, execute, verify parameters on chain
7. LP deposits; first position opened by someone other than the deployer
```

*`maxOpenInterest` is a state variable but has no setter; it is fixed at its default of $1m. The
effective cap is `maxOiToPoolBps`, which is settable and does the real work at this size.

## 3. The exit plan (what happens if something breaks)

The perp has **no upgrade path**. "Exit" therefore means: stop new risk, let everyone close, let LPs
withdraw, then abandon or redeploy.

**Trigger conditions** (any one):
- the hourly monitor reports an invariant break;
- two consecutive liquidation failures on a position that is under maintenance;
- the oracle has been frozen for more than 48 hours;
- a disclosed vulnerability is found.

**Sequence, in order, by the owner through the timelock:**

1. **`setPaused(true)`** — this blocks `open` only. `close` and `liquidate` keep working. This is the
   single most important switch: it stops new exposure while leaving every exit open.
2. **Announce** in the same channel the market was announced, with the reason and the expected next
   step.
3. **Let positions close.** With new risk stopped, traders close (or get liquidated normally). The
   market is close-only until open interest reaches zero.
4. **Freeze the funding rate to zero** (`setFundingRate(0)`) so nobody bleeds while unwinding.
5. **LPs withdraw** once `netSize == 0`. The withdrawal guard allows it at that point; before it, the
   guard exists precisely to stop LPs leaving traders unpaid.
6. **If the pool is insolvent** (a losing position exceeded the pool): the payout cap means the last
   winners take a haircut, and that fact is published with the numbers. There is no insurance fund —
   that is a known limitation, and it is why the caps are small.

**If the owner key is compromised:** the timelock delay is the only defence. That is why the owner must
be a timelock and why the delay should be raised as the pool grows.

**If the oracle stops:** the market freezes by itself after 6h (close-only). Exits remain, entries
stop. That is the intended behaviour, not an incident.

## 4. What is watched daily for the first 30 days

- hourly invariant monitor (balance == collateral + pool, sums agree, exposure inside the multiple)
- `riskLevel` transitions and how long the index spends frozen
- every liquidation: was the keeper paid, was the position actually underwater, did the pool take a loss
- LP share price: a drawdown larger than 10% in a week is a signal to stop and look

## 5. Day-one disclosure (on /perps, above the trade panel)

> Limited beta. Pool capped at $5k, open interest at $5k, 3× leverage. Contracts are self-audited, not
> externally audited. The index is a price reference, not a redeemable basket. If the market pauses,
> positions can still be closed and LPs can withdraw once open interest is zero.
