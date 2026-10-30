# Audit scope pack — what to review, where it lives, and what we already know

2026-10-30. Prepared so an audit firm can quote without a discovery call, and so the review starts at
the things this team could not see rather than at rediscovering our own findings.

---

## 1. What is being audited

Two systems. They are independent and can be quoted separately.

### A. The index (live on Arbitrum One, holds no funds)

| File | Lines | Purpose |
|---|---|---|
| `monad/src/PlanetCore.sol` | ~490 | basket, on-chain PPI, mint/redeem (disabled), fees, risk state |
| `monad/src/PlanetToken.sol` | ~125 | ERC-20, minter-gated |
| `monad/src/PlanetTimelock.sol` | ~130 | propose → delay → execute |
| `monad/src/SignedPriceOracle.sol` | ~170 | 2-of-3 verifier for signed price payloads |

Deployment (Arbitrum One 42161):

```
core      0x61de052af7cb7dc957a07b1e6298152bb851cbbb
token     0xee270802969f0689e3085331d47679bdc5bf4512
timelock  0xa1fdb9f95210af1d968872f6fc86f623a3e3017c
oracle    0x0daf541ef7e41402070bc549f91475ab368d1824
```

Owner of core and token is the timelock, delay 6h. `depositToken == address(0)`, so minting and
redemption cannot be exercised: the live system publishes a price and nothing else.

### B. The perp market (Sepolia only, **not** intended for real funds until audited)

| File | Lines | Purpose |
|---|---|---|
| `monad/src/perp/PPIPerp.sol` | ~420 | LP pool as counterparty, open/close, funding, liquidation, riskState-gated margin |
| `monad/src/perp/PPIPriceSource.sol` | ~85 | reads PPI, derives a data-quality level |
| `monad/src/perp/IPerpPrice.sol` | ~15 | the price/risk seam |

Sepolia (11155111): `perp 0x48fecec7f876540a4584fc71c22b8d49051ffe26`, price source
`0x132920e32fa9e1d65b64a37b1b18bc4305e4675b`, core `0xe0aeb4c5a15a6e09e0dcdaf552083bd253cfc64d`.

---

## 2. Reproducing the build

```
solc 0.8.24 (commit e11b9ed9), optimizer enabled, runs 200, evmVersion "paris"
```

No external dependencies: every contract is self-contained Solidity (no OpenZeppelin, no proxies).
The deployed bytecode matches a plain `solc --standard-json` compile of `monad/src`, which is what the
Arbiscan verification used. `monad/test-mocks/Mocks.sol` is test-only and out of scope.

---

## 3. Where we want the auditor to look hardest

1. **`PPIPerp` accounting.** `contract balance == totalCollateral + poolAssets` is the invariant every
   settlement writes against (`poolAssets = poolAssets + collateral - payout`). Try to break it with
   deposit/withdraw interleaved with open/close/liquidate, including the payout-cap branch.
2. **Funding.** `cumFunding` accrues per second per unit of signed size; the view adds pending funding
   (`_pendingCumFunding`) while settlement calls `_accrueFunding` first. Look for a way to settle at a
   stale cumFunding or to make funding exceed the position's equity.
3. **Liquidation.** Keeper reward is `max(liqFeeBps/2 of collateral, half of remaining equity)`, capped
   at collateral. Frozen feeds only allow closing positions underwater by more than half the
   maintenance buffer. Look for griefing and for paths that leave bad debt or pay a keeper twice.
4. **`PPIPriceSource`.** Future timestamps (the signer publishes `now + 120`) must count as age zero;
   a past bug reverted `open`/`liquidate` for two minutes after every push.
5. **Oracle digest.** `keccak256(abi.encode(DOMAIN, oracle, chainid, consumer, index, price,
   volatility, liquidity, riskState, timestamp))`, raw `ecrecover` (no EIP-191 prefix), `s > N/2`
   rejected, duplicate signers counted once, timestamps strictly increasing.
6. **Timelock.** `propose/execute` with a 6h delay and a 3-day grace; owner is an EOA today.

## 4. What we already know (do not spend budget rediscovering these)

| # | Severity | Finding | State |
|---|---|---|---|
| K1 | High (economic) | A stablecoin reserve cannot track a commodity index; no fee schedule closes the gap. The index is sold as a price reference, not a redeemable basket | Disclosed, by design |
| K2 | High | `PPIPerp` owner is an EOA and can repoint `priceSource` | Must be timelocked before real funds |
| K3 | High | 2-of-3 signer keys are held by one operator (two in Vercel, two in GitHub) | Needs three people |
| K4 | Medium | LP withdrawal is guarded against open interest but not against unrealised PnL | Open |
| K5 | Medium | Closing at a frozen price is allowed (users need exit) | Accepted trade-off |
| K6 | Medium | Keeper scans at most 500 accounts | Bounded by gas cost of dust positions |
| K7 | Medium | Funding is keeper-set within ±1e12/s, not derived from a mark price | Discretion, bounded |
| K8 | Info | No separate insurance fund; bad debt hits LP capital | Open |

Fixed during our own reviews, for context: payable-owner takeover risk (handover to timelock),
median-of-sources replaced by a confirmation rule, redeem freshness gate, fee cliffs, reentrancy on
mint, uint64 truncation, oracle signer set 1-of-1, the timestamp underflow above, keepers earning
zero on negative-equity positions, a missing decimals check, maintenance ≥ initial margin, and a 2h
caution window that let stale prints be traded.

## 5. Out of scope

The website and APIs, the relayer scripts (`relayer/*.mjs`), the Rango integration, and the economic
design of the index itself (basket weights, channel choice). `monad/src/PlanetBond.sol` if present is
outside this engagement.

## 6. Deliverables we expect

1. Findings with severity, impact, likelihood, a concrete exploit path or a test, and a recommendation.
2. A public report we can link from the site, plus a private version with any unpatched issues.
3. Re-review of fixes.

## 7. Commercials

Target: **2 calendar weeks, 1–2 auditors**, split as index (30%) / perp (70%). Please quote fixed-fee
with a re-review line item. Repository access under NDA; the deployment and build are reproducible from
this document alone.
