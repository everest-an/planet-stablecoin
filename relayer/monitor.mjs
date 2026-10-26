// Protocol monitor — runs hourly. Fails loudly so GitHub raises it, because a monitor that writes a
// log line nobody reads is not monitoring.
//
// It checks the invariants a reader of the docs would assume are already watched:
//   1. the index is fresh (oldest active asset within MAX_ORACLE_AGE)
//   2. the contract actually holds what it says it holds (counter vs real balance)
//   3. the core is not paused
//   4. ownership is still the timelock (configuration drift after a redeploy)
//   5. a timelock proposal is sitting ready to execute (warn, with the ETA)
//
// Env: CORE, TOKEN, TIMELOCK, RPC (all defaulted to the live deployment)

import { createPublicClient, http, parseAbi, formatUnits } from "viem";
import { arbitrumSepolia } from "viem/chains";

const CORE = process.env.CORE ?? "0xE0b72e108DB58BCbc20da0b1Cd9BEB4824674E30";
const TIMELOCK = process.env.TIMELOCK ?? "0x2617Df906B6C42aF912dd4d4485Fcd74903a5feB";
const RPC = process.env.RPC ?? "https://sepolia-rollup.arbitrum.io/rpc";
const MAX_ORACLE_AGE = 21600;

const client = createPublicClient({ chain: arbitrumSepolia, transport: http(RPC) });

const coreAbi = parseAbi([
  "function owner() view returns (address)",
  "function paused() view returns (bool)",
  "function currentPpi() view returns (uint64)",
  "function oldestActiveUpdate() view returns (uint64)",
  "function totalReserve() view returns (uint64)",
  "function depositToken() view returns (address)",
  "function assetCount() view returns (uint256)",
]);
const tokenAbi = parseAbi(["function balanceOf(address) view returns (uint256)"]);
const tlAbi = parseAbi(["function hasPending() view returns (bool)", "function eta() view returns (uint64)"]);

const read = (abi, address, f, args) => client.readContract({ address, abi, functionName: f, ...(args ? { args } : {}) });

const failures = [];
const warnings = [];

try {
  const [owner, paused, ppi, oldest, totalReserve, depositToken, assetCount, hasPending, eta] = await Promise.all([
    read(coreAbi, CORE, "owner"),
    read(coreAbi, CORE, "paused"),
    read(coreAbi, CORE, "currentPpi"),
    read(coreAbi, CORE, "oldestActiveUpdate"),
    read(coreAbi, CORE, "totalReserve"),
    read(coreAbi, CORE, "depositToken"),
    read(coreAbi, CORE, "assetCount"),
    read(tlAbi, TIMELOCK, "hasPending"),
    read(tlAbi, TIMELOCK, "eta"),
  ]);

  const balance = await read(tokenAbi, depositToken, "balanceOf", [CORE]);
  const now = Math.floor(Date.now() / 1000);
  const age = oldest > 0 ? now - Number(oldest) : null;

  console.log(`core       ${CORE}`);
  console.log(`ppi        ${(Number(ppi) / 1e6).toFixed(6)}   assets ${assetCount}`);
  console.log(`oracle age ${age === null ? "never pushed" : age + "s"} (limit ${MAX_ORACLE_AGE}s)`);
  console.log(`reserve    counter ${formatUnits(BigInt(totalReserve), 6)}   balance ${formatUnits(balance, 6)}`);

  if (oldest === 0n) failures.push("oracle_never_pushed");
  else if (age > MAX_ORACLE_AGE) failures.push(`oracle_stale:${age}s`);

  if (balance < BigInt(totalReserve)) {
    failures.push(`reserve_undercollateralised: counter ${totalReserve} > balance ${balance}`);
  }

  if (paused) failures.push("core_paused");

  if (owner.toLowerCase() !== TIMELOCK.toLowerCase()) {
    failures.push(`owner_not_timelock: ${owner}`);
  }

  if (hasPending) {
    const ready = Number(eta) <= now;
    warnings.push(`timelock_proposal_${ready ? "READY_TO_EXECUTE" : "pending"} eta=${eta}`);
  }
} catch (e) {
  failures.push(`read_failed: ${String(e.shortMessage ?? e.message).slice(0, 120)}`);
}

for (const w of warnings) console.log(`WARN  ${w}`);
for (const f of failures) console.log(`FAIL  ${f}`);

if (failures.length) {
  console.error(`\n${failures.length} invariant(s) violated`);
  process.exit(1);
}
console.log("\nall invariants hold");
