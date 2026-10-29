// Executes the pending timelock proposal (setOracle) after the 6h delay.
// Run once, after the `eta` printed by propose-oracle.mjs. Idempotent enough: if it is not yet
// executable the timelock reverts and nothing changes.
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { readFileSync } from "node:fs";

const A = JSON.parse(readFileSync(new URL("../artifacts.json", import.meta.url), "utf8"));
const D = JSON.parse(readFileSync(new URL("../deployment-mainnet.json", import.meta.url), "utf8"));
const env = readFileSync("E:/Protocol Bank/.env.local", "utf8");
const rawPk = env.match(/^AGENT_TEST_WALLET_PRIVATE_KEY=(.*)$/m)[1].trim().replace(/^["']|["']$/g, "");
const account = privateKeyToAccount(rawPk.startsWith("0x") ? rawPk : "0x" + rawPk);

const pub = createPublicClient({ chain: arbitrum, transport: http("https://arb1.arbitrum.io/rpc") });
const wallet = createWalletClient({ account, chain: arbitrum, transport: http("https://arb1.arbitrum.io/rpc") });

const eta = await pub.readContract({ address: D.timelock, abi: A.PlanetTimelock.abi, functionName: "eta" });
const now = BigInt(Math.floor(Date.now() / 1000));
if (now < eta) {
  console.log(`not yet executable: eta ${eta} (${new Date(Number(eta) * 1000).toISOString()}), now ${now}`);
  process.exit(0);
}

const hash = await wallet.writeContract({ address: D.timelock, abi: A.PlanetTimelock.abi, functionName: "execute" });
const rc = await pub.waitForTransactionReceipt({ hash });
if (rc.status !== "success") throw new Error("execute reverted " + hash);
console.log("executed", hash, "gas", rc.gasUsed);
console.log("core.oracle:", await pub.readContract({ address: D.core, abi: A.PlanetCore.abi, functionName: "oracle" }));
