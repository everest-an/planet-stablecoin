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
VITE_PLANET_ADDRESS=kQBUIDOcKIQZS_AMXjOL3usH69c3HIo0YudLoo_49eE0X2NJ
VITE_PLT_MINTER_ADDRESS=kQC6zZ83qploNLCy0MdUNhKkBD9Tx25N-xWF7iDHkd3IJ2k3
VITE_BOND_ADDRESS=kQDMxJXroCmuxBw9Sw7oj9LhO9Y0mLxdPS3Tr4vY-sdq65hz   # optional
```

The live Core carries a **14-commodity basket** (energy / metals / agriculture / industrial,
each weight ≤15%, total 100%) — see `../relayer/assets.example.json`. It is the **v1.8** code:
governance basket management (`GovernanceSetWeight` / `GovernanceAddAsset`, base prices
immutable) **plus a mint staleness guard** (refuses to mint against an oracle price older than
6h). Changing weights is a governance action (owner = a 60s timelock on testnet).

The **bond auto-trigger** (`PPI < 0.95` opens the sale, `>= 0.97` closes it) and the
`bondOpen` / `bondPaid` Core getters ship with the next Core redeploy. Until then the app reads
the Bond contract directly for `isOpen` / `premiumBps` / `totalIssued` (all three already exist
on the deployed Bond), and any unavailable read degrades to a muted "unavailable" line.

## Features

- **Design system:** monochrome "on-chain ledger / technical terminal" aesthetic (Aptos-inspired,
  tokens extracted live) — see [`DESIGN.md`](DESIGN.md). Light/dark toggle (remembered) +
  Telegram `colorScheme`. Custom mono wallet button (no default TON Connect button).
- Reads PPI / reserve / supply / **risk fund** / **oracle age** + on-chain basket (weights, prices, drift, **risk/frozen**) + basket-implied PPI.
- **Freshness guard in the UI:** PPI vs peg context, and a visible stale warning once the oracle is older than 6h (when minting is blocked on-chain).
- **Stability panel:** bond sale state, premium and face outstanding (optional `VITE_BOND_ADDRESS`), plus the risk fund.
- Manual refresh, first-load "reading chain…" state, and a top-level error banner.
- Connected-wallet balances: **Your PLT** (jetton wallet) and **Your TON**.
- Mint (PlanetCore `Mint` 0x10000001) and Burn (TEP-74 `AskToBurn` 0x595f07bc).
- Transaction feedback (submitted + explorer link), client-side guards (per-tx cap, PLT
  balance), auto-refresh (60s).
- RPC resilience: optional API key, exponential backoff + jitter on 429/timeouts; `Buffer` polyfill.

## Security / release notes

- **Non-custodial**: no keys in the app; the user signs in their own wallet.
- **Host your own** TON Connect manifest before release (the default is the demo manifest).
- Testnet only for now; public RPC is rate-limited — use a keyed/self-hosted RPC in production.
