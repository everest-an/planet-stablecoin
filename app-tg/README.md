# Planet — Telegram Mini App (`app-tg/`)

Web app (Vite + React + TON Connect) that reads **PlanetCore** live on-chain state and
lets a connected wallet mint / burn PLT. The **same build** runs as a **Telegram Mini App**
(Telegram loads the hosted page) — there is no separate "web vs TG" codebase.

## Run / Build

```bash
npm install
npm run dev        # dev server, http://localhost:5173
npm run build      # -> dist/
```

## Env (`.env.local`, see `.env.example`)

| Var | Purpose |
|---|---|
| `VITE_TON_ENDPOINT` | TON RPC endpoint (default: testnet toncenter) |
| `VITE_TONCENTER_API_KEY` | Optional toncenter API key (`X-API-Key`) — recommended in prod to avoid 429s |
| `VITE_PLANET_ADDRESS` | Deployed PlanetCore address (basket/PPI + mint) |
| `VITE_PLT_MINTER_ADDRESS` | PLT Jetton minter (burn) |
| `VITE_TONCONNECT_MANIFEST` | **Self-hosted** TON Connect manifest URL |

Current live testnet values (see `../docs/HANDOFF.md` §11):

```
VITE_PLANET_ADDRESS=kQAwzh3O-52-QBtB8JFFTjtNaKFhw-uJMkd-zdnoHoGibzcU
VITE_PLT_MINTER_ADDRESS=kQAMXsJdK0tklNy5x3Q8Jhw1dAkB6pw6ubREVprusamUcpbq
```

The live Core carries a **14-commodity basket** (energy / metals / agriculture / industrial,
each weight ≤15%, total 100%) — see `../relayer/assets.example.json`. Changing weights is a
governance action on PlanetCore (`GovernanceSetWeight` / `GovernanceAddAsset`; base prices are
immutable once locked). **Env vars are read at build time** — after changing them in Vercel,
trigger a new build (a push to `app-tg/` does it).

## Features

- **Design system:** monochrome "on-chain ledger / technical terminal" aesthetic (Aptos-inspired,
  tokens extracted live) — see [`DESIGN.md`](DESIGN.md). Light/dark toggle (remembered) +
  Telegram `colorScheme`. Custom mono wallet button (no default TON Connect button).
- Reads PPI / reserve / supply + on-chain basket (weights, prices, drift, **risk/frozen**) + basket-implied PPI.
- Connected-wallet balances: **Your PLT** (jetton wallet) and **Your TON**.
- Mint (PlanetCore `Mint` 0x10000001) and Burn (TEP-74 `AskToBurn` 0x595f07bc).
- Transaction feedback (submitted + explorer link), client-side guards (per-tx cap, PLT
  balance), auto-refresh (60s).
- RPC resilience: optional API key, exponential backoff + jitter on 429/timeouts; `Buffer` polyfill.

## Security / release notes

- **Non-custodial**: no keys in the app; the user signs in their own wallet.
- **Host your own** TON Connect manifest before release (the default is the demo manifest).
- Testnet only for now; public RPC is rate-limited — use a keyed/self-hosted RPC in production.
