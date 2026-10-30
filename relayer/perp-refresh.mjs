// Refresh the Sepolia demo index: sign the 14 prices and submit them, paying one gas per asset.
// Idle cost is zero; a run costs a handful of Sepolia gas (testnet ETH, no value).
import { createPublicClient, createWalletClient, http, keccak256, encodeAbiParameters, parseAbiParameters, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { readFileSync } from "node:fs";
import { ASSETS, readAsset } from "./sources.mjs";

const RPC = process.env.RPC || "https://ethereum-sepolia-rpc.publicnode.com";
const CORE = process.env.CORE || "0xe0aeb4c5a15a6e09e0dcdaf552083bd253cfc64d";
const ORACLE = process.env.ORACLE || "0xa1fdb9f95210af1d968872f6fc86f623a3e3017c";
const SCALE = 1_000_000;

const pk = process.env.PRIVATE_KEY;
if (!pk) {
  console.error("PRIVATE_KEY required");
  process.exit(1);
}
const account = privateKeyToAccount(pk.startsWith("0x") ? pk : "0x" + pk);
const pub = createPublicClient({ chain: sepolia, transport: http(RPC, { timeout: 120000, retryCount: 4, retryDelay: 3000 }) });
const wallet = createWalletClient({ account, chain: sepolia, transport: http(RPC, { timeout: 120000, retryCount: 4, retryDelay: 3000 }) });

const CORE_ABI = [
  { name: "lastOracleUpdate", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { name: "currentPpi", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  {
    name: "updatePriceSigned",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "p", type: "tuple", components: [
        { name: "index", type: "uint256" }, { name: "price", type: "uint64" }, { name: "volatility", type: "uint64" },
        { name: "liquidity", type: "uint64" }, { name: "riskState", type: "uint8" }, { name: "timestamp", type: "uint64" },
      ] },
      { name: "sigs", type: "bytes" },
    ],
    outputs: [],
  },
];
const ORACLE_ABI = [{ name: "consumer", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] }];

const DOMAIN = keccak256(new TextEncoder().encode("PLANET_PRICE_V1"));
const chainId = BigInt(await pub.getChainId());
const consumer = await pub.readContract({ address: ORACLE, abi: ORACLE_ABI, functionName: "consumer" });
const last = await pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "lastOracleUpdate" });
const age = Math.floor(Date.now() / 1000) - Number(last);
console.log(`core ${CORE} | oracle ${ORACLE} | last update ${age}s ago | signer ${account.address}`);

const base = BigInt(Number((await pub.getBlock()).timestamp) + 120);
let ok = 0, failed = 0;
for (const asset of ASSETS) {
  const agg = await readAsset(asset);
  if (!agg.ok) {
    console.log(`#${asset.i} ${asset.sym}: skipped (${agg.reason})`);
    failed++;
    continue;
  }
  const p = {
    index: BigInt(asset.i),
    price: BigInt(Math.round(agg.price * SCALE)),
    volatility: 0n,
    liquidity: BigInt(SCALE),
    riskState: Number(agg.riskState ?? 0),
    timestamp: base + BigInt(asset.i),
  };
  const digest = keccak256(
    encodeAbiParameters(parseAbiParameters("bytes32, address, uint256, address, uint256, uint64, uint64, uint64, uint8, uint64"), [
      DOMAIN, ORACLE, chainId, consumer, p.index, p.price, p.volatility, p.liquidity, p.riskState, p.timestamp,
    ]),
  );
  const sig = await account.sign({ hash: digest });
  try {
    const h = await wallet.writeContract({ address: CORE, abi: CORE_ABI, functionName: "updatePriceSigned", args: [p, sig] });
    const rc = await pub.waitForTransactionReceipt({ hash: h });
    if (rc.status !== "success") throw new Error("reverted");
    ok++;
  } catch (e) {
    console.log(`#${asset.i} ${asset.sym} failed: ${(e.shortMessage || e.message).slice(0, 80)}`);
    failed++;
  }
}
const ppi = await pub.readContract({ address: CORE, abi: CORE_ABI, functionName: "currentPpi" });
const bal = await pub.getBalance({ address: account.address });
console.log(`pushed ${ok}, failed ${failed} | PPI ${Number(ppi) / 1e6} | balance ${formatUnits(bal, 18)} ETH`);
process.exit(failed > 0 && ok === 0 ? 1 : 0);
