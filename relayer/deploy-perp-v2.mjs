// Deploy the v2 perp (guardian emergency pause + TWAP liquidation gate) and restart the timelock
// queue. Modeled on deploy-perp-mainnet.mjs: idempotent, resumable, CI-safe.
//
// After this runs, the daily timelock-queue workflow advances setParams -> setKeeper -> setTreasury
// -> setGuardian, one 6h round at a time.
import { createPublicClient, createWalletClient, http, encodeFunctionData } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const A = JSON.parse(readFileSync("./perp-artifacts.json", "utf8"));
const STATE = "./perp-mainnet.json";
const QUEUE = "../docs/timelock-queue.json";
const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
const CORE = "0x61de052af7cb7dc957a07b1e6298152bb851cbbb";
const TIMELOCK = "0xA1Fdb9F95210AF1d968872F6FC86F623A3e3017C";

function key() {
  if (process.env.PRIVATE_KEY) return process.env.PRIVATE_KEY;
  const env = readFileSync("E:/Protocol Bank/.env.local", "utf8");
  return env.match(/^AGENT_TEST_WALLET_PRIVATE_KEY=(.*)$/m)[1].trim().replace(/^["']|["']$/g, "");
}
const RPC = process.env.RPC || "https://arbitrum-one-rpc.publicnode.com";
const pub = createPublicClient({ chain: arbitrum, transport: http(RPC) });
const k = key();
const account = privateKeyToAccount(k.startsWith("0x") ? k : "0x" + k);
const wallet = createWalletClient({ account, chain: arbitrum, transport: http(RPC) });

const TL_ABI = [
  { name: "propose", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "bytes" }], outputs: [] },
  { name: "eta", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
];

const state = existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : {};
console.log("payer:", account.address, "balance:", (await pub.getBalance({ address: account.address })).toString(), "wei");

// 1) deploy the TWAP-aware price source
if (!state.perpV2Source) {
  const h = await wallet.deployContract({
    abi: A.PPIPriceSource.abi, bytecode: A.PPIPriceSource.bytecode,
    args: [CORE, 1000n], // USD per 1.0 PPI
  });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  state.perpV2Source = rc.contractAddress;
  console.log("price source v2:", rc.contractAddress, "gas", rc.gasUsed);
} else {
  console.log("price source v2 already deployed:", state.perpV2Source);
}

// 2) deploy the perp, owned by the timelock from the first block
if (!state.perpV2) {
  const h = await wallet.deployContract({
    abi: A.PPIPerp.abi, bytecode: A.PPIPerp.bytecode,
    args: [USDC, state.perpV2Source, TIMELOCK],
  });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  state.perpV2 = rc.contractAddress;
  console.log("perp v2:", rc.contractAddress, "gas", rc.gasUsed);
  writeFileSync(STATE, JSON.stringify(state, null, 1));
} else {
  console.log("perp v2 already deployed:", state.perpV2);
}

// 3) restart the queue for the new contract and propose the params round
const q = JSON.parse(readFileSync(QUEUE, "utf8")).map((x) => ({ ...x, proposed: false, done: false }));
writeFileSync(QUEUE, JSON.stringify(q, null, 1));

const eta = await pub.readContract({ address: TIMELOCK, abi: TL_ABI, functionName: "eta" });
if (eta === 0n) {
  const data = encodeFunctionData({ abi: A.PPIPerp.abi, functionName: "setParams", args: [30_000n, 10n, 10n, 1_000n] });
  const h = await wallet.writeContract({ address: TIMELOCK, abi: TL_ABI, functionName: "propose", args: [state.perpV2, data] });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  console.log("setParams proposed for perp v2 (gas", rc.gasUsed + ") — executable in 6h");
} else {
  console.log("a proposal is already pending (eta", eta.toString() + "); the queue will advance it");
}
console.log("NEXT: update perp-mainnet.json consumers (API, monitor, keeper, refresh) to the v2 addresses");
