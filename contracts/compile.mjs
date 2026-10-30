import { readFileSync, writeFileSync } from "node:fs";
import solc from "solc";

const files = ["PlanetCore", "PlanetToken", "PlanetTimelock", "SignedPriceOracle"];
const sources = Object.fromEntries(files.map((f) => [`src/${f}.sol`, { content: readFileSync(`./src/${f}.sol`, "utf8") }]));

const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    evmVersion: "paris",
    outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object"] } },
  },
};

const out = JSON.parse(solc.compile(JSON.stringify(input)));
const errs = (out.errors || []).filter((e) => e.severity === "error");
if (errs.length) {
  console.error("COMPILE ERRORS:");
  errs.forEach((e) => console.error(e.formattedMessage));
  process.exit(1);
}
const warnings = (out.errors || []).filter((e) => e.severity !== "error");
if (warnings.length) console.log("warnings:", warnings.length);

const artifacts = {};
for (const f of files) {
  const c = out.contracts[`src/${f}.sol`][f];
  artifacts[f] = { abi: c.abi, bytecode: "0x" + c.evm.bytecode.object };
  const size = c.evm.bytecode.object.length / 2;
  const deployed = c.evm.deployedBytecode.object.length / 2;
  console.log(`${f.padEnd(18)} create ${String(size).padStart(6)} B · runtime ${String(deployed).padStart(5)} B`);
}
writeFileSync("./artifacts.json", JSON.stringify(artifacts, null, 1));
console.log("artifacts.json written");
