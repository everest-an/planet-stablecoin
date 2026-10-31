// F1 handover: deploy the self-owned timelock and move core + perp under it, one 6h round at a time.
// F4: the guardian becomes a dedicated key (address in GUARDIAN env), split from the operator wallet.
// Idempotent, resumable. Run it locally or in CI with PRIVATE_KEY (the operator EOA) + GUARDIAN.
import { createPublicClient, createWalletClient, http, encodeFunctionData } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const TL_V2 = JSON.parse(readFileSync("./timelock-v2-artifacts.json", "utf8")).PlanetTimelockV2;
const P = JSON.parse(readFileSync("./perp-artifacts.json", "utf8"));
const STATE = "./tl-v2-state.json";
const OLD_TL = "0xA1Fdb9F95210AF1d968872F6FC86F623A3e3017C";
const CORE = "0x61de052af7cb7dc957a07b1e6298152bb851cbbb";
const PERP = "0x9c2250914c457914af3bffb085ae44141667f5ac";

function key() {
  if (process.env.PRIVATE_KEY) return process.env.PRIVATE_KEY;
  const env = readFileSync("E:/Protocol Bank/.env.local", "utf8");
  return env.match(/^AGENT_TEST_WALLET_PRIVATE_KEY=(.*)$/m)[1].trim().replace(/^["']|["']$/g, "");
}
const RPC = process.env.RPC || "https://arbitrum-one-rpc.publicnode.com";
const pub = createPublicClient({ chain: arbitrum, transport: http(RPC) });
const account = privateKeyToAccount(key().startsWith("0x") ? key() : "0x" + key());
const wallet = createWalletClient({ account, chain: arbitrum, transport: http(RPC) });
const TL_ABI = [
  { name: "propose", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "bytes" }], outputs: [] },
  { name: "eta", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { name: "owner", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
];
const st = existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : {};

// 1) deploy TLv2, owner = operator EOA for the bootstrap
if (!st.tlV2) {
  const h = await wallet.deployContract({ abi: TL_V2.abi, bytecode: TL_V2.bytecode, args: [account.address, 21600n] });
  st.tlV2 = (await pub.waitForTransactionReceipt({ hash: h })).contractAddress;
  writeFileSync(STATE, JSON.stringify(st, null, 1));
  console.log("timelock v2:", st.tlV2);
}
const proposeOn = async (tl, dest, data, label) => {
  const eta = await pub.readContract({ address: tl, abi: TL_ABI, functionName: "eta" });
  if (eta === 0n) {
    const h = await wallet.writeContract({ address: tl, abi: TL_ABI, functionName: "propose", args: [dest, data] });
    await pub.waitForTransactionReceipt({ hash: h });
    console.log("proposed on " + tl.slice(0, 8) + ":", label, "(6h)");
  } else {
    console.log(tl.slice(0, 8) + " busy until", new Date(Number(eta) * 1000).toISOString(), "- retry after it executes");
  }
};
const transferOwner = (target) => encodeFunctionData({ abi: [{ type: "function", name: "setOwner", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] }], functionName: "setOwner", args: [st.tlV2] });

// 2) ownership handovers. Only propose when the target still points at the OLD owner.
const coreOwner = await pub.readContract({ address: CORE, abi: TL_ABI, functionName: "owner" });
const perpOwner = await pub.readContract({ address: PERP, abi: TL_ABI, functionName: "owner" });
const tlV2Owner = await pub.readContract({ address: st.tlV2, abi: TL_ABI, functionName: "owner" });

if (coreOwner !== st.tlV2) await proposeOn(OLD_TL, CORE, transferOwner(CORE), "core.setOwner(tlV2)");
else console.log("core already owned by tlV2");
if (perpOwner !== st.tlV2) await proposeOn(OLD_TL, PERP, transferOwner(PERP), "perp.setOwner(tlV2)");
else console.log("perp already owned by tlV2");

// 3) the last step: tlV2 becomes self-owned. ONLY after core+perp are under it, otherwise the
//    EOA loses the only path to fix a botched handover. Propose it last and only once.
if (coreOwner === st.tlV2 && perpOwner === st.tlV2 && tlV2Owner !== st.tlV2) {
  await proposeOn(st.tlV2, st.tlV2, transferOwner(st.tlV2), "tlV2.setOwner(tlV2) - self-ownership");
} else {
  console.log("tlV2 self-ownership:", tlV2Owner === st.tlV2 ? "done" : "waiting for core+perp handover first");
}

// 4) F4: the guardian is a dedicated key, split from the operator wallet. Set it on the perp
//    through whichever timelock currently owns it.
const GUARDIAN = process.env.GUARDIAN;
if (GUARDIAN && /^0x[0-9a-fA-F]{40}$/.test(GUARDIAN)) {
  const guardianOwner = perpOwner === st.tlV2 ? st.tlV2 : OLD_TL;
  await proposeOn(guardianOwner, PERP, encodeFunctionData({ abi: P.PPIPerp.abi, functionName: "setGuardian", args: [GUARDIAN] }), "perp.setGuardian(dedicated key)");
}
console.log("next step: wait 6h, re-run this script to advance the next round");
