#!/usr/bin/env node
// Planet PPI MCP server — exposes the on-chain commodity index to any MCP-capable agent.
// Read-only. Every tool answers from the public API (https://ppppp.space/api/v1/*), which reads
// Arbitrum One directly; no keys, no writes.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const BASE = process.env.PPI_BASE || "https://ppppp.space";
const CORE = "0x61de052af7cb7dc957a07b1e6298152bb851cbbb";

async function api(path) {
  const r = await fetch(BASE + path, { headers: { "cache-control": "no-cache" } });
  if (!r.ok) throw new Error(`API ${r.status} on ${path}`);
  const j = await r.json();
  if (j.error) throw new Error(j.error.message || "API error");
  return j;
}

const RISK = ["normal", "caution", "frozen"];
const riskName = (v) => RISK[Number(v)] ?? String(v);

const server = new McpServer({ name: "planet-ppi", version: "0.1.0" });

server.tool(
  "get_index",
  "Get the live Planet PPI commodity purchasing-power index: value (1.0 = inception), the oracle state (age, risk level), and the 14 assets with weights, prices and risk states. Source: PlanetCore on Arbitrum One.",
  {},
  async () => {
    const j = await api("/api/v1/ppi");
    const ppi = j.ppi ?? j.currentPpi ?? j.index ?? null;
    const assets = (j.assets || []).map((a) => ({
      index: a.index, name: a.name ?? null, symbol: a.symbol ?? null,
      weightPpm: a.weightPpm ?? null, weightPct: a.weightPct ?? null,
      price: a.currentPrice ?? a.price ?? null, changePct: a.changePct ?? null,
      riskState: riskName(a.riskState ?? a.risk ?? 0),
    }));
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          index: ppi,
          base: 1.0,
          core: CORE,
          chain: "arbitrum-one (42161)",
          oracle: j.oracle ?? null,
          assets,
          note: "riskState=caution halves leverage in the perp; riskState=frozen excludes the asset from the index. Not a stablecoin; no commodity reserve.",
        }, null, 1),
      }],
    };
  }
);

server.tool(
  "get_asset",
  "Get one commodity in the index by symbol (e.g. XAU, XAG, CL, NG) or by index 0-13: weight, price, risk state, base price.",
  { query: z.string().describe("Symbol like XAU or XAG, or the numeric index 0-13") },
  async ({ query }) => {
    const j = await api("/api/v1/ppi");
    const q = String(query).trim().toUpperCase();
    const assets = j.assets || [];
    const hit = /^\d+$/.test(q)
      ? assets.find((a) => Number(a.index) === Number(q))
      : assets.find((a) => String(a.symbol ?? a.name ?? "").toUpperCase() === q);
    if (!hit) {
      return { content: [{ type: "text", text: `No asset "${query}". Known symbols: ` + assets.map((a) => a.symbol ?? a.name).join(", ") }] };
    }
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          symbol: hit.symbol ?? hit.name, name: hit.name ?? null, index: hit.index,
          weightPpm: hit.weightPpm ?? null, weightPct: hit.weightPct ?? null,
          price: hit.currentPrice ?? hit.price, basePrice: hit.basePrice ?? null,
          changePct: hit.changePct ?? null,
          riskState: riskName(hit.riskState ?? hit.risk ?? 0),
          impact: "A frozen asset is excluded from the index and renormalised out; a caution asset halves leverage where the index is used as margin.",
        }, null, 1),
      }],
    };
  }
);

server.tool(
  "get_risk_level",
  "Get the market-wide data-quality verdict for the index: 0 = fresh and normal, 1 = caution (stale >30min or an asset flagged), 2 = frozen (older than 6h or an asset frozen; close-only in the perp). Use this before settling anything against the index.",
  {},
  async () => {
    const j = await api("/api/v1/ppi");
    const last = j.lastOracleUpdate ?? null;
    const age = j.oracleAgeSeconds ?? (last ? Math.max(0, Math.floor(Date.now() / 1000) - Number(last)) : null);
    const states = (j.assets || []).map((a) => Number(a.riskState ?? 0));
    let level = 0;
    if (age == null || age > 6 * 3600 || states.some((v) => v >= 2)) level = 2;
    else if (age > 30 * 60 || states.some((v) => v === 1)) level = 1;
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          level, label: riskName(level),
          lastUpdate: last,
          ageSeconds: age,
          meaning: level === 2 ? "Do not open new risk; settlement price is the last known one."
            : level === 1 ? "Usable, but raise margin / halve leverage."
            : "Fresh; normal settlement.",
        }, null, 1),
      }],
    };
  }
);

server.tool(
  "get_perp_market",
  "Get the Planet perpetual market on the index: price, pool size, open interest, net exposure, risk state, leverage and fee parameters. An empty pool means the market cannot take positions.",
  {},
  async () => {
    const j = await api("/api/v1/perp");
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          perp: j.contracts?.perp, core: j.contracts?.core, collateral: j.contracts?.collateral,
          price: j.market?.price, poolAssets: j.pool?.assets, sharePrice: j.pool?.sharePrice,
          netExposure: j.pool?.netExposure, risk: j.market?.riskLabel,
          maxLeverage: j.market?.maxLeverage, maintenancePct: j.market?.maintenancePct,
          openFeePct: j.market?.openFeePct, oiCap: j.market?.maxOiToPool,
          note: "The LP pool is the counterparty. poolAssets=0 means open() reverts (open-interest cap).",
        }, null, 1),
      }],
    };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
