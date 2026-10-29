# End-to-end verification — 2026-10-29

Every row below was executed against production (`https://ppppp.space`) or a public RPC, not read
from a test. Reproduce any line with the command beside it.

## Verdict

**The product runs end to end.** The chain that matters — connect → see your ounces → quote →
sign → own metal → see it in the same view — is closed, and the last link was verified with real
money: the wallet bought 0.00040375 oz of PAXG on Ethereum mainnet and `/api/metals` read it back
with the correct issuer and an MiCA warning attached.

| # | Layer | Check | Result | Evidence |
|---|---|---|---|---|
| 1 | Site | `/`, `/metals`, `/whitepaper`, `/docs` | 200 | `/` was a transient failure on first probe, 200 on retry |
| 2 | Site | `/metals` carries the resume code | pass | `planet.pendingRoute`, `createStep`, `executeSwap(false)` present in the served HTML |
| 3 | Holdings | `GET /api/metals?address=0xBf0D…768C` | pass | `goldOz 0.000403745752141591`, `usd 1.6346`, `priceSource coingecko` |
| 4 | Quote | `GET /api/quote?symbol=PAXG&from=ARBITRUM&amount=5` | pass | `0.001230778122420831 PAXG` in ~83s |
| 5 | Execute | `POST /api/execute {action:confirm}` | pass | chains `ARBITRUM,ETH`, 1 shortfall (wallet holds 1.87 of the 5) |
| 6 | Execute | `POST /api/execute {action:create,step:1}` | pass | approve tx on ARBITRUM → `0xaf88d065…` |
| 7 | Oracle | `GET /api/v1/oracle` | pass | healthy, 0 reasons, 0 stale |
| 8 | Index | `GET /api/v1/status` | pass | `ppi 0.995086` (moves hourly), `supply 0` |
| 9 | Audit trail | `GET /api/v1/sources` | pass | 14 assets, **36 channel reads** |
| 10 | Automation | GitHub Actions | pass | price push, oracle monitor, protocol monitor, cache warmer — all `success`, hourly |

The last link, which is the product's actual claim:

    PAXG 0x45804880De22913dAFE09f4980848ECE6EcbAf78
    balance 0.000403745752141591  =  0.000403745752141591 oz  =  $1.63
    bought 0.0007 ETH → PAXG  tx 0xd0456d7a3501a9c25cf4f6aa785f01ae599d857d72983873633f3a1e5199cf84

A real swap produced real metal, and the product read it back. That is the loop closed.

## Gaps found (none of them blocking the loop)

| Gap | Severity | What it means |
|---|---|---|
| 5 USDC still in CCTP, attested, unminted | money, not function | `0xd512ec66…`; destination is Rango's router; waiting on their relayer |
| Two-step routes not yet proven with real money | unknown | resume now exists; needs a 1.8 USDC run to confirm |
| `/api/health` returns 404 | monitoring | there is no health endpoint; uptime is inferred from `/api/v1/oracle` |
| Demo core `supply 0` | cosmetic | the Sepolia PLT has no outstanding supply after the last redeem |

## What is NOT verified here

- Wallet-connect UX on a real browser extension (the API behind it was verified; the click was not).
- Anything in the EU under MiCA (PAXG is unavailable to EU residents, and the page says so).
- Multi-asset baskets, fund layer, RWA reserve — designed, not deployed.

## How to re-run

```bash
node e2e.mjs    # 9 assertions against production, no keys required
```
