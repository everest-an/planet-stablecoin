// Deploy the RWA market (registry + pool) to any EVM chain and wire the first collateral.
// Usage: RPC=... PRIVATE_KEY=... GOLD=0x... FEED=0x... node deploy-rwa.mjs
// The feed must implement IPriceFeed: price() -> (uint256 price1e18, uint8 quality).
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum, arbitrumSepolia } from "viem/chains";
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const A = JSON.parse(readFileSync("./rwa-artifacts.json", "utf8"));
const RPC = process.env.RPC || "https://arbitrum-sepolia-rpc.publicnode.com";
const CHAIN = process.env.CHAIN === "arbitrum-one" ? arbitrum : arbitrumSepolia;
const USDC = process.env.USDC || "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"; // Arbitrum Sepolia test USDC
const GOLD = process.env.GOLD; // tokenized commodity token address
const FEED = process.env.FEED; // IPriceFeed address
const STATE = "./rwa-deployment.json";

function key() {
  if (process.env.PRIVATE_KEY) return process.env.PRIVATE_KEY;
  const env = readFileSync("E:/Protocol Bank/.env.local", "utf8");
  return env.match(/^AGENT_TEST_WALLET_PRIVATE_KEY=(.*)$/m)[1].trim().replace(/^["']|["']$/g, "");
}

const pub = createPublicClient({ chain: CHAIN, transport: http(RPC) });
const account = privateKeyToAccount(key().startsWith("0x") ? key() : "0x" + key());
const wallet = createWalletClient({ account, chain: CHAIN, transport: http(RPC) });
const st = existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : {};

console.log("payer:", account.address, "| chain:", CHAIN.name);

const deploy = async (name, args, keyName) => {
  if (st[keyName]) { console.log(keyName, "exists:", st[keyName]); return st[keyName]; }
  const h = await wallet.deployContract({ abi: A[name].abi, bytecode: A[name].bytecode, args });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  st[keyName] = rc.contractAddress;
  writeFileSync(STATE, JSON.stringify(st, null, 1));
  console.log(keyName, ":", rc.contractAddress, "gas", rc.gasUsed);
  return rc.contractAddress;
};

const registry = await deploy("CollateralRegistry", [account.address], "registry");
const pool = await deploy("LendingPool", [USDC, registry, account.address], "pool");
const CORE = process.env.PPI_CORE || "0x61de052af7cb7dc957a07b1e6298152bb851cbbb";
await deploy("PPIFeedAdapter", [CORE, BigInt(process.env.USD_PER_INDEX || 1000)], "feedAdapter");
console.log("usdc:", USDC, "| registry:", registry, "| pool:", pool);

// wire the first collateral when addresses are provided (owner = this account for the bootstrap;
// hand ownership to the timelock before any real money)
if (GOLD && FEED) {
  const hash = await wallet.writeContract({
    address: registry, abi: A.CollateralRegistry.abi, functionName: "setAsset",
    args: [GOLD, FEED, Number(process.env.LTV_BPS || 7000), Number(process.env.CAUTION_LTV_BPS || 6000), Number(process.env.LIQ_BPS || 8000)],
  });
  const rc = await pub.waitForTransactionReceipt({ hash });
  console.log("setAsset:", rc.status === "success" ? "ok" : "FAILED", "| ltv", process.env.LTV_BPS || 7000);
} else {
  console.log("GOLD/FEED not provided - registry deployed without a collateral");
}

const ph = await wallet.writeContract({ address: pool, abi: A.LendingPool.abi, functionName: "setPaused", args: [true] });
const prc = await pub.waitForTransactionReceipt({ hash: ph });
console.log("pool paused:", prc.status === "success" ? "yes (nobody can deposit until governance unpauses)" : "FAILED");
console.log("state file:", STATE);
console.log("next: allowlist lenders/borrowers (setAllowed), setRate, then hand ownership to the timelock");
