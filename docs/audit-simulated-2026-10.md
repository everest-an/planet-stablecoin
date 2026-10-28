# Security Assessment — Planet protocol contracts

**Report ID:** PSSA-2026-10
**Assessment type:** Simulated third-party audit (see Disclaimer)
**Version assessed:** `monad/src` @ `af47466`, deployed on Arbitrum Sepolia
**Deployment audited:** Core `0xCEcad784A6cEB1aF12c69639a5027D935651F946`, Token
`0x1Cc00D99F81DBAAAa3734594377b1781f427d12B`, Timelock `0xd71CD916A237aB294230D0056ef4BD240e232Cb5`

---

## 1. Executive summary

Four contracts in scope: `PlanetCore` (basket, index, mint/redeem, fees, oracle state), `PlanetToken`
(ERC-20), `PlanetTimelock` (delayed owner), `SignedPriceOracle` (M-of-N verifier). The system is a
**synthetic index token** whose reserve is a stablecoin; it does not hold, hedge or redeem the
underlying commodities.

**Two findings would have allowed loss of funds and are fixed in the assessed version.** One was
critical: ownership sat on an EOA while the documentation promised a 60-second delay, and the token
owner could re-point the minter and drain the reserve through `redeem`. The high-severity finding was
that `redeem` had no freshness gate while `mint` did, which is an arbitrage against the reserve.

The remaining risk is **economic, not lexical**: the reserve does not move with the liability. No
contract change fixes that; it requires a backing model (see §6).

| Severity | Count | Open |
|---|---|---|
| Critical | 1 | 0 |
| High | 2 | 1 (economic, cannot be patched) |
| Medium | 5 | 2 |
| Low | 5 | 3 |
| Informational | 4 | 4 |

---

## 2. Scope

```
monad/src/PlanetCore.sol            292 → 470 lines
monad/src/PlanetToken.sol           125 lines
monad/src/PlanetTimelock.sol        130 lines
monad/src/SignedPriceOracle.sol     167 lines
```

Out of scope: `web/`, `relayer/`, the Rango integration, deployment keys, and the operating entity.

## 3. Methodology

1. Manual review of every line, in the order a user touches it (configure → push → mint → redeem →
   admin).
2. **Live verification** of every claimed property against the deployed contracts: fee constants,
   ownership, oracle wiring, token minter, and an on-chain swap of 5 USDC through the Rango path.
3. Unit suite: 82 tests. Stateful invariant suite: 4 invariants over random call sequences
   (reserve == real balance, core supply == ERC-20 supply, stored index == recomputed index, no
   supply without a defined index).
4. Threat modelling against comparable incidents (Synthetix stock synths, Mirror, and the FPI
   index-stablecoin design).

---

## 4. Findings

### C-01 (Critical, fixed) — privileged roles on an EOA; the timelock was decorative

**Evidence (on-chain, before the fix):** `core.owner()`, `token.owner()` and `timelock.owner()` all
returned the deployer EOA, while the documentation stated every privileged action is delayed.

**Impact.** `token.owner` could call `setMinter(attacker)`, mint unlimited PLT, restore the minter,
and call `core.redeem()` — draining the reserve in two transactions with no delay.

**Fix.** `script/Handover.s.sol` moves both to the timelock; a `handover` action was added to the
deployment workflow. **Residual:** the timelock's owner is still an EOA, so a 60-second window is a
delay, not a defence, and nothing alerts on a pending proposal.

### H-01 (High, fixed) — `redeem` had no freshness gate

`mint` gated on the oldest active asset; `redeem` gated on nothing. Once the index was stale, a
redeemer was paid at a PPI the market had left behind — a transfer from the reserve to whoever
redeemed first.

**Fix.** The same `StaleOracle` check now runs in `redeem`. Regression test present.

### H-02 (High, open — cannot be patched) — the reserve does not move with the liability

The reserve holds a dollar asset; the liability is an index of commodity prices. If the index rises,
the reserve does not, so the last redeemers cannot be paid what the index promised. Pro-rata
redemption (`RedeemedProRata`) shares the shortfall instead of rewarding the fastest exit, which is
the honest floor but not a solution. **This is a missing backing model, not a code defect** (§6).

### M-01 (Medium, fixed) — reentrancy surface in `mint`

Collateral was pulled with an external `transferFrom` before state updates. With a token that has
transfer hooks this is exploitable. `nonReentrant` added to `mint` and `redeem`; a
`ReentrantToken` regression test now exists.

### M-02 (Medium, fixed) — `uint64` downcast truncates

`uint64(net * SCALE / ppi)` and the equivalent in `redeem` truncate silently in 0.8. Bounded with
`AmountTooLarge` before the cast.

### M-03 (Medium, fixed) — the fee schedule had two cliffs

Measured: 4.99% deviation cost 100 bps and 5.01% cost 201 bps; 15.00% cost 1200 bps and 15.01%
reverted. A 0.02% move doubling everyone's fee is a lever for whoever can nudge the index.
Replaced with a continuous curve (flat 50 bps to 3%, linear to 300 bps at the edge) and the band
moved to `checkBand()` at the entry point.

### M-04 (Medium, mitigated) — owner could renormalise the index to one asset

Freezing an asset removes it from the index and renormalises the rest. `frozenWeightCap` (40%) now
bounds this. Not eliminated: an owner can still freeze up to the cap.

### M-05 (Medium, open) — oracle signer set is 1-of-1

`SignedPriceOracle` is deployed and wired, but its signer set is one key — the same operator that
drives the relayer. The M-of-N machinery is real but unexercised. Fix is `setSigners` through the
timelock, blocked on key holders.

### L-01 (Low, fixed) — fee labels with no sink

`feesToBurn` / `feesToStaking` accumulated while nothing burned or staked them; after a pro-rata
redemption they could describe money already paid out. Both counters are now zero and the split is
90% reserve / 10% risk fund.

### L-02 (Low, fixed) — oracle digest did not bind the consuming core

Now includes `consumer`, so a signature cannot be replayed onto another core.

### L-03 (Low, fixed) — timelock proposals never expired

`gracePeriod` (3 days) added; `execute` reverts `TooLate` after it.

### L-04 (Low, open) — relayer key == timelock owner

Configuration, not code. Same key can push prices and propose admin actions.

### L-05 (Low, open) — `PlanetToken.burn` subtracts supply unchecked

Unreachable today (minter-only, balance-checked first) but the `unchecked` removes a layer of
defence for no measurable gain.

### I-01..I-04 (Informational)

- No source verification on Arbiscan — a blocker for any real audit.
- `/api/v1/sources` fans out ~34 upstream requests per cache miss; cached, not rate-limited.
- 60-second timelock is a demo value; production wants hours-to-days.
- `assets` is unbounded and both `computePpi` and `weightSum` are O(n).

---

## 5. Centralisation analysis

| Capability | Holder | Delay |
|---|---|---|
| `forcePrice` (bypass the 50% jump guard) | timelock | 60s |
| `setRelayer`, `setRiskState`, `setLimits`, `pause` | timelock | 60s |
| `setOwner`, `setMinter`, `setToken` | timelock | 60s |
| Price submission | single relayer EOA | none |

A single EOA still holds both roles behind the timelock. Until that key is split and its owner is a
multisig, the "delayed" property protects against mistakes and haste, not against a compromised key.

## 6. What the audit cannot fix

PLT is a claim on an index, backed by a stablecoin. The protocol is structurally short the index.
FPI solves the same problem by making the reserve **earn** the CPI rate; Planet's reserve earns
nothing, so the ratio decays by construction. Until the reserve holds the basket or a delta-matched
hedge, H-02 stands regardless of the code.

## 7. Conclusion

The contracts do what they say, with two exceptions that are economic rather than lexical: the
reserve cannot deliver index returns (H-02), and the oracle is single-key (M-05). Both are stated in
the whitepaper and the API rather than hidden. **Recommendation: resolve M-05 and open H-02 before
any mainnet claim; neither is a code review issue alone.**

---

## Disclaimer

**This is a simulated audit written by the team that built the contracts, in an auditor's format.**
It is not an independent assessment and must not be presented as one. A real audit requires a firm
with no stake in the code, source verification on Arbiscan, and a scope letter. What this document
is good for: a complete list of what to fix, with evidence, so that a paid audit starts at finding
the things this review missed rather than at rediscovering these.
