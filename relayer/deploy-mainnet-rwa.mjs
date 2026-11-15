// Deploy and wire the RWA market on a target chain, with built-in verification.
// Reads signers from the Arbitrum index oracle so both chains share one signer set.
//
//   CHAIN=ethereum    PAXG=0x45804880De22913dAFE09f4980848ECE6EcbAf78 node deploy-mainnet-rwa.mjs
//   CHAIN=local       PAXG=<mock token>  node deploy-mainnet-rwa.mjs
//
// Idempotent: state in rwa-mainnet.json; every step is skipped if already done.
import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum, mainnet, foundry } from "viem/chains";
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const A = JSON.parse(readFileSync("./rwa-artifacts.json", "utf8"));
const STATE = "./rwa-mainnet.json";
const st = existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : {};

const CHAIN = process.env.CHAIN || "ethereum";
const CHAINS = { ethereum: mainnet, local: foundry };
const RPC = process.env.RPC || (CHAIN === "local" ? "http://127.0.0.1:8545" : "https://eth.llamarpc.com");
const chain = CHAINS[CHAIN] || mainnet;
const PAXG = process.env.PAXG;
const USDC = process.env.USDC || (CHAIN === "ethereum" ? "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" : st.usdc || "");
const ARB_RPC = process.env.ARB_RPC || "https://arb1.arbitrum.io/rpc";
const ORACLE = process.env.ORACLE || "0x0daf541ef7e41402070bc549f91475ab368d1824";
const LTV = BigInt(process.env.LTV_BPS || 7000);
const CAUTION_LTV = BigInt(process.env.CAUTION_LTV_BPS || 6000);
const LIQ = BigInt(process.env.LIQ_BPS || 8000);
const ASSET_ID = BigInt(process.env.ASSET_ID || 0);

function key() {
  if (process.env.PRIVATE_KEY) return process.env.PRIVATE_KEY;
  const env = readFileSync("E:/Protocol Bank/.env.local", "utf8");
  return env.match(/^AGENT_TEST_WALLET_PRIVATE_KEY=(.*)$/m)[1].trim().replace(/^["']|["']$/g, "");
}

const pub = createPublicClient({ chain, transport: http(RPC) });
const account = privateKeyToAccount(key().startsWith("0x") ? key() : "0x" + key());
const wallet = createWalletClient({ account, chain, transport: http(RPC) });

// one signer set for both chains: read it from the index oracle on Arbitrum
async function readSigners() {
  if (process.env.SIGNERS) return process.env.SIGNERS.split(",").map((s) => s.trim());
  const arb = createPublicClient({ chain: arbitrum, transport: http(ARB_RPC) });
  const abi = parseAbi(["function signerCount() view returns (uint256)", "function signers(uint256) view returns (address)"]);
  const n = Number(await arb.readContract({ address: ORACLE, abi, functionName: "signerCount" }));
  const out = [];
  for (let i = 0; i < n; i++) out.push(await arb.readContract({ address: ORACLE, abi, functionName: "signers", args: [BigInt(i)] }));
  return out;
}

const save = () => writeFileSync(STATE, JSON.stringify(st, null, 1));
const wait = async (h) => { const rc = await pub.waitForTransactionReceipt({ hash: h }); if (rc.status !== "success") throw new Error("tx failed " + h); return rc; };

console.log(`chain: ${chain.name} (${chain.id}) | payer: ${account.address}`);
const bal = await pub.getBalance({ address: account.address });
console.log(`balance: ${Number(bal) / 1e18} ETH`);

// 1) registry + pool (reuse from the Arbitrum deployment record when on Arbitrum, else deploy)
if (!st.registry) {
  const h = await wallet.deployContract({ abi: A.CollateralRegistry.abi, bytecode: A.CollateralRegistry.bytecode, args: [account.address] });
  st.registry = (await wait(h)).contractAddress;
  save();
  console.log("registry:", st.registry);
} else console.log("registry exists:", st.registry);

if (!st.pool) {
  if (!USDC) { console.error("USDC address required"); process.exit(1); }
  const h = await wallet.deployContract({ abi: A.LendingPool.abi, bytecode: A.LendingPool.bytecode, args: [USDC, st.registry, account.address] });
  st.pool = (await wait(h)).contractAddress;
  save();
  console.log("pool:", st.pool);
} else console.log("pool exists:", st.pool);

// 2) the signed feed adapter for this asset
if (!st.adapter) {
  const signers = await readSigners();
  if (signers.length < 2) { console.error("need at least 2 signers from the index oracle"); process.exit(1); }
  console.log("signers:", signers.join(", "));
  const h = await wallet.deployContract({
    abi: A.SignedFeedAdapter.abi, bytecode: A.SignedFeedAdapter.bytecode,
    args: [account.address, signers, 2, ASSET_ID],
  });
  st.adapter = (await wait(h)).contractAddress;
  st.signers = signers;
  save();
  console.log("adapter:", st.adapter);
} else console.log("adapter exists:", st.adapter);

// 3) wire the collateral
if (PAXG) {
  const regAbi = A.CollateralRegistry.abi;
  const cur = await pub.readContract({ address: st.registry, abi: regAbi, functionName: "assets", args: [PAXG] });
  const enabled = cur[0];
  if (!enabled) {
    const h = await wallet.writeContract({ address: st.registry, abi: regAbi, functionName: "setAsset", args: [PAXG, st.adapter, LTV, CAUTION_LTV, LIQ] });
    await wait(h);
    console.log("setAsset:", PAXG, "ltv", LTV.toString(), "caution", CAUTION_LTV.toString(), "liq", LIQ.toString());
  } else {
    console.log("asset already enabled:", PAXG, "ltv", cur[2].toString());
  }
  st.asset = PAXG;
  save();
} else {
  console.log("PAXG not provided - registry deployed without a collateral");
}

// 3b) safety: pause the pool unless explicitly told not to (local dev only)
if (process.env.PAUSE !== "0" || CHAIN !== "local") {
  if (process.env.PAUSE === "0") { /* local dev */ }
  else {
    const isPaused = await pub.readContract({ address: st.pool, abi: A.LendingPool.abi, functionName: "paused" });
    if (!isPaused) {
      const h = await wallet.writeContract({ address: st.pool, abi: A.LendingPool.abi, functionName: "setPaused", args: [true] });
      await wait(h);
      console.log("pool paused: yes (nothing can be deposited until governance unpauses)");
    } else console.log("pool already paused");
  }
}
// 4) verification pass
console.log("\n--- verification ---");
const regAbi = A.CollateralRegistry.abi;
const poolAbi = A.LendingPool.abi;
const feedAbi = A.SignedFeedAdapter.abi;
const [paused, owner, count] = await Promise.all([
  pub.readContract({ address: st.pool, abi: poolAbi, functionName: "paused" }),
  pub.readContract({ address: st.registry, abi: regAbi, functionName: "owner" }),
  pub.readContract({ address: st.registry, abi: regAbi, functionName: "count" }),
]);
console.log("pool paused:", paused, "| registry owner:", owner, "| assets listed:", count.toString());
if (PAXG) {
  const a = await pub.readContract({ address: st.registry, abi: regAbi, functionName: "assets", args: [PAXG] });
  console.log("asset enabled:", a[0], "| feed:", a[1]);
  try {
    const ltv = await pub.readContract({ address: st.registry, abi: regAbi, functionName: "ltvOf", args: [PAXG] });
    console.log("effective ltv:", ltv[0].toString(), "| quality:", ltv[1]);
  } catch {
    console.log("effective ltv: unavailable until the first signed payload lands (feed price is 0)");
  }
}
const feed = await pub.readContract({ address: st.adapter, abi: feedAbi, functionName: "price" });
console.log("adapter price:", feed[0].toString(), "quality:", feed[1], "(0,2 until the first signed payload lands)");
const [threshold, signerCount] = await Promise.all([
  pub.readContract({ address: st.adapter, abi: feedAbi, functionName: "threshold" }),
  pub.readContract({ address: st.adapter, abi: feedAbi, functionName: "signerCount" }),
]);
console.log("adapter threshold:", threshold.toString(), "/", signerCount.toString());

console.log("\nnext: 1) submit the first payload with sign-feed.mjs  2) allowlist lenders  3) hand ownership to the timelock  4) unpause");
