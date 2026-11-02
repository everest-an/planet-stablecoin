# protocolbank-mcp

MCP server for the **Planet PPI** â€” a 14-commodity purchasing-power index published on Arbitrum One
where every asset carries a machine-readable **risk state** (`normal` / `caution` / `frozen`), not
just a price. Read-only: every tool answers from the public API, no keys, no writes.

- Live index: https://ppppp.space/ppi
- Methodology: https://ppppp.space/methodology
- Contracts: PlanetCore `0x61de052af7cb7dc957a07b1e6298152bb851cbbb` (Arbitrum One)

## Install

```bash
npx -y protocolbank-mcp
```

### Claude Desktop / any MCP client

```json
{
  "mcpServers": {
    "planet-ppi": {
      "command": "npx",
      "args": ["-y", "protocolbank-mcp"]
    }
  }
}
```

### From source

```bash
git clone https://github.com/everest-an/planet-stablecoin
cd planet-stablecoin/mcp
npm install
node index.mjs
```

## Tools

| tool | arguments | returns |
|---|---|---|
| `get_index` | â€” | index value (1.0 = inception), oracle state, all 14 assets with weights, prices, change and risk states |
| `get_asset` | `query` (symbol like `XAU`, `CL=F`, or index `0`â€“`13`) | one asset: weight, price, base price, change, risk state, and what a degraded state implies |
| `get_risk_level` | â€” | market-wide data-quality verdict (0 normal / 1 caution / 2 frozen), oracle age, and the settlement meaning |
| `get_perp_market` | â€” | the perpetual market on the index: price, pool size, open interest, net exposure, leverage/fee parameters |

`get_risk_level` follows the contract rule exactly: frozen when `lastOracleUpdate` is older than 6h
or any asset is frozen; caution when older than 30 minutes or any asset is flagged.

## Why risk states matter

A price feed that cannot say when its own data is bad is a liquidation engine waiting for a bad
print. Venues can raise margin while an asset is `caution` and stop opening risk while it is
`frozen` â€” before a stale value or a wick is liquidated through a pool.

## Notes

- Not a stablecoin and no commodity reserve: this is an index.
- The perpetual market is a limited beta; `poolAssets = 0` means it cannot take positions.
- Contracts are self-audited (no external audit); tests and audit documents are in the repository.
- Data: CC-BY-4.0. Daily snapshots: `docs/data/hf/ppi.csv` in the repo.

## License

MIT

