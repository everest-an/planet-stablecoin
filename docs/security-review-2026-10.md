# Security review — 2026-10-26

Self-review of the deployed Arbitrum Sepolia stack, performed by the team that wrote it. **This is
not an audit.** A self-review finds the things the author was looking for; the point of paying an
auditor is to find the things they were not.

Scope: `monad/src/*.sol` (PlanetCore, PlanetToken, PlanetTimelock, SignedPriceOracle), the price
pipeline (`relayer/`, `web/api/_channels.js`) and the public read API.

---

## Fixed in this pass

### F-1 — CRITICAL — privileged roles sat on an EOA while the documentation promised a delay

**Evidence (on-chain, before the fix):**

```
core.owner()   = 0x68be…2C13   (deployer EOA)
token.owner()  = 0x68be…2C13   (deployer EOA)
timelock.owner = 0x68be…2C13   delay = 60s
```

The timelock existed and was wired to nothing. Every admin action — `forcePrice`, `setRelayer`,
`setRiskState`, `pause`, `setMinner` — executed instantly with one key.

**Worst case:** `token.owner` calls `setMinter(attacker)`, mints unlimited PLT, points the minter
back at the core, then calls `core.redeem()` and drains the reserve. Two transactions, no delay,
no event a monitor would understand.

**Fix:** `monad/script/Handover.s.sol` moves `core.owner` and `token.owner` to the `PlanetTimelock`;
the deploy workflow gained a `handover` action. Order is deploy → configure → handover, because
basket configuration needs owner rights.

**Deployed:** core.owner and token.owner now both return the timelock address.

**Residual:** the timelock's own owner is still the deployer EOA, so the EOA can propose and, after
60 seconds, execute anything. That is a *delay*, not a defence. Delays are worth exactly as much as
somebody watching them: nothing currently alerts on a pending proposal.

### F-2 — HIGH — `redeem` had no freshness gate

Minting was gated on the oldest active asset (eq. 20) and **redemption was not**. Once the index went
stale, a redeemer was paid at a PPI the market had already left behind. If the true index had fallen,
the stale, higher PPI paid out more than the basket was worth — a direct transfer from the reserve to
whoever redeemed first.

**Fix:** `redeem` now enforces the same `StaleOracle` check against `oldestActiveUpdate()`.
Regression: `test_redeem_requires_fresh_prices`.

### F-3 — MEDIUM — reentrancy in `mint`

`mint` pulls the collateral with an external `transferFrom` **before** touching state. That is correct
for the "never hold a refused deposit" property, but it is a reentrancy surface for any deposit token
with transfer hooks. USDC has none; the core accepts whatever token the owner wires, so it must not
depend on that.

**Fix:** `nonReentrant` on `mint` and `redeem`. Regression: `test_mint_is_reentrancy_guarded`, which
uses a `ReentrantToken` that calls back into `mint` from inside `transferFrom`.

### F-4 — MEDIUM — `uint64` downcast truncates instead of reverting

`minted = uint64(net * SCALE / ppi)` and `payout = uint64(gross - fee)` were explicit downcasts.
In Solidity 0.8 an explicit narrowing cast **truncates silently**; only arithmetic overflow reverts.
A deposit large enough to push the value past `2^64-1` would mint a wrapped (tiny) amount.

**Fix:** both are computed in `uint256`, bounded with `AmountTooLarge`, then cast.

---

## Open — accepted or blocked

### F-5 — MEDIUM — the oracle signer set is 1-of-1

`SignedPriceOracle` is deployed and wired, but its signer set is one key: the same operator that
drives the relayer. `updatePrice` (`onlyRelayer`) has the same trust level. The M-of-N machinery is
real but unexercised.

**Blocked on:** separate key holders. Fix is `setSigners([a,b,c], 2)` through the timelock — no
redeploy. Generating those keys ourselves would recreate the single point of failure under a
different name.

### F-6 — MEDIUM — owner can renormalise the index down to one asset

`setRiskState(FROZEN)` removes an asset from the index and the remaining weights are renormalised
(eq. 15). An owner holding the timelock could freeze thirteen assets and leave the "index" equal to
one commodity's price ratio, then trade against it.

**Partial mitigation:** the timelock delay (F-1) and the `RiskStateSet` event. **Not fixed:** there is
no maximum-frozen-weight guard. Adding one is a contract change; it should go in with the audit.

### F-7 — LOW — redemption freezes when the index deviates past 15%

`feeBpsForPpi` reverts `BandReject` beyond 15% deviation, and both `mint` and `redeem` call it. A
volatile week that pushes the index 15% from base therefore **locks exits**, which is the worst
possible moment to lock them. This is a known trade-off of the band design, not a bug, but it is a
bank-run amplifier and an auditor will raise it.

### F-8 — LOW — `PlanetToken.burn` subtracts supply unchecked

`unchecked { totalSupply -= value }` after a balance check. Unreachable today (burn is minter-only and
the core checks its own accounting first), but the `unchecked` buys nothing and removes a
defence-in-depth layer.

### F-9 — LOW — relayer key and owner key are the same address

`core.relayer()` is the deployer. A leak of that key can push prices (bounded by the guards) **and**,
because it is also the timelock's owner, propose admin actions. Key separation is a configuration
change, not a code change, and it has not been done.

### F-10 — INFO — `/api/v1/sources` fans out ~36 upstream requests per cache miss

A public endpoint that makes 36 outbound calls is a cost and amplification surface. Mitigated by a
120-second edge cache and a 12-second budget; not rate-limited per client.

### F-11 — INFO — 60-second timelock is a demo value

Production wants hours-to-days. `PlanetTimelock` refuses to lower a non-zero delay back to zero
(TL-3), but it does not enforce a minimum.

### F-12 — INFO — no source verification on Arbiscan

`sepolia.arbiscan.io` returns 403 to an unauthenticated fetch, so verification status could not be
confirmed and is not claimed. An auditor needs verified source; this is a submission blocker, not a
code defect.

---

## What this review does **not** cover

- The arbitrage and economic-incentive properties of the fee band and the renormalisation rule.
- Gas griefing and MEV around `updatePrice` (hourly, non-competitive).
- The Telegram bot and any credential handling outside this repository.
- Anything at the OS, CI-secret or GitHub-account layer. The deploy key is a single secret that can
  deploy; that is the largest uncontrolled surface in this system and it is not in the contracts.

## Recommended order for a real audit

1. F-5 (signer separation) — cheap, and it turns a written claim into an enforced one.
2. F-6 (frozen-weight guard) — the only finding where a privileged actor can move the index itself.
3. F-7 (exit freeze) — economic, needs a designer's opinion, not a patch.
4. Everything above before any mainnet claim.
