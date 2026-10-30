# Attack-vector audit — what a real attacker would try

2026-10-30. Checked against the classes that actually drain DeFi protocols, not against a checklist
of academic trivia. Every "exposed" row names the exact path.

## Verdict first

**One live vulnerability was found and is being fixed** (§1). Everything else is either mitigated,
structurally impossible for this design, or a documented trade-off. Nothing here removes the need for
an external audit.

---

## 1. Oracle: the relayer role was still authorised on mainnet — **live, being fixed**

We disabled the hourly *workflow*, not the *role*. `core.relayer` on Arbitrum One was still the
deployer EOA, so one key could call `updatePrice` directly and move the index, **bypassing the 2-of-3
signed oracle that was just wired in**. Once a venue settles against PPI, a single compromised key
could push a false price inside the 50% jump guard and extract value.

- Proposed: `setRelayer(address(0))` through the 6h timelock (tx `0x335af5e5…`), executable 08:29 UTC.
- After it executes, the ONLY write path is `updatePriceSigned`, which needs two of three keys.
- The perp's price source already refuses to construct against a core with an active relayer, so this
  cannot be forgotten at deployment.

## 2. Oracle: stale-price trading

| Attack | Status |
|---|---|
| Open at a price older than 30 minutes | Blocked: `riskLevel` returns caution, margin requirement doubles |
| Open at a price older than 6 hours | Blocked: frozen, open reverts |
| **Close at a frozen price** | **Allowed by design** — users must be able to exit. Bounded by the 6h window and the 50% guard; documented, not fixed |

## 3. Signature replay

The digest binds `DOMAIN, oracle address, chainid, consumer, index, price, volatility, liquidity,
riskState, timestamp`. Consequences:

- A payload signed for the Sepolia core cannot be replayed on mainnet (consumer + chainid differ).
- A payload cannot be replayed onto a different oracle deployment (address in the digest).
- Re-submitting an old payload reverts: `_applyPrice` requires `timestamp > lastOracleUpdate`, and
  `lastOracleUpdate` is global and strictly increasing.
- Malleable signatures rejected (`s > N/2`), `v` must be 27/28, duplicate signers count once.

## 4. Reentrancy

Every mutating perp function is behind a mutex; the core's `mint`/`redeem` likewise. Collateral is
USDC (no transfer hooks); the mock is a plain ERC-20. No callback surface exists.

## 5. Flash loans, donation attacks, share inflation

- The index is oracle-fed, not AMM-derived, so a flash loan cannot move it.
- `sharePrice` and deposits read `poolAssets` (storage), never `balanceOf` — sending tokens directly
  to the contract does not move the share price. The classic first-depositor inflation attack does not
  apply.
- Rounding in deposit/withdraw favours the pool.

## 6. Access control — the remaining structural risk

| Power | Holder | Risk |
|---|---|---|
| `setPriceSource` (perp) | owner **EOA** | **Critical if the perp is ever deployed with real money**: a hostile source drains the pool. Must sit behind a timelock before any mainnet listing. |
| `setParams`, `setTreasury`, `setProtocolShare` | owner EOA | Bounded (leverage ≥1x, maintenance < 1/leverage, protocol share ≤50%) |
| `setFundingRate` | keeper, bounded ±1e12/s | A malicious keeper can annoy, not drain |
| Core admin | 6h timelock | Timelock's own owner is an EOA — a delay, not a defence against a compromised key |
| Liquidate | anyone | Intended |

## 7. Liquidation

- Keeper is paid from the trader's collateral even when equity ≤ 0 (this was a real bug; a keeper that
  earns nothing does not liquidate the positions that matter).
- While the feed is frozen, only positions underwater by half the maintenance buffer can be closed —
  no bad-print cascade.
- **Griefing/cap**: the keeper scans at most 500 accounts. More than 500 concurrent positions means
  some are never scanned; the cost of opening that many (gas + fee each) is the only barrier.

## 8. Economic attacks

| Attack | Status |
|---|---|
| LP withdraws before a large trader payout | Partly guarded: withdrawal is blocked when remaining pool < 2× open interest. **Not** guarded against unrealised PnL — an LP can still exit before a known loss lands, pushing the shortfall onto traders via the payout cap |
| Trader front-runs a price update | Inherent to a pull oracle on a sequenced chain; the pool is the loser. Mitigation is operational (submit and trade atomically), not contractual |
| Funding rate extraction | Bounded ±0.086%/day at the cap; a keeper flipping the sign repeatedly extracts only what the bound allows |

## 9. Denial of service

- `riskLevel()` loops the basket (14 external staticcalls) on every open/liquidate — ~70k extra gas,
  acceptable, and bounded by the basket size.
- `computePpi()` in the core loops the basket on every price update and every `currentPpi` read.
- No unbounded loops over user-supplied arrays in any state-changing function.

## 10. Upgradeability

Neither the core, the token, the timelock, the oracle nor the perp is a proxy. A bug cannot be patched
in place — only replaced. That is the honest trade: no upgrade key to steal, no upgrade to save you.

## 11. What is NOT covered by any of the above

1. **No external audit.** Self-review has the blindness of the author.
2. **Governance keys are one person.** Two signer keys live in Vercel and GitHub, both held by the same
   operator. 2-of-3 protects against a single key leak, not against the operator.
3. **The perp is Sepolia-only and holds no real value.** The index is live on mainnet but has no
   consumer, so it drifts stale by design.

---

## Changes made because of this pass

1. Proposed `setRelayer(0)` on mainnet (removes the 1-of-1 price path).
2. Nothing else required a code change; the remaining items are deployment conditions:
   timelock the perp owner, audit before real money, and either constrain LP exits or disclose the
   unrealised-PnL race.
