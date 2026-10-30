# DeFi expert review — is the product complete?

2026-10-30, after the mainnet deployment. Verdict first, then the list.

## Verdict: mechanically complete, operationally and economically incomplete

The accounting is fuzz-verified and the attack surface is closed. What is missing is everything that
makes a perpetual market *run*: an operator, a funding mechanism, a consumer for the index, an
emergency brake, and a revenue line. A protocol in this state is a well-built engine without a
driver, fuel schedule, or brake line.

## Findings, in the order a DeFi auditor would raise them

### 1. Critical — no emergency pause; the only pause path is a 6h timelock

`setPaused` is owner-only, and the owner is a 6h timelock. In an incident (bad print, suspected
exploit), the market keeps accepting new risk for six hours. Every serious venue has a guardian or a
fast circuit breaker. **Fix:** a `guardian` role that can only pause (one-way), or a multisig owner
for the pause path. Requires a contract change and a redeploy — currently blocked by gas, not design.

### 2. Critical — the index freezes without a consumer, and the market dies with it

`riskLevel == 2` right now: nobody submitted a signed price on mainnet for hours, so the market is
close-only. The pull-oracle design is correct, but it makes the perp's liveness depend on someone
paying ~$0.17 per refresh — which nobody is contracted to do. **Until there is a consumer or a funded
keeper, the "live" market is dead on arrival.** This is the single biggest product-level gap.

### 3. High — no one is set to run liquidations or set funding

`keeper == address(0)` on the mainnet perp. `liquidate` is permissionless (anyone can), but in
practice nobody watches; `setFundingRate` needs the keeper role, so **funding is currently 0 and
unsettable**. Two more sequential timelock proposals are needed (the timelock holds one at a time):
`setKeeper`, then `setTreasury`.

### 4. High — the platform earns nothing

`treasury == address(0)`, so `_takeProtocolFee` returns 0 and 100% of fees go to LPs. The 30%
protocol share is configured but unwired. The "we rake the casino" business model is not connected.

### 5. High — funding is a parameter, not a mechanism

`fundingRatePerSec` is set by the keeper within bounds. A real perp derives funding from mark-minus-
index, so it equilibrates. Here nothing equilibrates: whoever holds the keeper key decides the cost
of holding a position. Honest for a beta, but it is discretion wearing a mechanism's clothes.

### 6. Medium — liquidation uses the instantaneous price

A single print can liquidate. The 50% jump guard and the frozen-feed rule blunt the worst case, but
there is no TWAP or time-weighted liquidation price, so a legitimate large gap (an oil shock) can
still cascade. Standard fix: liquidate at a time-weighted price with a deviation check.

### 7. Medium — LPs are structurally short the index, unhedged

At 2x OI, a 10% index move moves the pool 20%; a 33% trend takes two-thirds of LP capital. The LP
risk disclosure says this, but a disclosure does not change the exposure. Real pool products either
hold a delta (GLP holds the basket) or pay a real funding rate for the risk. This pool does neither.

### 8. Low — parameters are still the defaults until 02:04 UTC

10x leverage and 5% maintenance are live on-chain until the pending proposal executes. With an empty
pool the open-interest cap is zero, so nothing can be traded — the window is theoretical, but a
deposit today would open at 10x, not the beta's 3x.

### 9. Low — the /perps page still says Sepolia

The API now reads mainnet; the page banner and the trade panel's network switch still say Sepolia.
Cosmetic, but a page that lies about which chain it trades on is not a finished page.

## What is genuinely done (so the list is fair)

- Accounting invariants fuzz-tested (900 random steps, 4 invariants after every step).
- Replay, donation, reentrancy, share-inflation, price-manipulation surfaces closed.
- 2-of-3 signed oracle; the single-key relayer path is removed and re-verified daily.
- Keeper economics fixed (paid on negative-equity positions); frozen-feed liquidation guard.
- Timelock ownership from the first block; caps designed; exit runbook written.

## Resolution status (updated after the review)

| # | Fix | Status |
|---|-----|--------|
| 1 | Guardian emergency pause: one-way `emergencyPause()` + `setGuardian`, in PPIPerp v2. Only pause, no resume, no other power. | **Implemented + tested; live after v2 redeploy** |
| 2 | Index consumer: `index-refresh-mainnet.yml` submits the signed batch every 5h (the venue-absent treadmill). Freeze = honest failure mode, monitor alerts. | **Automated; costs ~$2/day of gas** |
| 3 | Keeper + treasury: `timelock-queue.mjs` advances setParams → setKeeper → setTreasury → setGuardian, one 6h round per day, fully automatic. | **Automated (4-day sequence)** |
| 4 | Treasury wired: same queue; the 30% share starts flowing once the round executes. | **Queued** |
| 5 | Funding rule: `perp-keeper.mjs --auto-funding` derives the rate from netSize/poolAssets, clamped at ±50 bps/day (the cap is 8%/day). It is a rule now, not a hand-set number. | **Implemented; active once setKeeper executes** |
| 6 | TWAP liquidation gate: `triggerPrice(isLong)` = trader-favorable side of {spot, 15-min ring TWAP}; a position must be underwater at both to be liquidated. Settlement stays at spot. | **Implemented + tested (wick-protection cases pass)** |
| 7 | LP short exposure: still structural. The 2x OI cap, 3x leverage cap and the funding rule bound it; a delta venue is future work, not rushed. | **Bounded, disclosed** |
| 8 | Default params: replaced by the v2 queue; defaults only exist in the minutes between deploy and first execute. | **Queued** |
| 9 | /perps page + API read mainnet. | **Done** |

The v2 deployment itself is gated on gas (see the deploy-perp-v2.mjs header) and, after deploy,
four 6h timelock rounds. Everything else is in the repository and runs unattended.

---

*This review was written by the same team that built the product, in an adversarial frame. It is not
an independent audit, and it says so.*
