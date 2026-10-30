// Mainnet perp deployment. Gated: refuses unless core.relayer == 0, because the price source does too.
// Resumable, and it uses the timelock as owner from the first block (the perp has no setOwner).
import { createPublicClient, createWalletClient, http, formatUnits, encodeFunctionData } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const A = JSON.parse(readFileSync("./artifacts.json", "utf8"));
const P = JSON.parse(readFileSync("./perp-artifacts.json", "utf8"));
const D = JSON.parse(readFileSync(new URL("../docs/mainnet-deployment.json", import.meta.url), "utf8"));
const STATE = "./perp-mainnet-state.json";
const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
const DELAY = BigInt(process.env.DELAY || "21600");

const env = readFileSync("E:/Protocol Bank/.env.local", "utf8");
const rawPk = env.match(/^AGENT_TEST_WALLET_PRIVATE_KEY=(.*)$/m)[1].trim().replace(/^["']|["']$/g, "");
const account = privateKeyToAccount(rawPk.startsWith("0x") ? rawPk : "0x" + rawPk);
const RPC = "https://arb1.arbitrum.io/rpc";
const pub = createPublicClient({ chain: arbitrum, transport: http(RPC) });
const wallet = createWalletClient({ account, chain: arbitrum, transport: http(RPC) });

const state = existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : {};
const save = () => writeFileSync(STATE, JSON.stringify(state, null, 1));
const log = (...a) => console.log(...a);

// A committed record means the market already exists; redeploying would create a second one and
// split liquidity. This guard is what makes the script safe to re-run from CI.
if (existsSync("./perp-mainnet.json") && !process.env.FORCE) {
  const prev = JSON.parse(readFileSync("./perp-mainnet.json", "utf8"));
  log("already deployed:", prev.perp, "— set FORCE=1 to deploy another");
  process.exit(0);
}

const relayer = await pub.readContract({ address: D.core, abi: A.PlanetCore.abi, functionName: "relayer" });
log("core.relayer:", relayer);
if (relayer !== "0x0000000000000000000000000000000000000000") {
  console.error("REFUSING: the core still has an active relayer. One key could move the price of a market that settles money.");
  process.exit(2);
}

const deploy = async (key, abi, bytecode, args) => {
  if (state[key]) { log(`${key.padEnd(14)} exists ${state[key]}`); return state[key]; }
  const h = await wallet.deployContract({ abi, bytecode, args });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  if (rc.status !== "success") throw new Error(key + " reverted");
  state[key] = rc.contractAddress;
  save();
  log(`${key.padEnd(14)} ${rc.contractAddress}  gas ${rc.gasUsed}`);
  return rc.contractAddress;
};

log("deployer:", account.address, "| ETH:", formatUnits(await pub.getBalance({ address: account.address }), 18));

// 1. the perp's own timelock (owner of the market from the first block)
const timelock = await deploy("timelock", A.PlanetTimelock.abi, A.PlanetTimelock.bytecode, [account.address, DELAY]);
// 2. price source - refuses a core with an active relayer by construction
const source = await deploy("priceSource", P.PPIPriceSource.abi, P.PPIPriceSource.bytecode, [D.core, 1000n]);
// 3. the market, owned by the timelock
const perp = await deploy("perp", P.PPIPerp.abi, P.PPIPerp.bytecode, [USDC, source, timelock]);

const out = { chain: "arbitrum-one", chainId: 42161, core: D.core, oracle: D.oracle, collateral: USDC, timelock, priceSource: source, perp, owner: account.address, delay: Number(DELAY) };
writeFileSync("./perp-mainnet.json", JSON.stringify(out, null, 1));
// Beta parameters, proposed through the perp's own timelock. Nobody can fund the pool until they
// execute, so there is no window where the defaults (10x leverage) apply to real money.
const propose = async (label, data) => {
  const k = "proposed:" + label;
  if (state[k]) { log(`${("\u2713 " + label).padEnd(22)} already proposed`); return; }
  const h = await wallet.writeContract({ address: timelock, abi: A.PlanetTimelock.abi, functionName: "propose", args: [perp, data] });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  if (rc.status !== "success") throw new Error("propose " + label + " reverted");
  state[k] = h;
  save();
  log(`${("\u2713 " + label).padEnd(22)} proposed (gas ${rc.gasUsed})`);
};

await propose("setParams", encodeFunctionData({
  abi: P.PPIPerp.abi,
  functionName: "setParams",
  args: [30_000n, 10n, 10n, 1_000n], // 3x, 0.10% open, 0.10% close, 10% maintenance
}));
await propose("setTreasury", encodeFunctionData({ abi: P.PPIPerp.abi, functionName: "setTreasury", args: [account.address] }));
await propose("setMaxOiToPool", encodeFunctionData({ abi: P.PPIPerp.abi, functionName: "setMaxOiToPool", args: [20_000n] }));

const eta = await pub.readContract({ address: timelock, abi: A.PlanetTimelock.abi, functionName: "eta" });
log(`beta parameters executable at ${new Date(Number(eta) * 1000).toISOString()}`);

log("\nwritten perp-mainnet.json");
log("perp owner is the timelock — parameters must be proposed and executed through it.");
