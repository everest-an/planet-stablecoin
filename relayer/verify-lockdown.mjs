// Executes the pending setRelayer(0) proposal once its delay has passed, then proves the lockdown:
// the relayer is the zero address and a direct updatePrice call is rejected.
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { readFileSync } from "node:fs";

const D = JSON.parse(readFileSync(new URL("../docs/mainnet-deployment.json", import.meta.url), "utf8"));
const RPC = process.env.RPC || "https://arb1.arbitrum.io/rpc";
const ZERO = "0x0000000000000000000000000000000000000000";

const TIMELOCK_ABI = [
  { name: "eta", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { name: "execute", type: "function", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "bool" }] },
];
const CORE_ABI = [
  { name: "relayer", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "assetCount", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    name: "updatePrice",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "index", type: "uint256" }, { name: "price", type: "uint64" }, { name: "volatility", type: "uint64" },
      { name: "liquidity", type: "uint64" }, { name: "riskState", type: "uint8" }, { name: "timestamp", type: "uint64" },
    ],
    outputs: [],
  },
];

function key() {
  if (process.env.PRIVATE_KEY) return process.env.PRIVATE_KEY;
  const env = readFileSync("E:/Protocol Bank/.env.local", "utf8");
  return env.match(/^AGENT_TEST_WALLET_PRIVATE_KEY=(.*)$/m)[1].trim().replace(/^["']|["']$/g, "");
}

const pub = createPublicClient({ chain: arbitrum, transport: http(RPC) });
const k = key();
const account = privateKeyToAccount(k.startsWith("0x") ? k : "0x" + k);
const wallet = createWalletClient({ account, chain: arbitrum, transport: http(RPC) });

let relayer = await pub.readContract({ address: D.core, abi: CORE_ABI, functionName: "relayer" });
console.log("relayer now:", relayer);

if (relayer !== ZERO) {
  const eta = await pub.readContract({ address: D.timelock, abi: TIMELOCK_ABI, functionName: "eta" });
  const now = BigInt(Math.floor(Date.now() / 1000));
  if (eta === 0n) {
    console.error("FAIL: relayer is set and there is no pending proposal to clear it");
    process.exit(1);
  }
  if (now < eta) {
    console.log(`waiting: executable at ${new Date(Number(eta) * 1000).toISOString()}`);
    process.exit(0);
  }
  const h = await wallet.writeContract({ address: D.timelock, abi: TIMELOCK_ABI, functionName: "execute" });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  if (rc.status !== "success") {
    console.error("FAIL: execute reverted");
    process.exit(1);
  }
  console.log("executed", h, "gas", rc.gasUsed);
  relayer = await pub.readContract({ address: D.core, abi: CORE_ABI, functionName: "relayer" });
}

if (relayer !== ZERO) {
  console.error("FAIL: relayer is still", relayer);
  process.exit(1);
}
console.log("PASS: relayer is the zero address");

// Prove the single-key write path is closed: a direct updatePrice must revert.
const ts = BigInt(Math.floor(Date.now() / 1000) + 60);
try {
  await pub.simulateContract({
    address: D.core,
    abi: CORE_ABI,
    functionName: "updatePrice",
    args: [0n, 100000000n, 0n, 1000000n, 0, ts],
    account: account.address,
  });
  console.error("FAIL: updatePrice was accepted from a non-relayer — the lockdown did not take");
  process.exit(1);
} catch (e) {
  console.log("PASS: direct updatePrice rejected —", (e.shortMessage || e.message).slice(0, 60));
}
