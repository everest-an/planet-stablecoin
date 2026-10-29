# PPIPerp MVP — the pool is the counterparty

2026-10-29. First implementation of the contract layer: a perpetual market on the PPI index where
**the LP pool takes the other side and the platform only rakes**. Written because the alternative
framing ("we are the counterparty") is a different, much riskier business; see
`docs/index-as-a-product-2026-10.md` §8.

## What exists

| File | What it is |
|---|---|
| `monad/src/perp/IPerpPrice.sol` | the seam: `price()` + `riskLevel()`, so the market can be tested with a settable price and deployed against the real index |
| `monad/src/perp/PPIPriceSource.sol` | reads PlanetCore: price = `PPI × usdPerIndex`; riskLevel from staleness (2h caution / 6h frozen) and the worst per-asset `riskState` |
| `monad/src/perp/PPIPerp.sol` | pool + single-market perp: deposit/withdraw shares, open/close, funding, liquidation, riskState-gated margin |
| `monad/test-mocks/Mocks.sol` | **test only** settable price + 6-decimal mock USDC |

## The accounting, stated plainly

```
contract balance == totalCollateral (trader margin) + poolAssets (LP capital)
```

Every settlement writes `poolAssets = poolAssets + collateral - payout`, which keeps that invariant
true by construction instead of by arithmetic coincidence. If the pool cannot pay a winner, the payout
is capped and `PoolShortfall` is emitted — the alternative (reverting) would trap every trader behind
an insolvent pool.

Revenue to the platform (in this contract, to the pool; a fee split can be added later):
open fee 0.10%, close fee 0.10%, funding that longs pay when the pool is net short, and half of a
liquidated position's remaining equity (the keeper takes the other half).

## Test results — real EVM (hardhat), not mocks of the math

| Test | Result |
|---|---|
| long 5000, price +5% | equity 1245 (= 1000 − 5 fee + 250 pnl), payout 1240 ✅ |
| short 5000, price −5% | payout 1240 ✅ |
| 10x long, price −15% | equity −510 < maintenance 500 → liquidated ✅ |
| riskLevel = 2 (frozen) | new position rejected ✅ |
| riskLevel = 1 (caution) | 10x rejected (max 5x) ✅ |
| invariant | balance == collateral + pool ✅ |
| funding | 5,000 notional × 1e10/s × 1h = 0.18 USD charged, pool receives it ✅ |

A real bug was found by the funding test: `equityOf()` did not include pending funding, so the view
lagged the settlement. Fixed by computing `cumFunding + rate × elapsed` in the view.

## What is NOT done

1. **Not deployed to a public chain.** Sepolia has no ETH in the deployer and the mainnet balance is
   ~0.0001 ETH; the test stack costs more than that. The contracts are compiled and tested locally.
2. **No keeper.** Nothing calls `liquidate` automatically yet.
3. **No front-end.** No UI, no wallet flow.
4. **No audit.** This is the first cut of a market that will hold other people's money; it must not
   be used with real funds before review.
5. **PPIPriceSource is untested against a live core** — the mapping is simple, but "simple and
   unverified" is how the oracle bugs in this repo started.

## Next

```
1. keeper bot (liquidate + funding rate updates)          ← needed before any demo
2. deploy to Sepolia with mock USDC and run the same
   suite against the deployed bytecode                    ← needs Sepolia ETH
3. /perps page with the riskState banner
4. review, then a small mainnet cap
```

## Contract review (self, 2026-10-29)

A deliberate pass over the two contracts found one real bug and three completeness gaps. All are
fixed and covered by tests.

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | **High (bug)** | `PPIPriceSource.riskLevel()` subtracted `last` from `block.timestamp` in uint64. The signer publishes `now + 120`, so for two minutes after every push the subtraction underflowed and **reverted** — bricking `open()` and `liquidate()`. | Future timestamps count as age zero. |
| 2 | High (gap) | `liquidate()` ignored `riskLevel`, so a frozen feed could still liquidate a borderline position at a stale price — the exact cascade the confidence signal exists to prevent. | While frozen, only positions underwater by half the maintenance buffer may be closed. |
| 3 | Medium (gap) | LPs could withdraw the whole pool while positions were open; the payout cap then pushed the shortfall onto traders. | Withdrawal blocked when the pool no longer covers `maxOiToPoolBps` of open interest. |
| 4 | Medium (gap) | Every fee went to the pool; the platform earned nothing, contradicting the stated model. | `treasury` + `protocolShareBps` (30% of open/close fees). |

Also tightened: open interest may not exceed `maxOiToPoolBps` (2x) of the pool, enforced on open and
after a withdrawal.

Tests added and passing: future-timestamp no-revert, price mapping, 3h caution / 7h frozen, asset
caution propagation, 30% protocol fee, OI cap vs pool, withdrawal blocked under open interest, and a
frozen feed protecting a borderline position while still liquidating a deeply underwater one.

### Still open before any real money

1. No external audit.
2. The owner is a plain EOA and can repoint `priceSource`; in production both must sit behind the
   timelock, and the source change should be treated like an oracle upgrade (delay + announcement).
3. Funding is keeper-set within a cap rather than derived from a mark price — honest for a one-sided
   market, but it is discretion, not mechanism.

