import { readFileSync, writeFileSync } from "node:fs";
import solc from "solc";

const dir = "E:/Planet/planet-stablecoin/contracts/src/rwa/";
const input = {
  language: "Solidity",
  sources: {
    "rwa/CollateralRegistry.sol": { content: readFileSync(dir + "CollateralRegistry.sol", "utf8") },
    "rwa/LendingPool.sol": { content: readFileSync(dir + "LendingPool.sol", "utf8") },
    "rwa/Mocks.sol": { content: readFileSync(dir + "Mocks.sol", "utf8") },
  },
  settings: {
    optimizer: { enabled: true, runs: 200 },
    evmVersion: "paris",
    outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } },
  },
};
const out = JSON.parse(solc.compile(JSON.stringify(input)));
const errs = (out.errors || []).filter((e) => e.severity === "error");
if (errs.length) {
  console.log(errs.map((e) => e.formattedMessage).join("\n"));
  process.exit(1);
}
const arts = {};
for (const [file, contracts] of Object.entries(out.contracts)) {
  for (const [name, c] of Object.entries(contracts)) {
    arts[name] = { abi: c.abi, bytecode: "0x" + c.evm.bytecode.object };
  }
}
writeFileSync("E:/Planet/planet-stablecoin/relayer/rwa-artifacts.json", JSON.stringify(arts, null, 1));
console.log("compiled:", Object.keys(arts).join(", "));
