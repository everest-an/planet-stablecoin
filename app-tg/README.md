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
VITE_PLANET_ADDRESS=kQA57Fa64OT_MXIqrJD0DGokcNaw36neL-aIWjWJHcIp2QfX
VITE_PLT_MINTER_ADDRESS=kQDh_XQENGiZ7JSzvRYp_G7EvTtTXvpz6FXS65BnYVimGsEJ
```

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
