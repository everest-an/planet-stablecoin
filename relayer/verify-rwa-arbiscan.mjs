// Verify the three deployed RWA contracts on Arbiscan via the Etherscan V2 API.
// Reads the sources, builds the exact standard-JSON used for compilation, and submits each contract
// with its ABI-encoded constructor arguments.
import { readFileSync } from "node:fs";
import { encodeAbiParameters, parseAbiParameters } from "viem";

const KEY = (() => {
  const env = readFileSync("E:/Protocol Bank/.env.local", "utf8");
  const m = env.match(/^ETHERSCAN_API_KEY=(.*)$/m);
  return m ? m[1].trim().replace(/^["']|["']$/g, "") : "";
})();
if (!KEY) { console.error("no ETHERSCAN_API_KEY"); process.exit(1); }

const dir = "E:/Planet/planet-stablecoin/contracts/src/rwa/";
const sources = {
  "rwa/CollateralRegistry.sol": { content: readFileSync(dir + "CollateralRegistry.sol", "utf8") },
  "rwa/LendingPool.sol": { content: readFileSync(dir + "LendingPool.sol", "utf8") },
  "rwa/PPIFeedAdapter.sol": { content: readFileSync(dir + "PPIFeedAdapter.sol", "utf8") },
};
const stdJson = JSON.stringify({
  language: "Solidity",
  sources,
  settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: "paris", outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } },
});
const COMPILER = "v0.8.24+commit.e11b9ed9";
const CHAIN = "42161";

const OWNER = "0xBf0D7119F553eB5f85C9806f0849f9c86a9B768C";
const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
const CORE = "0x61de052af7cb7dc957a07b1e6298152bb851cbbb";
const st = JSON.parse(readFileSync("E:/Planet/planet-stablecoin/relayer/rwa-deployment.json", "utf8"));

const items = [
  { address: st.registry, name: "rwa/CollateralRegistry.sol:CollateralRegistry", args: encodeAbiParameters(parseAbiParameters("address"), [OWNER]) },
  { address: st.pool, name: "rwa/LendingPool.sol:LendingPool", args: encodeAbiParameters(parseAbiParameters("address, address, address"), [USDC, st.registry, OWNER]) },
  { address: st.feedAdapter, name: "rwa/PPIFeedAdapter.sol:PPIFeedAdapter", args: encodeAbiParameters(parseAbiParameters("address, uint256"), [CORE, 1000n]) },
];

const post = async (params) => {
  const body = new URLSearchParams({ ...params, apikey: KEY, chainid: CHAIN });
  const r = await fetch("https://api.etherscan.io/v2/api", { method: "POST", body });
  return r.json();
};

for (const it of items) {
  console.log(`\n=== ${it.name} @ ${it.address} ===`);
  const res = await post({
    module: "contract",
    action: "verifysourcecode",
    codeformat: "solidity-standard-json-input",
    contractaddress: it.address,
    contractname: it.name,
    compilerversion: COMPILER,
    sourceCode: stdJson,
    constructorArguements: it.args.slice(2),
  });
  console.log("submit:", JSON.stringify(res).slice(0, 220));
  if (res.status === "1" && res.result) {
    const guid = res.result;
    for (let i = 0; i < 12; i++) {
      await new Promise((r) => setTimeout(r, 5000));
      const chk = await post({ module: "contract", action: "checkverifystatus", guid });
      if (chk.result && !/pending/i.test(chk.result)) { console.log("status:", chk.result); break; }
      if (i === 11) console.log("status: still pending (check Arbiscan later)");
    }
  }
}
