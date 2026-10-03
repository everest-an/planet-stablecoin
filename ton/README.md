# Planet on TON (`ton/`)

TON implementation of Planet — commodity purchasing-power index protocol.

## Toolchain status

| Language | Toolchain | Status |
|---|---|---|
| **Tolk** (official, recommended) | **Acton** | ⚠️ **source written, NOT compiled** — needs WSL/Linux/Docker |
| Tact (deprecated by TON) | `@tact-lang/compiler` (npm) | ✅ compiled (Phase 0 PoC reference) |

> TON deprecated Tact in favour of **Tolk**; the official toolchain is **Acton**.
> Acton does **not** support native Windows — it must run inside **WSL (Ubuntu 22.04+)**, Linux, or Docker.

## Build (Tolk / Acton) — run inside WSL, not PowerShell

```bash
# 1. install Acton (inside WSL Ubuntu 22.04+)
curl -LsSf https://github.com/ton-blockchain/acton/releases/latest/download/acton-installer.sh | sh
acton --version   # expect 1.2.0+

# 2. from this directory
acton build
acton test
```

Alternative (no WSL): use the Acton Docker image:

```bash
docker run --rm -v "$PWD":/workspace -w /workspace ghcr.io/ton-blockchain/acton:1.2.0 build
```

## Legacy Tact PoC (compiles on native Windows)

```bash
npm install
npm run build     # tact --config tact.config.json  -> build/planet_PlanetCore.*
```

## Layout

```
contracts/planet_core.tolk   # Tolk core (Phase 0 skeleton): PPI, mint/burn, risk, pause
contracts/planet_core.tact   # legacy Tact PoC (compiles now, deprecated)
Acton.toml                   # Acton toolchain pin
tact.config.json             # legacy Tact config
build/                       # Tact build artifacts
```

See `../docs/PLAN-TON.md` for the migration plan and `../docs/TON-MAPPING.md` for the Solana→TON mapping.
