// Executes the pending timelock proposal once its delay has elapsed. Idempotent: exits 0 when
// nothing is pending, so a scheduled run after the first execution is a no-op.
// Env: PRIVATE_KEY (the timelock owner), RPC optional.
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { readFileSync } from "node:fs";

const D = JSON.parse(readFileSync(new URL("../docs/mainnet-deployment.json", import.meta.url), "utf8"));
const RPC = process.env.RPC || "https://arb1.arbitrum.io/rpc";
const TIMELOCK_ABI = [
  { name: "eta", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { name: "execute", type: "function", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "bool" }] },
];
const CORE_ABI = [{ name: "oracle", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] }];

function key() {
  if (process.env.PRIVATE_KEY) return process.env.PRIVATE_KEY;
  const env = readFileSync("E:/Protocol Bank/.env.local", "utf8");
  return env.match(/^AGENT_TEST_WALLET_PRIVATE_KEY=(.*)$/m)[1].trim().replace(/^["']|["']$/g, "");
}

const pub = createPublicClient({ chain: arbitrum, transport: http(RPC) });
const k = key();
const account = privateKeyToAccount(k.startsWith("0x") ? k : "0x" + k);
const wallet = createWalletClient({ account, chain: arbitrum, transport: http(RPC) });

const eta = await pub.readContract({ address: D.timelock, abi: TIMELOCK_ABI, functionName: "eta" });
const now = BigInt(Math.floor(Date.now() / 1000));
if (eta === 0n) {
  console.log("nothing pending — the timelock has no proposal");
  process.exit(0);
}
if (now < eta) {
  console.log(`not yet executable: eta ${new Date(Number(eta) * 1000).toISOString()}, now ${new Date(Number(now) * 1000).toISOString()}`);
  process.exit(0);
}

const hash = await wallet.writeContract({ address: D.timelock, abi: TIMELOCK_ABI, functionName: "execute" });
const rc = await pub.waitForTransactionReceipt({ hash });
if (rc.status !== "success") throw new Error("execute reverted " + hash);
console.log("executed", hash, "gas", rc.gasUsed);
console.log("core.oracle:", await pub.readContract({ address: D.core, abi: CORE_ABI, functionName: "oracle" }));
