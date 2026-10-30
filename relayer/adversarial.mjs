import { createPublicClient, createWalletClient, http, defineChain, parseUnits, formatUnits, keccak256, encodeAbiParameters, parseAbiParameters } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";

const A = JSON.parse(readFileSync("./perp-artifacts.json", "utf8"));
const I = JSON.parse(readFileSync("./artifacts.json", "utf8"));
const RPC = "http://127.0.0.1:8545";
const chain = defineChain({ id: 31337, name: "hardhat", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const a0 = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const a1 = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const pub = createPublicClient({ chain, transport: http(RPC) });
const w0 = createWalletClient({ account: a0, chain, transport: http(RPC) });
const w1 = createWalletClient({ account: a1, chain, transport: http(RPC) });
const read = (a, abi, fn, args = []) => pub.readContract({ address: a, abi, functionName: fn, args });
const send = async (w, a, abi, fn, args = []) => {
  const h = await w.writeContract({ address: a, abi, functionName: fn, args });
  const rc = await pub.waitForTransactionReceipt({ hash: h });
  if (rc.status !== "success") throw new Error(fn + " reverted");
  return rc;
};
const deploy = async (w, name, args, abiSet) => {
  const h = await w.deployContract({ abi: abiSet[name].abi, bytecode: abiSet[name].bytecode, args });
  return (await pub.waitForTransactionReceipt({ hash: h })).contractAddress;
};
let fails = 0;
const check = (l, c, x = "") => { console.log(`${c ? "PASS" : "FAIL"}  ${l}${x ? "  " + x : ""}`); if (!c) fails++; };

// ---- A. donation does not move the share price ----
const price = await deploy(w0, "MockPrice", [parseUnits("1000", 18), 0], A);
const usdc = await deploy(w0, "MockUSDC", [], A);
const perp = await deploy(w0, "PPIPerp", [usdc, price, a0.address], A);
await send(w0, usdc, A.MockUSDC.abi, "mint", [a0.address, parseUnits("100000", 6)]);
await send(w0, usdc, A.MockUSDC.abi, "approve", [perp, 2n ** 255n]);
await send(w0, perp, A.PPIPerp.abi, "deposit", [parseUnits("10000", 6)]);
const sp0 = await read(perp, A.PPIPerp.abi, "sharePrice");
await send(w0, usdc, A.MockUSDC.abi, "transfer", [perp, parseUnits("50000", 6)]); // donation
const sp1 = await read(perp, A.PPIPerp.abi, "sharePrice");
check("donation does not inflate sharePrice", sp0 === sp1, `${formatUnits(sp0, 6)} -> ${formatUnits(sp1, 6)}`);
const balAfter = await read(usdc, A.MockUSDC.abi, "balanceOf", [perp]);
const paAfter = await read(perp, A.PPIPerp.abi, "poolAssets");
check("donation breaks the invariant (expected - it is not poolAssets)", balAfter !== paAfter, `balance ${formatUnits(balAfter, 6)} vs pool ${formatUnits(paAfter, 6)}`);

// ---- B. oracle replay is rejected ----
const core = await deploy(w0, "PlanetCore", [a0.address, "0x0000000000000000000000000000000000000000"], I);
const oracle = await deploy(w0, "SignedPriceOracle", [a0.address, [a0.address], 1], I);
await send(w0, oracle, I.SignedPriceOracle.abi, "setConsumer", [core]);
await send(w0, core, I.PlanetCore.abi, "setOracle", [oracle]);
for (let i = 0; i < 7; i++) {
  await send(w0, core, I.PlanetCore.abi, "setAsset", [BigInt(i), i === 6 ? 100000n : 150000n, 1000000n, 1000000n]);
}
const DOMAIN = keccak256(new TextEncoder().encode("PLANET_PRICE_V1"));
const chainId = BigInt(await pub.getChainId());
const consumer = await read(oracle, I.SignedPriceOracle.abi, "consumer");
const ts = BigInt(Number((await pub.getBlock()).timestamp) + 300);
const p = { index: 0n, price: 1010000n, volatility: 0n, liquidity: 1000000n, riskState: 0, timestamp: ts };
const digest = keccak256(encodeAbiParameters(parseAbiParameters("bytes32, address, uint256, address, uint256, uint64, uint64, uint64, uint8, uint64"), [DOMAIN, oracle, chainId, consumer, p.index, p.price, p.volatility, p.liquidity, p.riskState, p.timestamp]));
const sig = await a0.sign({ hash: digest });
await send(w0, core, I.PlanetCore.abi, "updatePriceSigned", [p, sig]);
let replayed = false;
try { await send(w0, core, I.PlanetCore.abi, "updatePriceSigned", [p, sig]); replayed = true; } catch {}
check("replaying the same signed payload is rejected", !replayed);

// ---- C. liquidating a healthy position is rejected ----
const w1c = createWalletClient({ account: a1, chain, transport: http(RPC) });
await send(w1c, usdc, A.MockUSDC.abi, "mint", [a1.address, parseUnits("10000", 6)]);
await send(w1c, usdc, A.MockUSDC.abi, "approve", [perp, 2n ** 255n]);
await send(w1c, perp, A.PPIPerp.abi, "open", [parseUnits("2000", 6), parseUnits("1000", 6)]); // 2x, healthy
let griefed = false;
try { await send(w1c, perp, A.PPIPerp.abi, "liquidate", [a1.address, 0n]); griefed = true; } catch {}
check("liquidating a healthy position is rejected", !griefed);

// ---- D. a non-relayer cannot push a price ----
let pushed = false;
try { await send(w1c, core, I.PlanetCore.abi, "updatePrice", [0n, 9990000n, 0n, 1000000n, 0, ts + 100n]); pushed = true; } catch {}
check("updatePrice is closed to non-relayers (relayer == 0)", !pushed);

console.log(`\n${fails === 0 ? "ALL ADVERSARIAL CHECKS PASSED" : fails + " FAILURE(S)"}`);
process.exit(fails ? 1 : 0);
