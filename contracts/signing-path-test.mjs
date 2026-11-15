import { createPublicClient, createWalletClient, http, defineChain, keccak256, encodeAbiParameters, parseAbiParameters, toBytes, parseUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";

const A = JSON.parse(readFileSync("./rwa-artifacts.json", "utf8"));
const RPC = "http://127.0.0.1:8545";
const chain = defineChain({ id: 31337, name: "hardhat", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const owner = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const sA = privateKeyToAccount("0x" + "44".repeat(32));
const sB = privateKeyToAccount("0x" + "55".repeat(32));
const pub = createPublicClient({ chain, transport: http(RPC) });
const w = createWalletClient({ account: owner, chain, transport: http(RPC) });
let fails = 0;
const check = (l, c, e = "") => { console.log(`${c ? "PASS" : "FAIL"}  ${l}${e ? "  " + e : ""}`); if (!c) fails++; };

const h = await w.deployContract({ abi: A.SignedFeedAdapter.abi, bytecode: A.SignedFeedAdapter.bytecode, args: [owner.address, [sA.address, sB.address], 2, 7n] });
const adapter = (await pub.waitForTransactionReceipt({ hash: h })).contractAddress;

const blk = await pub.getBlock();
const payload = { assetId: 7n, price1e18: parseUnits("2000", 18), quality: 0, timestamp: blk.timestamp + 1n };

// off-chain digest exactly as sign-feed.mjs computes it
const DOMAIN = keccak256(toBytes("PLANET_FEED_V1"));
const offChain = keccak256(
  encodeAbiParameters(
    parseAbiParameters("bytes32, address, uint256, uint256, uint256, uint8, uint64"),
    [DOMAIN, adapter, 31337n, payload.assetId, payload.price1e18, payload.quality, payload.timestamp]
  )
);
const onChain = await pub.readContract({ address: adapter, abi: A.SignedFeedAdapter.abi, functionName: "digest", args: [payload] });
check("off-chain digest == on-chain digest", offChain === onChain, offChain.slice(0, 12) + "…");

const s1 = await sA.sign({ hash: offChain });
const s2 = await sB.sign({ hash: offChain });
const tx = await w.writeContract({ address: adapter, abi: A.SignedFeedAdapter.abi, functionName: "submit", args: [payload, "0x" + s1.slice(2) + s2.slice(2)] });
const rc = await pub.waitForTransactionReceipt({ hash: tx });
check("submit with signatures produced from the off-chain digest", rc.status === "success");
const q = await pub.readContract({ address: adapter, abi: A.SignedFeedAdapter.abi, functionName: "price" });
check("price readable after submit", q[0] === payload.price1e18 && q[1] === 0, q[0].toString());

console.log(fails === 0 ? "\nSIGNING PATH VERIFIED" : `\n${fails} FAILURES`);
process.exit(fails === 0 ? 0 : 1);
