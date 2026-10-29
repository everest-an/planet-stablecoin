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

## Second review — perp-engineer pass (2026-10-29)

Reading it the way a perp auditor would, not a contract reviewer. Five more issues, all fixed and
tested.

### 1. Critical: the perp was pricing off the 1-of-1 relayer path

The whole point of the 2-of-3 signed oracle is that no single key can move a price. But `PPIPerp`
reads `PlanetCore.currentPpi`, which `updatePrice` (one relayer key) writes just as happily as
`updatePriceSigned` (2-of-3). A compromised relayer could push a price inside the 50% jump guard and
be liquidated through the pool — the signature work protected nothing that mattered.

Fix: `PPIPriceSource` now **refuses to construct against a core whose `relayer` is not `address(0)`**.
A market that settles money may only consume the signed path. Operational consequence: before
deploying a perp, the core's relayer must be zeroed through the timelock.

### 2. High: keepers earned nothing on the positions that matter

`keeperReward = remaining / 2` where `remaining = max(equity, 0)`. For an underwater position
(equity ≤ 0) the keeper got **zero**, so a rational keeper never liquidates it and the bad debt sits
until the pool is insolvent. The `liqFeeBps` parameter existed but was unused.

Fix: the keeper is paid from the trader's collateral via the liquidation fee, falling back to the
equity share when that is larger, capped at the collateral. Verified: a position at equity −510 now
pays the keeper 4.95 instead of 0.

### 3. High: no decimals check

Every number assumes 6 decimals. Deploying against an 18-decimal token would be off by 1e12 —
and would look fine until the first close. The constructor now requires `decimals() == 6`.

### 4. Medium: maintenance margin could exceed the initial margin

`setParams` allowed maintenance up to 49.99% while 10x leverage implies 10% initial margin. At that
setting every position is liquidatable the instant it opens — a one-call griefing vector for the
key holder. Now enforced: `maintenanceBps × maxLeverageBps < BPS²`.

### 5. Medium: a two-hour-old commodity price was still tradable

`CAUTION_AGE` was 2 hours. For a spot-like index that is defensible; for a perp it is free alpha
against the pool. Tightened to **30 minutes** (6h remains the hard freeze).

Also: the liquidation refactor hit `Stack too deep`, fixed by extracting `_keeperReward` rather than
switching on `viaIR` — the deployed bytecode keeps the same compiler settings as the verified
contracts.

### Open by design (not bugs, but must be said to an LP)

1. **The pool is structurally short commodities with no hedge.** In a sustained inflationary trend it
   bleeds; funding only offsets when traders are net long. This is the LP's actual bet.
2. **No separate insurance fund.** Bad debt lands on LP capital directly.
3. **Withdrawal can be blocked indefinitely** while open interest exceeds the pool multiple — correct
   for solvency, but an LP cannot always exit on demand.
4. **Funding is discretionary** within a cap, not derived from a mark price.


