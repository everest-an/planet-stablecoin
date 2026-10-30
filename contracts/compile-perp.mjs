import { readFileSync, writeFileSync } from "node:fs";
import solc from "solc";

const files = [
  ["src/perp/IPerpPrice.sol", "IPerpPrice"],
  ["src/perp/PPIPriceSource.sol", "PPIPriceSource"],
  ["src/perp/PPIPerp.sol", "PPIPerp"],
  ["test-mocks/Mocks.sol", "MockPrice"],
  ["test-mocks/Mocks.sol", "MockUSDC"],
  ["test-mocks/Mocks.sol", "MockCore"],
];

const sources = {};
for (const [p] of files) sources[p] = { content: readFileSync("./" + p, "utf8") };

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
  errs.forEach((e) => console.error(e.formattedMessage));
  process.exit(1);
}

const artifacts = {};
for (const [p, name] of files) {
  const c = out.contracts[p]?.[name];
  if (!c) throw new Error("missing " + name);
  artifacts[name] = { abi: c.abi, bytecode: "0x" + c.evm.bytecode.object };
  console.log(name.padEnd(16), "runtime", String(c.evm.deployedBytecode.object.length / 2).padStart(5), "B");
}
writeFileSync("./perp-artifacts.json", JSON.stringify(artifacts, null, 1));
console.log("perp-artifacts.json written");
