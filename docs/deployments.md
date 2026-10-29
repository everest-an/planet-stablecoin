# Deployments

## Arbitrum One (42161) — mainnet index, 2026-10-29

The PPI index, live. **Index-only: no deposit token is set, so mint/redeem are disabled and no one
can put funds into an unaudited contract.**

| Contract | Address |
|---|---|
| PlanetCore | `0x61de052af7cb7dc957a07b1e6298152bb851cbbb` |
| PlanetToken (PLT) | `0xee270802969f0689e3085331d47679bdc5bf4512` |
| PlanetTimelock | `0xa1fdb9f95210af1d968872f6fc86f623a3e3017c` |

- Owner of Core and Token: the timelock (`0xa1fd…017C`), delay **6 hours**.
- Relayer (pushes prices hourly): `0xBf0D7119F553eB5f85C9806f0849f9c86a9B768C`.
- PPI at inception: **1.000000** (base prices locked at the 14 assets' prices on 2026-10-29).
- weightSum: `1,000,000` · 14 assets · `baseLocked = true`.
- Deploy cost: ~0.000114 ETH.

Pushes: `.github/workflows/ppi-push-mainnet.yml` (hourly, secret `MAINNET_RELAYER_KEY`).

**Not yet done (see `docs/ppi-methodology-v1.md` §9):** source verification on Arbiscan,
relayer/owner key separation, oracle signer set, independent review against bytecode.

## Arbitrum Sepolia (421614) — PoC, 2026-10

| Contract | Address |
|---|---|
| PlanetCore | `0xCEcad784A6cEB1aF12c69639a5027D935651F946` |
| PlanetToken | `0x1Cc00D99F81DBAAAa3734594377b1781f427d12B` |
| PlanetTimelock | `0xd71CD916A237aB294230D0056ef4BD240e232Cb5` |
| SignedPriceOracle | `0x116Ca153eA8EdFFBf578C3D8452A3DDBC593eF70` |
| Test USDC (deposit) | `0x75faf114…AA4d` |
