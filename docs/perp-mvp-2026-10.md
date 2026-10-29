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
