// Sequential timelock queue: the timelock holds ONE proposal, so the post-deploy proposals must run
// one at a time — setParams (already proposed) → setKeeper → setTreasury. This script advances the
// queue: execute when due, then propose the next. Idempotent; safe to run every day.
//
// Queue is docs/timelock-queue.json: [{"label","fn","args"}]. Once an item is proposed, the queue
// file is rewritten with a "proposed" flag so the next run proposes the following item.
import { createPublicClient, createWalletClient, http, encodeFunctionData } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const PERP_FILE = "./perp-mainnet.json";
if (!existsSync(PERP_FILE)) { console.log("no perp deployment yet"); process.exit(0); }
const D = JSON.parse(readFileSync(PERP_FILE, "utf8"));
const Q_FILE = "../docs/timelock-queue.json";
const QUEUE = JSON.parse(readFileSync(new URL(Q_FILE, import.meta.url), "utf8"));
const P_ABI = JSON.parse(readFileSync("./perp-artifacts.json", "utf8")).PPIPerp.abi;
const TL_ABI = [
  { name: "eta", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { name: "execute", type: "function", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "bool" }] },
  { name: "propose", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "bytes" }], outputs: [] },
];

function key() {
  if (process.env.PRIVATE_KEY) return process.env.PRIVATE_KEY;
  const env = readFileSync("E:/Protocol Bank/.env.local", "utf8");
  return env.match(/^AGENT_TEST_WALLET_PRIVATE_KEY=(.*)$/m)[1].trim().replace(/^["']|["']$/g, "");
}
const pub = createPublicClient({ chain: arbitrum, transport: http(process.env.RPC || "https://arbitrum-one-rpc.publicnode.com") });
const k = key();
const account = privateKeyToAccount(k.startsWith("0x") ? k : "0x" + k);
const wallet = createWalletClient({ account, chain: arbitrum, transport: http(process.env.RPC || "https://arbitrum-one-rpc.publicnode.com") });

const PERP = D.perpV2 || D.perp; // v2 once deployed, v1 until then
const eta = await pub.readContract({ address: D.timelock, abi: TL_ABI, functionName: "eta" });
const now = BigInt(Math.floor(Date.now() / 1000));

if (eta !== 0n && now >= eta) {
  const h = await wallet.writeContract({ address: D.timelock, abi: TL_ABI, functionName: "execute" });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  if (rc.status !== "success") throw new Error("execute reverted");
  console.log("executed", h, "gas", rc.gasUsed);
} else if (eta !== 0n) {
  console.log(`proposal pending, executable at ${new Date(Number(eta) * 1000).toISOString()}`);
  process.exit(0);
}

// find the next queue item that is not yet proposed
const next = QUEUE.find((q) => !q.proposed && !q.done);
if (!next) { console.log("queue exhausted"); process.exit(0); }

const args = next.args.map((a) => (typeof a === "string" && /^0x[0-9a-fA-F]{40}$/.test(a) ? a : BigInt(a)));
const data = encodeFunctionData({ abi: P_ABI, functionName: next.fn, args });
const h2 = await wallet.writeContract({ address: D.timelock, abi: TL_ABI, functionName: "propose", args: [PERP, data] });
const rc2 = await pub.waitForTransactionReceipt({ hash: h2 });
if (rc2.status !== "success") throw new Error("propose reverted");
next.proposed = true;
writeFileSync(new URL(Q_FILE, import.meta.url), JSON.stringify(QUEUE, null, 1));
console.log(`proposed ${next.fn} (gas ${rc2.gasUsed}) — executable in 6h`);
