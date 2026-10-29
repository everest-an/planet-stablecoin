// Consumer side of the pull oracle: take the signed feed and submit it on-chain, paying the gas.
// This is what a venue would embed in its own transaction; run standalone it acts as a keeper.
//
// Usage: node submit-signed.mjs [--dry-run]
// Env:   RPC (default Arbitrum One), API (default the public feed), PRIVATE_KEY (payer)
import { createPublicClient, createWalletClient, http, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";

const RPC = process.env.RPC ?? "https://arb1.arbitrum.io/rpc";
const API = process.env.API ?? "https://ppppp.space/api/v1/price-signed";
const DRY = process.argv.includes("--dry-run");
const CORE_ABI = [
  { name: "lastOracleUpdate", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  {
    name: "updatePriceSigned",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "p",
        type: "tuple",
        components: [
          { name: "index", type: "uint256" },
          { name: "price", type: "uint64" },
          { name: "volatility", type: "uint64" },
          { name: "liquidity", type: "uint64" },
          { name: "riskState", type: "uint8" },
          { name: "timestamp", type: "uint64" },
        ],
      },
      { name: "sigs", type: "bytes" },
    ],
    outputs: [],
  },
];

const feed = await (await fetch(API, { headers: { "cache-control": "no-cache" } })).json();
if (!feed.payloads?.length) {
  console.error("feed empty:", JSON.stringify(feed).slice(0, 200));
  process.exit(1);
}
const core = feed.core;
const pub = createPublicClient({ chain: arbitrum, transport: http(RPC) });
const last = await pub.readContract({ address: core, abi: CORE_ABI, functionName: "lastOracleUpdate" });
console.log(`feed generated ${feed.generatedAt} | core ${core} | lastOracleUpdate ${last}`);

const usable = feed.payloads.filter((p) => BigInt(p.timestamp) > last);
console.log(`payloads: ${feed.payloads.length} | newer than on-chain: ${usable.length}`);
if (!usable.length) {
  console.log("nothing to submit — the on-chain value is already at or past this batch");
  process.exit(0);
}

if (DRY) {
  console.log("dry run — would submit", usable.length, "updates");
  process.exit(0);
}

const pk = process.env.PRIVATE_KEY;
if (!pk) {
  console.error("PRIVATE_KEY required to submit (this is the party that pays gas)");
  process.exit(1);
}
const account = privateKeyToAccount(pk.startsWith("0x") ? pk : "0x" + pk);
const wallet = createWalletClient({ account, chain: arbitrum, transport: http(RPC) });
console.log("payer:", account.address, "balance:", formatUnits(await pub.getBalance({ address: account.address }), 18), "ETH");

let ok = 0;
for (const p of usable) {
  const payload = {
    index: BigInt(p.index),
    price: BigInt(p.price),
    volatility: BigInt(p.volatility),
    liquidity: BigInt(p.liquidity),
    riskState: p.riskState,
    timestamp: BigInt(p.timestamp),
  };
  try {
    const hash = await wallet.writeContract({
      address: core,
      abi: CORE_ABI,
      functionName: "updatePriceSigned",
      args: [payload, p.sig],
    });
    const rc = await pub.waitForTransactionReceipt({ hash });
    if (rc.status !== "success") throw new Error("reverted " + hash);
    ok++;
    console.log(`#${p.index} ${p.symbol} -> ${p.price} (gas ${rc.gasUsed})`);
  } catch (e) {
    console.error(`#${p.index} ${p.symbol} FAILED: ${e.shortMessage || e.message}`);
  }
}
console.log(`submitted ${ok}/${usable.length}`);
