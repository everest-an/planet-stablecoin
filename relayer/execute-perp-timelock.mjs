// Executes the perp's pending timelock proposal (the beta parameters) once its delay has elapsed.
// Idempotent: exits 0 when there is nothing pending.
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { readFileSync, existsSync } from "node:fs";

const FILE = "./perp-mainnet.json";
if (!existsSync(FILE)) {
  console.log("no perp deployment yet");
  process.exit(0);
}
const D = JSON.parse(readFileSync(FILE, "utf8"));
const A = JSON.parse(readFileSync("./artifacts.json", "utf8"));

const TIMELOCK_ABI = [
  { name: "eta", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { name: "execute", type: "function", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "bool" }] },
];
const PERP_ABI = [
  { name: "maxLeverageBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "maintenanceBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "maxOiToPoolBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "treasury", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
];

function key() {
  if (process.env.PRIVATE_KEY) return process.env.PRIVATE_KEY;
  const env = readFileSync("E:/Protocol Bank/.env.local", "utf8");
  return env.match(/^AGENT_TEST_WALLET_PRIVATE_KEY=(.*)$/m)[1].trim().replace(/^["']|["']$/g, "");
}

const pub = createPublicClient({ chain: arbitrum, transport: http("https://arb1.arbitrum.io/rpc") });
const k = key();
const account = privateKeyToAccount(k.startsWith("0x") ? k : "0x" + k);
const wallet = createWalletClient({ account, chain: arbitrum, transport: http("https://arb1.arbitrum.io/rpc") });

const eta = await pub.readContract({ address: D.timelock, abi: TIMELOCK_ABI, functionName: "eta" });
const now = BigInt(Math.floor(Date.now() / 1000));
if (eta === 0n) {
  console.log("no pending proposal");
} else if (now < eta) {
  console.log(`waiting: executable at ${new Date(Number(eta) * 1000).toISOString()}`);
  process.exit(0);
} else {
  const h = await wallet.writeContract({ address: D.timelock, abi: TIMELOCK_ABI, functionName: "execute" });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  if (rc.status !== "success") throw new Error("execute reverted");
  console.log("executed", h, "gas", rc.gasUsed);
}

const read = (fn) => pub.readContract({ address: D.perp, abi: PERP_ABI, functionName: fn });
console.log("maxLeverageBps :", (await read("maxLeverageBps")).toString(), "(30000 = 3x)");
console.log("maintenanceBps :", (await read("maintenanceBps")).toString(), "(1000 = 10%)");
console.log("maxOiToPoolBps :", (await read("maxOiToPoolBps")).toString(), "(20000 = 2x pool)");
console.log("treasury       :", await read("treasury"));
