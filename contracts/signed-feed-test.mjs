import { createPublicClient, createWalletClient, http, defineChain, parseUnits, hexToSignature } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";

const A = JSON.parse(readFileSync("./rwa-artifacts.json", "utf8"));
const RPC = "http://127.0.0.1:8545";
const chain = defineChain({ id: 31337, name: "hardhat", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const owner = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const sA = privateKeyToAccount("0x" + "11".repeat(32));
const sB = privateKeyToAccount("0x" + "22".repeat(32));
const sC = privateKeyToAccount("0x" + "33".repeat(32));
const pub = createPublicClient({ chain, transport: http(RPC) });
const w = createWalletClient({ account: owner, chain, transport: http(RPC) });
let fails = 0;
const check = (l, c, e = "") => { console.log(`${c ? "PASS" : "FAIL"}  ${l}${e ? "  " + e : ""}`); if (!c) fails++; };
const tryIt = async (fn) => { try { await fn(); return true; } catch { return false; } };

const h = await w.deployContract({ abi: A.SignedFeedAdapter.abi, bytecode: A.SignedFeedAdapter.bytecode, args: [owner.address, [sA.address, sB.address, sC.address], 2, 1n] });
const adapter = (await pub.waitForTransactionReceipt({ hash: h })).contractAddress;

const blk = await pub.getBlock();
const payload = { assetId: 1n, price1e18: parseUnits("2000", 18), quality: 0, timestamp: blk.timestamp + 1n };
const digest = await pub.readContract({ address: adapter, abi: A.SignedFeedAdapter.abi, functionName: "digest", args: [payload] });

const sign = async (acct) => {
  const sig = await acct.sign({ hash: digest });
  return sig;
};
const sigA = await sign(sA);
const sigB = await sign(sB);
const concat = (arr) => ("0x" + arr.map((s) => s.slice(2)).join("")) ;

const submit = async (p, sigs) => {
  const tx = await w.writeContract({ address: adapter, abi: A.SignedFeedAdapter.abi, functionName: "submit", args: [p, sigs] });
  const rc = await pub.waitForTransactionReceipt({ hash: tx });
  return rc.status === "success";
};

check("2-of-3 submit", await tryIt(() => submit(payload, concat([sigA, sigB]))));
let q = await pub.readContract({ address: adapter, abi: A.SignedFeedAdapter.abi, functionName: "price" });
check("price stored", q[0] === parseUnits("2000", 18) && q[1] === 0, q[0].toString() + " q" + q[1]);

check("1 signature rejected", !(await tryIt(() => submit({ ...payload, timestamp: payload.timestamp + 1n }, concat([sigA])))));
check("replay rejected", !(await tryIt(() => submit(payload, concat([sigA, sigB])))));
check("wrong asset rejected", !(await tryIt(async () => {
  const p2 = { ...payload, assetId: 2n, timestamp: payload.timestamp + 5n };
  const d2 = await pub.readContract({ address: adapter, abi: A.SignedFeedAdapter.abi, functionName: "digest", args: [p2] });
  const s1 = await sA.sign({ hash: d2 }), s2 = await sB.sign({ hash: d2 });
  return submit(p2, concat([s1, s2]));
})));
check("duplicate signer counts once", !(await tryIt(async () => {
  const p3 = { ...payload, timestamp: payload.timestamp + 9n };
  const d3 = await pub.readContract({ address: adapter, abi: A.SignedFeedAdapter.abi, functionName: "digest", args: [p3] });
  const s1 = await sA.sign({ hash: d3 });
  return submit(p3, concat([s1, s1]));
})));

// staleness: after maxAge, quality degrades to frozen
await pub.request({ method: "evm_increaseTime", params: [7 * 3600] });
await pub.request({ method: "evm_mine", params: [] });
q = await pub.readContract({ address: adapter, abi: A.SignedFeedAdapter.abi, functionName: "price" });
check("stale feed reports frozen", q[1] === 2, "quality " + q[1]);

console.log(fails === 0 ? "\nSIGNED FEED OK" : `\n${fails} FAILURES`);
process.exit(fails === 0 ? 0 : 1);
