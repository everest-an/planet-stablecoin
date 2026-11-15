// Sign a price payload for any SignedFeedAdapter on any chain, and optionally submit it.
// Usage (local):  ADAPTER=0x.. CHAIN_ID=1 ASSET_ID=0 PRICE=2000 QUALITY=0 node sign-feed.mjs
// Usage (submit): + RPC=... PRIVATE_KEY=... (the relayer pays gas; the signers authorise)
import { keccak256, encodeAbiParameters, parseAbiParameters, createWalletClient, createPublicClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";

function env(k, fallback) {
  if (process.env[k]) return process.env[k];
  try {
    const f = readFileSync("E:/Protocol Bank/.env.local", "utf8");
    const m = f.match(new RegExp("^" + k + "=(.*)$", "m"));
    return m ? m[1].trim().replace(/^["']|["']$/g, "") : fallback;
  } catch { return fallback; }
}

const ADAPTER = process.env.ADAPTER;
const CHAIN_ID = BigInt(process.env.CHAIN_ID || "1");
const ASSET_ID = BigInt(process.env.ASSET_ID || "0");
const PRICE = BigInt(process.env.PRICE || "0"); // 1e18 USD per unit
const QUALITY = Number(process.env.QUALITY || "0");
const SUBMIT = Boolean(process.env.RPC && process.env.PRIVATE_KEY);

if (!ADAPTER || PRICE === 0n) { console.error("ADAPTER and PRICE are required"); process.exit(1); }

const DOMAIN = keccak256(new TextEncoder().encode("PLANET_FEED_V1"));
const timestamp = BigInt(Math.floor(Date.now() / 1000) + 60); // slight lead, the adapter only needs monotonic

const digest = keccak256(
  encodeAbiParameters(
    parseAbiParameters("bytes32, address, uint256, uint256, uint256, uint8, uint64"),
    [DOMAIN, ADAPTER, CHAIN_ID, ASSET_ID, PRICE, QUALITY, timestamp]
  )
);

const keys = [env("ORACLE_SIGNER_KEY"), env("ORACLE_SIGNER_KEY_2")].filter(Boolean);
if (keys.length < 2) { console.error("need two signer keys (ORACLE_SIGNER_KEY, ORACLE_SIGNER_KEY_2)"); process.exit(1); }

const sigs = [];
for (const k of keys.slice(0, 2)) {
  const acct = privateKeyToAccount(k.startsWith("0x") ? k : "0x" + k);
  const sig = await acct.sign({ hash: digest });
  sigs.push(sig);
  console.log("signer:", acct.address);
}
const packed = "0x" + sigs.map((s) => s.slice(2)).join("");
const payload = { assetId: ASSET_ID, price1e18: PRICE, quality: QUALITY, timestamp };
console.log("digest:", digest);
console.log("payload:", JSON.stringify(payload, (k, v) => (typeof v === "bigint" ? v.toString() : v)));
console.log("sigs:", packed.slice(0, 24) + "…(" + packed.length + " chars)");

if (!SUBMIT) {
  console.log("dry run - set RPC and PRIVATE_KEY to submit on-chain");
  process.exit(0);
}

const ABI = [
  { name: "submit", type: "function", stateMutability: "nonpayable", inputs: [
    { name: "p", type: "tuple", components: [
      { name: "assetId", type: "uint256" }, { name: "price1e18", type: "uint256" },
      { name: "quality", type: "uint8" }, { name: "timestamp", type: "uint64" }] },
    { name: "sigs", type: "bytes" }], outputs: [] },
  { name: "lastUpdate", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
];
const chain = { id: Number(CHAIN_ID), name: "target", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [process.env.RPC] } } };
const acct = privateKeyToAccount((process.env.PRIVATE_KEY.startsWith("0x") ? process.env.PRIVATE_KEY : "0x" + process.env.PRIVATE_KEY));
const pub = createPublicClient({ chain, transport: http(process.env.RPC) });
const wal = createWalletClient({ account: acct, chain, transport: http(process.env.RPC) });
const h = await wal.writeContract({ address: ADAPTER, abi: ABI, functionName: "submit", args: [payload, packed] });
const rc = await pub.waitForTransactionReceipt({ hash: h });
console.log("submit:", rc.status, "gas", rc.gasUsed);
