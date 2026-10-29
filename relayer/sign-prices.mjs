// Zero-gas price publishing. Fetches the 14 prices, signs one payload per asset (timestamps must
// increase by 1 because lastOracleUpdate is global and strictly increasing), and writes JSON.
// Nothing is sent on-chain: a consumer carries the payload + signature in ITS transaction and pays
// that gas. This is the pull (Pyth-style) half of the oracle; push-evm.mjs remains the push half.
import { createPublicClient, http, keccak256, encodeAbiParameters, parseAbiParameters } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { ASSETS, readAsset } from "./sources.mjs";
import { writeFileSync } from "node:fs";

const ORACLE = process.env.ORACLE ?? "0x0daf541ef7e41402070bc549f91475ab368d1824";
const RPC = process.env.RPC ?? "https://arb1.arbitrum.io/rpc";
const OUT = process.env.OUT ?? "price-signed.json";
const SCALE = 1_000_000;

const pk = process.env.PRIVATE_KEY;
if (!pk) {
  console.error("PRIVATE_KEY required (signer key)");
  process.exit(1);
}
const pk2 = process.env.PRIVATE_KEY_2;
if (!pk2) {
  console.error("PRIVATE_KEY_2 required: the oracle is 2-of-3, so every payload needs two signatures");
  process.exit(1);
}
const account = privateKeyToAccount(pk.startsWith("0x") ? pk : "0x" + pk);
const account2 = privateKeyToAccount(pk2.startsWith("0x") ? pk2 : "0x" + pk2);
const pub = createPublicClient({ chain: arbitrum, transport: http(RPC) });

const DOMAIN = keccak256(new TextEncoder().encode("PLANET_PRICE_V1"));
const consumer = await pub.readContract({ address: ORACLE, abi: [{ name: "consumer", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] }], functionName: "consumer" });
const chainId = BigInt(await pub.getChainId());

const base = BigInt(Math.floor(Date.now() / 1000) + 120);
const payloads = [];
for (const asset of ASSETS) {
  const agg = await readAsset(asset);
  if (!agg.ok) {
    console.error(`#${asset.i} ${asset.sym}: skipped (${agg.reason})`);
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
  const s1 = await account.sign({ hash: digest });
  const s2 = await account2.sign({ hash: digest });
  const sig = "0x" + s1.slice(2) + s2.slice(2);
  payloads.push({
    index: Number(p.index),
    symbol: asset.sym,
    price: p.price.toString(),
    volatility: p.volatility.toString(),
    liquidity: p.liquidity.toString(),
    riskState: p.riskState,
    timestamp: p.timestamp.toString(),
    sig,
  });
}

const out = {
  oracle: ORACLE,
  core: consumer,
  chainId: Number(chainId),
  signer: account.address,
  generatedAt: new Date().toISOString(),
  payloads,
};
writeFileSync(OUT, JSON.stringify(out, null, 1));
console.log(`signed ${payloads.length} payloads -> ${OUT}`);
console.log(`oracle=${ORACLE} core=${consumer} signer=${account.address}`);
