# Planet EVM relayer

Fetches the 14 commodity / ETF prices from four independent channels, signs the batch, and
submits it to `PlanetCore` / `SignedPriceOracle` on Arbitrum. The on-chain index is pull-based:
the consumer submits the signed payload in its own transaction, so the relayer never needs a
scheduled push key on mainnet.

## Files

| File | Purpose |
|---|---|
| `push-evm.mjs` | fetch → validate → submit a full 14-asset batch; `--dry-run` needs no key |
| `sources.mjs` | the four price channels and the confirmation rule |
| `sign-prices.mjs` | sign the 14 payloads with the 2-of-3 signer set |
| `submit-signed.mjs` | reference consumer: submit a signed batch to `updatePriceSigned` |
| `snapshot-ppi.mjs` | write a monthly PPI snapshot |
| `perp-*.mjs` | perp deployment, keeper, monitor and refresh helpers |
| `timelock-queue.mjs` | queue/execute timelocked parameter changes |
| `verify-*.mjs` | Arbiscan / lockdown verification |

## Setup

```bash
cd relayer
npm install
```

## Env

| Env | Meaning |
|---|---|
| `RPC` | Arbitrum RPC endpoint |
| `PRIVATE_KEY` | submitter key; never commit it |
| `CORE` | `PlanetCore` address (the index) |
| `ORACLE` | `SignedPriceOracle` address (for signing) |
| `ASSETS_JSON` | asset map, default `assets.example.json` |
| `CHAIN` | `arbitrum` / `arbitrum-sepolia` |
| `MIN_PUSH_DELTA` | skip an asset whose price moved less than this (default 0.1%) |
| `MAX_PUSH_AGE_H` | force a full refresh after this many hours |
| `MAX_SOURCE_SPREAD` | freeze an asset when channels diverge beyond this |
| `DRY_RUN` | `1` to fetch and print without sending |

## Commands

```bash
node push-evm.mjs --dry-run         # read-only: fetch, validate, print
node push-evm.mjs                   # submit the signed batch (consumer pays gas)
node sign-prices.mjs                # sign only
node submit-signed.mjs              # submit through the reference consumer
```

One full 14-asset refresh was measured at **~0.0000426 ETH (~$0.17)** at the October 2026
gas price. Signing is free; submitting is not.

## Sources

Four channels are read per asset: Yahoo is the primary, with Sina / Tencent / Eastmoney as
confirmations inside a 0.5% band. The rule is primary + confirmation, not a blind median; an
asset with no confirmation is published as `caution` rather than averaged with a dissenter.
Natural gas is single-source on purpose because the alternatives quote a later expiry.

Public audit trail: `https://ppppp.space/api/v1/sources`.