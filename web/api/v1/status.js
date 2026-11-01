// Planet public read API — v1 (white paper appendix III: `/get_ppi`, `/reserves`).
//
// GET /api/v1/status -> JSON snapshot of the on-chain basket + PPI + reserve/supply/fees.
//
// Chain: Arbitrum One (42161), PlanetCore 0x61de052a…1cbbb. Reads are `eth_call` against the
// contract's auto-generated getters, batched into ONE JSON-RPC round trip (~1-2s) instead of the
// ~20s of sequential get-methods this used to do.
//
// Conventions (unchanged from the previous edition, so existing clients keep working):
//   - URL-path versioning (`/api/v1/...`); additive changes stay in v1.
//   - One error envelope everywhere: { error: { code, message, request_id, details? } }.
//     A non-2xx status ALWAYS carries this envelope; a 2xx NEVER does.
//   - Cache-Control + ETag so clients can revalidate (304 Not Modified).
//   - 503 + Retry-After when the upstream RPC is unavailable (transient).
//
// SCHEMA NOTES FOR EVM CONSUMERS (the port is NOT a rename of the earlier contract — read this before
// wiring a client):
//   * `ppi`       <- currentPpi().  There is no ppi() on the EVM core.
//   * `supply`    <- totalSupply() on CORE (the accounting source), not the token's own totalSupply.
//   * `reserve`   <- totalReserve().
//   * `assets[i]` <- assets(i), not assetAt(i).
//   * `bond`      is ABSENT: PlanetBond is not part of this deployment (Core + Token + Timelock
//                 only). The key is omitted rather than faked with zeros; consumers must treat it
//                 as optional (the dashboard already does).
//   * `signerThreshold` is read from SignedPriceOracle (2-of-3 on Arbitrum One). `oracle.mode` says
//                 which price path is live: "signed-only" while Core.relayer is the zero address,
//                 "relayer+signed" when both are up. Never infer the threshold from whether the
//                 relayer is set — that is how a 1-of-1 claim gets printed for a 2-of-3 oracle.
//   * `oldestAssetUpdate` is the timestamp `mint()` gates on — the stalest active asset. It is NOT
//                 `lastOracleUpdate` (the most recent push), which could be seconds old while some
//                 other input is a week old.

import {
  CHAIN,
  CORE,
  MAX_ORACLE_AGE,
  NETWORK,
  SCALE,
  newRequestId,
  readAssets,
  readOracleConfig,
  readScalarsAndAssets,
  sendJson,
  sendUpstreamError,
  toAddress,
  toNum,
} from "../_evm.js";

const NAMES = [
  "WTI Crude",
  "Brent Crude",
  "Natural Gas",
  "Gold",
  "Silver",
  "Copper",
  "Wheat",
  "Corn",
  "Soybean",
  "Coffee",
  "Lumber (ETF)",
  "Lithium (ETF)",
  "Water (ETF)",
  "Carbon (ETF)",
];

const WEIGHT_SCALE = 1e6;
const BUDGET_MS = 8000;
// Enough slots for the current 14-asset basket in the same batch as the scalars. A larger basket
// falls back to a full second read rather than silently truncating.
const ASSET_SLOTS = 16;

async function readStatus() {
  const started = Date.now();

  const [{ scalars: g, assets: slots }, oracleCfg] = await Promise.all([
    readScalarsAndAssets(
      [
        "assetCount",
        "currentPpi",
        "lastOracleUpdate",
        "oldestActiveUpdate",
        "totalSupply",
        "totalReserve",
        "riskFund",
        "feesToBurn",
        "feesToReserve",
        "feesToStaking",
        "relayer",
        "paused",
        "mintsPaused",
        "redeemsPaused",
        "isSolvent",
        "mintCap",
        "oracle",
      ],
      ASSET_SLOTS,
      { timeoutMs: BUDGET_MS },
    ),
    readOracleConfig({ timeoutMs: BUDGET_MS }),
  ]);

  // currentPpi + lastOracleUpdate are the two values the product cannot be described without; if
  // either is missing the RPC is effectively down and a partial snapshot would be a lie.
  if (g.currentPpi == null || g.lastOracleUpdate == null || g.assetCount == null) {
    return { unreachable: true };
  }

  const assetCount = toNum(g.assetCount);
  const rows =
    assetCount === 0
      ? []
      : assetCount > ASSET_SLOTS
        ? await readAssets(assetCount, { timeoutMs: BUDGET_MS })
        : slots.slice(0, assetCount);

  let partial = false;
  for (const k of ["totalSupply", "totalReserve", "relayer"]) if (g[k] == null) partial = true;

  const assets = [];
  for (const r of rows) {
    if (!r) {
      partial = true;
      continue;
    }
    assets.push({
      index: r.index,
      name: NAMES[r.index] ?? `asset ${r.index}`,
      weight: r.weight,
      weightPct: r.weight / (WEIGHT_SCALE / 100),
      basePrice: r.basePriceRaw / SCALE,
      currentPrice: r.currentPriceRaw / SCALE,
      changePct: r.basePriceRaw ? (r.currentPriceRaw / r.basePriceRaw - 1) * 100 : 0,
      volatility: r.volatility,
      liquidity: r.liquidity,
      riskState: r.riskState,
      lastUpdate: r.lastUpdate,
    });
  }
  if (assets.length < assetCount) partial = true;

  const relayer = toAddress(g.relayer);
  const relayerSet = relayer && relayer !== "0x" + "0".repeat(40);
  const oracleAddr = toAddress(g.oracle);
  const oracleSet = oracleAddr && oracleAddr !== "0x" + "0".repeat(40);

  return {
    data: {
      network: NETWORK,
      chain: CHAIN,
      core: CORE,
      isCurrentDeployment: true,
      // The Sepolia proof of concept is still deployed and still readable. It is advertised here
      // rather than dropped, so nobody has to guess which of the two cores a number came from —
      // point EVM_CORE + EVM_RPC at it to read that deployment instead of this one.
      poc: {
        chain: "arbitrum-sepolia",
        chainId: 421614,
        core: process.env.POC_CORE || "0xCEcad784A6cEB1aF12c69639a5027D935651F946",
        token: process.env.POC_TOKEN || "0x1Cc00D99F81DBAAAa3734594377b1781f427d12B",
      },
      readMs: Date.now() - started,
      partial,
      ppi: toNum(g.currentPpi) / SCALE,
      supply: toNum(g.totalSupply) ?? 0,
      reserve: toNum(g.totalReserve) ?? 0,
      assetCount,
      assetsReturned: assets.length,
      lastOracleUpdate: toNum(g.lastOracleUpdate),
      // The timestamp mint() actually gates on: the stalest ACTIVE asset, not the newest push.
      oldestAssetUpdate: toNum(g.oldestActiveUpdate),
      maxOracleAge: MAX_ORACLE_AGE,
      riskFund: toNum(g.riskFund) ?? 0,
      paused: g.paused != null && g.paused !== 0n,
      // Pausing is split: an oracle incident closes minting without closing the exit.
      pauses: {
        mint: g.mintsPaused != null && g.mintsPaused !== 0n,
        redeem: g.redeemsPaused != null && g.redeemsPaused !== 0n,
      },
      // The counter is a claim, the balance is a fact. This is the contract answering for itself.
      solvent: g.isSolvent == null ? null : g.isSolvent !== 0n,
      mintCap: toNum(g.mintCap),
      signerThreshold: oracleCfg.threshold ?? 0,
      oracle: {
        mode: relayerSet ? "relayer+signed" : oracleSet ? "signed-only" : "unset",
        relayer,
        threshold: oracleCfg.threshold,
        signerCount: oracleCfg.signerCount,
        multiSig: (oracleCfg.threshold ?? 0) > 1,
        address: oracleAddr,
        signedPath: !!oracleSet,
      },
      fees: {
        burn: toNum(g.feesToBurn) ?? 0,
        reserve: toNum(g.feesToReserve) ?? 0,
        staking: toNum(g.feesToStaking) ?? 0,
      },
      assets,
      links: {
        dashboard: "https://ppppp.space/dashboard",
        openapi: "https://ppppp.space/openapi.json",
      },
    },
  };
}

export default async function handler(req, res) {
  const requestId = newRequestId();
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
  res.setHeader("X-Request-Id", requestId);
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.setHeader("Allow", "GET, HEAD, OPTIONS");
    return res.status(405).json({
      error: { code: "method_not_allowed", message: "Only GET/HEAD/OPTIONS are supported.", request_id: requestId },
    });
  }

  let out;
  try {
    out = await readStatus();
  } catch {
    return sendUpstreamError(res, requestId, "upstream_error", "Could not read the chain right now.");
  }
  if (out.unreachable) {
    return sendUpstreamError(
      res,
      requestId,
      "chain_unavailable",
      "PlanetCore did not answer eth_call (public RPC unavailable or rate-limited). Retry shortly.",
    );
  }

  // This is the number the dashboard calls "live". A 15-minute edge window would let the page show a
  // PPI that is three push cycles old, so the cache is one dashboard refresh long.
  return sendJson(req, res, requestId, out.data, { maxAge: 60, volatile: ["readMs"] });
}
