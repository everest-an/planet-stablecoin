# Planet — Telegram Mini App (`app-tg/`)

Phase 0 MVP: reads **PlanetCore** on-chain state (PPI / reserve / supply) and connects a
wallet via **TON Connect**. This is the "TG as first entry" surface (see `../docs/GTM.md`).

## Run

```bash
npm install
npm run dev
```

## Build

```bash
npm run build     # -> dist/
```

## Env (`.env.local`)

| Var | Purpose |
|---|---|
| `VITE_TON_ENDPOINT` | TON RPC endpoint (default testnet toncenter) |
| `VITE_PLANET_ADDRESS` | Deployed PlanetCore address to read from |
| `VITE_TONCONNECT_MANIFEST` | Hosted TON Connect manifest URL |

## Notes / limits

- Telegram Mini Apps with blockchain features **must use TON + TON Connect** (Telegram Blockchain Guidelines).
- Phase 0 reads getters only. **Mint/burn UI is added after the PLT Jetton contract ships.**
- The TON Connect manifest must be hosted at a public URL before release (default is the demo manifest).
