# Deployments

## Arbitrum One (42161) — mainnet index, 2026-10-29

The PPI index, live. **Index-only: no deposit token is set, so mint/redeem are disabled and no one
can put funds into an unaudited contract.**

| Contract | Address |
|---|---|
| PlanetCore | `0x61de052af7cb7dc957a07b1e6298152bb851cbbb` |
| PlanetToken (PLT) | `0xee270802969f0689e3085331d47679bdc5bf4512` |
| PlanetTimelock | `0xa1fdb9f95210af1d968872f6fc86f623a3e3017c` |
| SignedPriceOracle | `0x0daf541ef7e41402070bc549f91475ab368d1824` |

- **Source verified on Arbiscan** for all three core contracts (2026-10-29).
- Owner of Core and Token: the timelock (`0xa1fd…017C`), delay **6 hours**.
- Oracle: signer set **2-of-3** (`0xBf0D…768C`, `0x8F7B…2922`, `0xC00A…631A`); consumer bound to the
  core, so a signature cannot be replayed onto another core or chain.
- **Pull oracle**: `/api/v1/price-signed` signs the 14 payloads on demand (zero gas). A consumer
  submits them via `updatePriceSigned` in its own transaction and pays that gas
  (`relayer/submit-signed.mjs` is the reference consumer). There is no scheduled push.
- PPI at inception: **1.000000** (base = the 14 assets' prices on 2026-10-29); weightSum `1,000,000`.
- Deploy cost: ~0.00015 ETH including the oracle.

**Wired.** `core.setOracle(oracle)` executed through the timelock on 2026-10-30
(tx `0x6aabd976…c9d1`, gas 64,872); `updatePriceSigned` is live and the first 14-payload submission
moved PPI to **1.009055**.

**Cost of one full refresh, measured: 0.0000426 ETH (~$0.17)** — 14 signed updates at ~152k gas each.
Signing is free; submitting is not. That cost belongs to whoever consumes the price (a venue bundles
it into its trade). Paying it ourselves on a schedule is the treadmill that was deliberately removed.

## Arbitrum Sepolia (421614) — PoC, 2026-10

| Contract | Address |
|---|---|
| PlanetCore | `0xCEcad784A6cEB1aF12c69639a5027D935651F946` |
| PlanetToken | `0x1Cc00D99F81DBAAAa3734594377b1781f427d12B` |
| PlanetTimelock | `0xd71CD916A237aB294230D0056ef4BD240e232Cb5` |
| SignedPriceOracle | `0x116Ca153eA8EdFFBf578C3D8452A3DDBC593eF70` |
| Test USDC (deposit) | `0x75faf114…AA4d` |
