# Comprehensive attack-matrix audit — 2026-10-31

Scope: PlanetCore, PlanetToken, PlanetTimelock, SignedPriceOracle, PPIPerp (v2), PPIPriceSource (v2).
Method: every known attack form below was traced through the actual source (current `contracts/src/`),
line by line. Verdicts: SAFE (code prevents it), MITIGATED (bounded or gated), FINDING (needs work),
NA (does not apply to this design). Findings at the end with severity and fixes.

## 1. Reentrancy

| Surface | Trace | Verdict |
|---|---|---|
| PPIPerp deposit/withdraw/open/close/liquidate | `nonReentrant` lock on all five; state written before the final transfer; USDC has no hooks | SAFE |
| open() → `_takeProtocolFee` mid-function | external `usdc.transfer(treasury)` before the position write, but inside the lock | SAFE |
| PlanetCore mint/redeem | `nonReentrant` + collateral pulled before state changes | SAFE |
| PlanetTimelock execute | pending state cleared BEFORE `dest.call(body)` | SAFE |
| SignedPriceOracle | stateless, view-only verify | NA |

## 2. Oracle manipulation

| Surface | Trace | Verdict |
|---|---|---|
| Single-key price move | PPIPriceSource constructor REJECTS a core with `relayer != 0`; mainnet relayer is locked to address(0) | SAFE |
| Compromised 2-of-3 signer subset | threshold 2 means one key cannot move the price | SAFE |
| Bad print (honest signer bug) | jump guard (50%/tx), frozen-feed liquidation guard, TWAP liquidation gate | MITIGATED |
| Wick + TWAP wash-out | **snapshot() had no rate limit: 8 rapid snapshots after a bad print would fill the ring with the wick and neutralize the TWAP gate. FIXED this audit: SNAPSHOT_MIN_INTERVAL = 30 minutes** | FIXED |
| Signature replay | core requires strictly-increasing `timestamp`; digest binds core+oracle+chainid | SAFE |
| Signature malleability | EIP-2: `s > N/2` rejected; v∈{27,28}; ecrecover zero-address rejected | SAFE |
| Duplicate signer counted twice | used-signer bitmap: one key = one vote | SAFE |
| Cross-chain replay | digest binds `block.chainid` | SAFE |
| Replay onto another core | digest binds `consumer` | SAFE |
| Future timestamp DoS | push with ts = now+120 makes later pushes revert until catch-up; only signers can produce payloads; age treats future as 0 (no underflow) | MITIGATED |
| Owner forcePrice | jump guard bypass exists by design (dead-feed rescue); forces CAUTION, halves perp leverage; behind timelock | MITIGATED |
| Frozen-weight renormalisation | frozenWeightCap = 40% — owner cannot freeze the basket down to one commodity | SAFE |
| Full pause stops price updates | `_applyPrice` reverts when both mints and redeems are paused → perp freezes honestly (risk 2) | MITIGATED |

## 3. Front-running / MEV

| Surface | Trace | Verdict |
|---|---|---|
| Mint/redeem against a pending price push | fee curve is continuous (no step at 3%/5% boundary), so a nudge cannot reprice everyone; mint gated on stalest asset | MITIGATED |
| Perp entry price front-run | entry reads `price()` in the same tx as the collateral pull; the signer batch cadence (5h) bounds the window | MITIGATED |
| Funding backdating | `setFundingRate` accrues at the OLD rate up to now, then switches — no retroactive application | SAFE |
| Liquidation front-run (keeper race) | liquidation is permissionless; the reward is capped at the collateral, so races only split the fee | SAFE |

## 4. Flash loans / same-block abuse

| Surface | Trace | Verdict |
|---|---|---|
| Flash-loan mint-redeem round trip | costs ≥ 50bps each way; band reject at >15% deviation; no leverage on the core | SAFE |
| Flash-loan LP deposit-withdraw | shares mint at current ratio, burned at the same ratio in the same block — no price move between them | SAFE |
| Flash-loan trader open-close | fees both ways + funding accrued per block; no oracle move inside a block unless the signer pushes | MITIGATED |

## 5. Precision / rounding

| Surface | Trace | Verdict |
|---|---|---|
| PPIPerp price scale | price = PPI(1e6) × usdPerIndex(1e3) × 1e12 = $1000 in 1e18 units; pnl is scale-invariant (ratio) | SAFE |
| Share rounding | standard pro-rata; dust shares cannot be withdrawn (0-asset revert) | MITIGATED |
| PlanetCore uint64 downcasts | explicit `> type(uint64).max` checks before casting (mint, redeem) | SAFE |
| Checked arithmetic | solidity 0.8 checked math everywhere; the one known underflow (future oracle ts) is guarded | SAFE |

## 6. Access control

| Surface | Trace | Verdict |
|---|---|---|
| Perp owner | timelock from first block; all admin calls `onlyOwner` | SAFE |
| Guardian | one-way pause only; cannot resume, cannot touch any other state | SAFE |
| Keeper | only `setFundingRate` (bounded ±8%/day) + permissionless liquidate (anyone) | SAFE |
| Timelock TL-1 | ownership change only via the timelock itself | SAFE |
| **Timelock admin is the EOA** | `setDelay` can drop 6h→1s instantly; the "reaction window" is illusory against the key holder | FINDING F1 |
| `setDepositToken` / `setToken` mutable post-mint | changing the token after supply exists strands the reserve and breaks redemptions | FINDING F2 |

## 7. DoS / griefing

| Surface | Trace | Verdict |
|---|---|---|
| traders[] array growth | bounded by OI cap (2x pool, $1m notional) — a few hundred addresses max | SAFE |
| snapshot() spam | rate-limited now (30 min); even before, it could only copy the honest price | SAFE |
| liquidate() spam on healthy positions | reverts; caller pays gas | SAFE |
| withdraw blocked by OI | by design (capital stays behind open interest); the check reverts atomically | MITIGATED |
| Keeper reward griefing | `minPayout` parameter lets the keeper refuse dust liquidations | SAFE |
| Timelock proposal replacement | one pending at a time; a malicious owner can cancel+re-propose but the delay restarts | MITIGATED |

## 8. Insolvency paths

| Surface | Trace | Verdict |
|---|---|---|
| Trader wins > pool | close() caps payout at poolAssets + PoolShortfall event — no revert trap, loss socialised honestly | MITIGATED |
| LP withdraw drains capital behind OI | `PoolInsolvent` revert when OI > 2x pool after withdraw | SAFE |
| Liquidation when pool empty | collateral flows INTO poolAssets; keeper paid from collateral, never the pool | SAFE |
| Negative-equity positions | keeper paid from collateral via liqFee, so underwater positions still get liquidated | SAFE |
| PlanetCore reserve vs balance | `isSolvent()` compares balance to totalReserve; redeem pro-rata branch caps payout at reserve; fee never makes payout negative (MAX_BURN_FEE_BPS) | SAFE |
| PPIPerp donation | donations raise balance but not poolAssets — no share-price inflation (adversarial test: 1→1) | SAFE |
| PlanetCore donation | donations do not inflate totalReserve | SAFE |

## 9. Governance / configuration

| Surface | Trace | Verdict |
|---|---|---|
| Params impossible to make every position insta-liquidatable | `maintenanceBps × maxLeverageBps < BPS²` enforced | SAFE |
| Protocol share cap | ≤ 50% | SAFE |
| OI/pool cap range | 20%–1000% | SAFE |
| Fee caps | open/close ≤ 1% | SAFE |
| Funding cap | ±8%/day — a compromised keeper cannot drain through funding | SAFE |
| Oracle signer set rotation | owner (timelock) only | SAFE |

## Findings

### F1 — Timelock admin functions bypass the delay (MEDIUM)
`setDelay`, `setGracePeriod`, `setOwner` are callable by the timelock's EOA owner directly. The delay
can be dropped to 1 second and a malicious proposal executed 1 second later — the 6h window is a
promise the key holder can withdraw at any time. This matters only in the key-compromise scenario,
which is exactly the scenario the timelock exists for.
**Fix:** deploy a timelock whose admin IS itself (execute() public, ownership transferred to the
timelock via one proposal). Requires a new timelock + ownership handover of core and perp — queue it
before real money, it is already scoped in the roadmap.

### F2 — depositToken / token mutable after mints exist (LOW)
Owner (timelock) can re-point the collateral or the token after supply exists, stranding the old
collateral and breaking the reserve accounting. USDC/PLT are fixed on mainnet today, so this is a
governance discipline issue, not an exploitable path. **Fix:** one-way latches (like baseLocked) if
the token is ever to be upgraded, or document as "never change".

### F3 — Full pause also stops price updates (INFO)
`_applyPrice` reverts when both directions are paused. In an incident the owner freezes the market
AND the feed, and the perp goes risk-2 (close-only). That is the honest failure mode and the
monitors alert on it — but the operator must know that "pause" is a two-for-one switch. Documented,
not changed.

## What the fuzz/guard suites already prove (reproducible in contracts/)

- guards-test: 12/12 (fee share, OI cap, withdraw guard, frozen-feed liquidation, price source)
- fuzz-perp: 900-step seeds replayed — balance == collateral + pool after EVERY step, invariants held
- adversarial: 5/5 (donation, invariant breach detection, replay rejection, healthy-liq rejection, relayer closure)
- twap-guardian: 12/12 (guardian one-way, TWAP gate both directions)

## Bottom line

The attack surface is closed for everything a third party can do without keys. The residual risks are
all key-holder scenarios (F1, F2) and the honest structural limits of a pull-oracle index. No
new third-party exploitability was found in this pass; F1 is the one to fix before real money.
