# Planet off-chain relayer (TON testnet)

Fetches commodity / ETF prices from a public source, signs a `PricePayload` with an
ed25519 key, and pushes `SignedPriceUpdate` messages to a deployed **PlanetCore**.
PlanetCore verifies the signature on-chain (`isSignatureValid`) — see
`docs/oracle-ton.md`. No third-party oracle is required to get real prices on-chain.

## Setup

```bash
cd relayer
npm install
```

Config via env:

| Env | Meaning |
|---|---|
| `TON_ENDPOINT` | RPC endpoint (default: testnet toncenter) |
| `PLANET_CORE` | deployed PlanetCore address (hex or friendly) |
| `RELAYER_MNEMONIC` | 24-word mnemonic of the funded wallet (signer + gas payer) |
| `ASSETS_JSON` | path to the asset map (default `assets.json`) |
| `MULTI_SOURCE` | `0` disables cross-validation (default: on) |
| `MAX_SOURCE_SPREAD` | freeze asset if sources diverge beyond this (default `0.02` = 2%) |

## Commands

```bash
# 1) Register this wallet's public key as the oracle signer (owner action, once)
node relayer.mjs register

# 2) Fetch prices and push signed updates
node relayer.mjs push
```

## Asset map (`assets.json`)

```json
{
  "assets": [
    { "index": 0, "symbol": "CL=F", "sina": "hf_CL", "sinaScale": 1, "name": "WTI Crude" },
    { "index": 1, "symbol": "GC=F", "sina": "hf_GC", "sinaScale": 1, "name": "Gold" }
  ]
}
```

`index` must match the on-chain basket (`SetBasketAsset`). `symbol` is a **Yahoo Finance**
symbol (futures `CL=F`, `GC=F`, `HG=F`; ETF `GLD`, `USO`, …). Prices use
`meta.regularMarketPrice`, converted to 1e6 fixed point (raw price × 1e6).

## Multi-source cross-validation (S3)

Each asset may list a second independent source. The relayer fetches **Yahoo Finance** and
**Sina** (`hf_CL`/`hf_GC`/`hf_HG` international futures; `sinaScale` normalises units, e.g.
Copper is cents/lb → `0.01`), takes the **median**, and pushes it. If the sources diverge
beyond `MAX_SOURCE_SPREAD`, the asset is pushed as **`riskState=1` (frozen)** so the bad
reading is **excluded from `computePpi`** instead of corrupting the index. Signing the
median with the single oracle key still satisfies the on-chain M-of-N check.

## Notes / limits

- Testnet only. The wallet must hold testnet TON to pay gas.
- `volatility` / `liquidity` / `riskState` are currently set to `0 / 1e6 / 0`; extend
  `push` to compute volatility from a price history and to flag `frozen` on bad data.
- The signer key should, in production, be **separate** from the owner key (here one
  wallet does both for simplicity).
