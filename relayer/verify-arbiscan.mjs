// Verifies the three mainnet contracts on Arbiscan via the Etherscan V2 API.
// Env: ETHERSCAN_API_KEY (required). Run from the repo root.
import { readFileSync } from "node:fs";
import { encodeAbiParameters, parseAbiParameters } from "viem";
import solc from "solc";

const D = JSON.parse(readFileSync(new URL("../docs/mainnet-deployment.json", import.meta.url), "utf8"));
const KEY = process.env.ETHERSCAN_API_KEY || "";
if (!KEY) {
  console.error("ETHERSCAN_API_KEY required");
  process.exit(1);
}

const FILES = ["PlanetCore", "PlanetToken", "PlanetTimelock", "SignedPriceOracle"];
const sources = Object.fromEntries(
  FILES.map((f) => [`src/${f}.sol`, { content: readFileSync(new URL(`../monad/src/${f}.sol`, import.meta.url), "utf8") }]),
);
const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    evmVersion: "paris",
    outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object"] } },
  },
};

const compilerversion = "v" + solc.version().split(".Emscripten")[0];
console.log("compiler:", compilerversion);

const OWNER = D.deployer;
const targets = [
  { name: "PlanetTimelock", address: D.timelock, args: encodeAbiParameters(parseAbiParameters("address, uint64"), [OWNER, 21600n]) },
  { name: "PlanetToken", address: D.token, args: encodeAbiParameters(parseAbiParameters("address, address"), [OWNER, OWNER]) },
  { name: "PlanetCore", address: D.core, args: encodeAbiParameters(parseAbiParameters("address, address"), [OWNER, OWNER]) },
];

let failures = 0;
for (const t of targets) {
  const body = new URLSearchParams({
    module: "contract",
    action: "verifysourcecode",
    apikey: KEY,
    contractaddress: t.address,
    sourceCode: JSON.stringify(input),
    codeformat: "solidity-standard-json-input",
    contractname: `src/${t.name}.sol:${t.name}`,
    compilerversion,
    constructorArguements: t.args.slice(2),
    evmversion: "paris",
    optimizationUsed: "1",
    runs: "200",
  });
  const r = await fetch("https://api.etherscan.io/v2/api?chainid=42161", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const j = await r.json();
  const okAlready = /already verified/i.test(String(j.result));
  console.log(`${t.name.padEnd(18)} ${j.status} ${j.message} ${String(j.result).slice(0, 70)}`);
  if (j.status !== "1" && !okAlready) failures++;
  if (j.status !== "1") continue;

  // poll the queue so the run itself reports the final answer
  let outcome = "pending";
  for (let i = 0; i < 20; i++) {
    await new Promise((res) => setTimeout(res, 4000));
    const q = await fetch(
      `https://api.etherscan.io/v2/api?chainid=42161&module=contract&action=checkverifystatus&guid=${j.result}&apikey=${KEY}`,
    );
    const s = await q.json();
    const msg = String(s.result || "");
    if (/pass|success|verified/i.test(msg) && !/not yet/i.test(msg)) { outcome = "verified"; break; }
    if (/fail|error/i.test(msg)) { outcome = msg.slice(0, 120); break; }
  }
  console.log(`  ${outcome}`);
  if (outcome !== "verified") failures++;
}
process.exit(failures ? 1 : 0);
