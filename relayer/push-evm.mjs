// Planet EVM price push — the oracle's write path for Arbitrum Sepolia.
//
// Why a separate file from relayer.mjs: relayer.mjs is the TON implementation (TEP-74 / runGetMethod /
// ed25519 signer set). The price SOURCES (Yahoo + Sina, median-of-sources, spread->caution) and the
// push POLICY (delta gate + staleness ceiling) are the proven parts and are reproduced here verbatim in
// behaviour; only the settlement layer changes, from `SignPriceUpdate` to `updatePrice` via viem.
//
// Three invariants this file exists to respect — each one is a real way to lose money or freeze minting:
//
//  1. `lastOracleUpdate` is GLOBAL and `updatePrice` requires `timestamp > lastOracleUpdate`, while every
//     call SETS it. So a batch cannot share one timestamp: the second call would revert BadTimestamp.
//     TON's relayer already solved this with `ts += 1` (relayer.mjs ~L511). Same here, and the base is
//     max(now, lastOracleUpdate + 1) so a clock running behind the chain cannot wedge the push.
//
//  2. `priceJumpOk` rejects any single move > 50%, with NO bypass. If one asset gaps past that, the whole
//     batch must not die — we skip it, log it loudly, and let the other 13 keep `lastOracleUpdate` fresh.
//     (Otherwise one bad symbol freezes minting for the entire basket after MAX_ORACLE_AGE.)
//
//  3. `updatePrice` reverts `BadWeights` unless `weightSum() == SCALE`. Pre-flighted once per run so the
//     failure is one clear line, not 14 identical reverts.
//
// Settlement is a plain EOA (`onlyRelayer`) — this is the L1/"trusted relayer" stage. The M-of-N stage
// (SignedPriceOracle + updatePriceSigned) needs a Core change and a redeploy; see docs/HANDOFF.
//
// Env:
//   PRIVATE_KEY      required for a live push (0x-prefixed). Not needed for --dry-run.
//   CORE             PlanetCore address (default: the Arbitrum Sepolia deployment)
//   RPC              default https://sepolia-rollup.arbitrum.io/rpc
//   ASSETS_JSON      default assets.example.json
//   MIN_PUSH_DELTA   default 0.001 (0.1%) — skip writes that barely move the price
//   MAX_PUSH_AGE_H   default 6 — hours after which every asset is re-pushed regardless of delta
//   DRY_RUN=1        same as --dry-run
//
// Exit codes: 0 = nothing to do, or every attempted push settled. 1 = at least one push failed.

import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, parseAbi, formatEther, formatGwei } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia } from "viem/chains";
import { ASSETS as CHANNEL_ASSETS, readAsset } from "./sources.mjs";

const CORE = (process.env.CORE ?? "0xE0b72e108DB58BCbc20da0b1Cd9BEB4824674E30");
const RPC = (process.env.RPC ?? "https://sepolia-rollup.arbitrum.io/rpc");
const ASSETS_JSON = process.env.ASSETS_JSON ?? "assets.example.json";
const MIN_PUSH_DELTA = Number(process.env.MIN_PUSH_DELTA ?? "0.001");
const MAX_PUSH_AGE_H = Number(process.env.MAX_PUSH_AGE_H ?? "6");
const SCALE = 1_000_000;
const DRY_RUN = process.argv.includes("--dry-run") || process.env.DRY_RUN === "1";
// Same default as the TON relayer (relayer.mjs:71) — a deliberate carry-over, not a new policy.
const MAX_SPREAD = Number(process.env.MAX_SOURCE_SPREAD ?? "0.02"); // 2%

const ABI = parseAbi([
  "function assetCount() view returns (uint256)",
  "function weightSum() view returns (uint64)",
  "function paused() view returns (bool)",
  "function relayer() view returns (address)",
  "function lastOracleUpdate() view returns (uint64)",
  "function currentPpi() view returns (uint64)",
  "function assets(uint256) view returns (uint64 weight, uint64 basePrice, uint64 currentPrice, uint64 volatility, uint64 liquidity, uint8 riskState, uint64 lastUpdate)",
  "function updatePrice(uint256 index, uint64 price, uint64 volatility, uint64 liquidity, uint8 riskState, uint64 timestamp)",
]);

const chain = arbitrumSepolia;
const pub = createPublicClient({ chain, transport: http(RPC) });

// ---------------------------------------------------------------- main
const cfg = JSON.parse(readFileSync(ASSETS_JSON, "utf8"));
const nowSec = Math.floor(Date.now() / 1000);

console.log(`Planet EVM push${DRY_RUN ? " (DRY RUN — no transactions)" : ""}`);
console.log(`core=${CORE} rpc=${chain.name}`);

const [assetCount, wsum, paused, relayerAddr, lastUpd, ppiBefore] = await Promise.all([
  pub.readContract({ address: CORE, abi: ABI, functionName: "assetCount" }),
  pub.readContract({ address: CORE, abi: ABI, functionName: "weightSum" }),
  pub.readContract({ address: CORE, abi: ABI, functionName: "paused" }),
  pub.readContract({ address: CORE, abi: ABI, functionName: "relayer" }),
  pub.readContract({ address: CORE, abi: ABI, functionName: "lastOracleUpdate" }),
  pub.readContract({ address: CORE, abi: ABI, functionName: "currentPpi" }),
]);

console.log(
  `state: assetCount=${assetCount} weightSum=${wsum} paused=${paused} lastOracleUpdate=${lastUpd} ppi=${Number(ppiBefore) / SCALE}`,
);

// Fail once, clearly, instead of 14 times with the same error.
if (!paused && wsum !== BigInt(SCALE)) {
  console.error(`FATAL: weightSum=${wsum} != ${SCALE} — every updatePrice would revert BadWeights.`);
  process.exit(1);
}
if (paused) {
  console.error("FATAL: Core is paused — updatePrice reverts IsPaused. Nothing to do.");
  process.exit(1);
}
if (Number(assetCount) !== cfg.assets.length) {
  console.error(`FATAL: on-chain assetCount=${assetCount} but ${ASSETS_JSON} lists ${cfg.assets.length}.`);
  process.exit(1);
}

const stale = MAX_PUSH_AGE_H > 0 && nowSec - Number(lastUpd) >= MAX_PUSH_AGE_H * 3600;
console.log(`gate: minDelta=${(MIN_PUSH_DELTA * 100).toFixed(2)}% maxAge=${MAX_PUSH_AGE_H}h newestPush=${stale ? "stale" : "fresh"}`);

// Globally monotonic: every updatePrice must carry a timestamp strictly greater than the previous one.
let ts = Math.max(nowSec, Number(lastUpd) + 1);

const plan = [];
for (const asset of cfg.assets) {
  const i = asset.index;
  const onchain = await pub.readContract({ address: CORE, abi: ABI, functionName: "assets", args: [BigInt(i)] });
  const [, basePrice, currentPrice, , , riskState, lastUpdate] = onchain;

  const channelAsset = CHANNEL_ASSETS[asset.index];
  if (!channelAsset) {
    console.log(`#${i} ${asset.symbol}: SKIP — no channel config for index ${asset.index}`);
    continue;
  }
  const agg = await readAsset(channelAsset);
  if (!agg.ok) {
    console.log(`#${i} ${asset.symbol}: SKIP — ${agg.reason}`);
    continue;
  }

  const price = BigInt(Math.round(agg.price * SCALE));
  const risk = agg.riskState;
  const rel = currentPrice > 0n ? Math.abs(Number(price - currentPrice)) / Number(currentPrice) : 1;
  const riskChanged = Number(riskState) !== risk;
  const changePct = basePrice > 0n ? ((Number(price) / Number(basePrice)) - 1) * 100 : 0;
  // Staleness is PER ASSET: mint() gates on the oldest active input, so a quiet asset that the
  // delta gate keeps skipping would eventually close minting on its own. The heartbeat must
  // refresh each asset individually, not just the basket as a whole.
  const assetAge = Number(lastUpdate);
  const assetStale = MAX_PUSH_AGE_H > 0 && (assetAge === 0 || nowSec - assetAge >= MAX_PUSH_AGE_H * 3600);

  const line = `#${String(i).padStart(2)} ${asset.symbol.padEnd(6)} ${agg.price.toFixed(4).padStart(10)}` +
    `  vsBase ${changePct >= 0 ? "+" : ""}${changePct.toFixed(2)}%  vsChain ${(rel * 100).toFixed(3)}%` +
    `  src ${agg.confirmations + 1}/${agg.channelsOk}  spread ${(agg.spread * 100).toFixed(2)}%  risk ${riskState}->${risk}` +
    `  age ${assetAge === 0 ? "never" : Math.floor((nowSec - assetAge) / 60) + "m"}`;

  if (!assetStale && rel < MIN_PUSH_DELTA && !riskChanged) {
    console.log(`${line}  SKIP (below delta)`);
    continue;
  }
  if (price === 0n) {
    console.log(`${line}  SKIP (zero price)`);
    continue;
  }

  ts += 1;
  plan.push({ i, asset, price, risk, ts, line });
  console.log(`${line}  PUSH ts=${ts}`);
}

console.log(`\nplan: ${plan.length} push / ${cfg.assets.length} assets${DRY_RUN ? " (dry run)" : ""}`);
if (!plan.length) {
  console.log("nothing to push — the index is already current.");
  process.exit(0);
}

// ---------------------------------------------------------------- simulate everything before spending gas
const account = DRY_RUN ? null : privateKeyToAccount(normalizeKey(process.env.PRIVATE_KEY));

if (DRY_RUN) {
  for (const p of plan) {
    try {
      await pub.simulateContract({
        address: CORE, abi: ABI, functionName: "updatePrice",
        args: [BigInt(p.i), p.price, 0n, BigInt(SCALE), p.risk, BigInt(p.ts)],
        account: relayerAddr,
      });
      console.log(`  sim #${p.i} ${p.asset.symbol}: OK`);
    } catch (e) {
      const msg = (e.shortMessage ?? e.message ?? "").slice(0, 90);
      console.log(`  sim #${p.i} ${p.asset.symbol}: REVERT — ${msg}`);
      p.failed = true;
    }
  }
  const bad = plan.filter((p) => p.failed).length;
  console.log(`\ndry run complete: ${plan.length - bad} would settle / ${bad} would revert. No funds spent.`);
  process.exit(bad ? 1 : 0);
}

if (account.address.toLowerCase() !== relayerAddr.toLowerCase()) {
  console.error(`FATAL: signer ${account.address} is not Core.relayer ${relayerAddr} — every push would revert NotRelayer.`);
  process.exit(1);
}
const balance = await pub.getBalance({ address: account.address });
const gasPrice = await pub.getGasPrice();
console.log(`signer=${account.address} balance=${formatEther(balance)} ETH gas=${formatGwei(gasPrice)} gwei`);

const wallet = createWalletClient({ account, chain, transport: http(RPC) });

// ---------------------------------------------------------------- push
let ok = 0;
const failed = [];
for (const p of plan) {
  try {
    const hash = await wallet.writeContract({
      address: CORE, abi: ABI, functionName: "updatePrice",
      args: [BigInt(p.i), p.price, 0n, BigInt(SCALE), p.risk, BigInt(p.ts)],
    });
    const rc = await pub.waitForTransactionReceipt({ hash });
    if (rc.status !== "success") throw new Error(`tx ${hash} reverted`);
    ok++;
    console.log(`  #${p.i} ${p.asset.symbol} -> ${Number(p.price) / SCALE}  gas ${rc.gasUsed}  ${hash}`);
  } catch (e) {
    // One asset must never take the batch down: the remaining pushes still advance lastOracleUpdate.
    const msg = (e.shortMessage ?? e.message ?? "").slice(0, 110);
    failed.push({ i: p.i, symbol: p.asset.symbol, msg });
    console.log(`  #${p.i} ${p.asset.symbol}: FAILED — ${msg}`);
  }
}

// ---------------------------------------------------------------- verify on-chain (never trust the tx receipt alone)
const [lastUpdAfter, ppiAfter] = await Promise.all([
  pub.readContract({ address: CORE, abi: ABI, functionName: "lastOracleUpdate" }),
  pub.readContract({ address: CORE, abi: ABI, functionName: "currentPpi" }),
]);
console.log(`\nafter: lastOracleUpdate=${lastUpdAfter} ppi=${Number(ppiAfter) / SCALE} (was ${Number(ppiBefore) / SCALE})`);

let mismatch = 0;
for (const p of plan.filter((x) => !failed.some((f) => f.i === x.i))) {
  const a = await pub.readContract({ address: CORE, abi: ABI, functionName: "assets", args: [BigInt(p.i)] });
  if (a[2] !== p.price) {
    mismatch++;
    console.log(`  MISMATCH #${p.i}: on-chain ${a[2]} != pushed ${p.price}`);
  }
}

console.log(`result: ${ok} pushed, ${failed.length} failed, ${mismatch} mismatched`);
if (failed.length || mismatch || Number(lastUpdAfter) === Number(lastUpd)) {
  console.error("push incomplete — see failures above.");
  process.exit(1);
}
console.log("oracle sync OK.");

function normalizeKey(k) {
  if (!k) {
    console.error("FATAL: PRIVATE_KEY is not set (use --dry-run to preflight without it).");
    process.exit(1);
  }
  return k.startsWith("0x") ? k : `0x${k}`;
}
