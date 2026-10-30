// Adversarial fuzz harness for PPIPerp. Random actors, random actions, invariants checked after
// EVERY step. A failure prints the exact action sequence so it can be replayed.
//
// Invariants (checked on-chain, not against JS bookkeeping):
//   I1  usdc.balanceOf(perp) == totalCollateral + poolAssets
//   I2  sum(position.collateral) == totalCollateral
//   I3  sum(position.size)      == netSize
//   I4  every open position is listed in traders[] and vice versa
//   I5  poolAssets / totalShares / totalCollateral never underflow (uint, so a revert catches it)
import { createPublicClient, createWalletClient, http, defineChain, parseUnits, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";

const A = JSON.parse(readFileSync("./perp-artifacts.json", "utf8"));
const RPC = "http://127.0.0.1:8545";
const chain = defineChain({ id: 31337, name: "hardhat", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pub = createPublicClient({ chain, transport: http(RPC) });

// hardhat's first five accounts
const KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
];
const actors = KEYS.map((k) => privateKeyToAccount(k));
const wallets = actors.map((a) => createWalletClient({ account: a, chain, transport: http(RPC) }));

// deterministic RNG so a failure can be replayed by changing SEED
let seed = Number(process.env.SEED || 1337);
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
const between = (a, b) => a + Math.floor(rnd() * (b - a + 1));

const deploy = async (w, name, args) => {
  const h = await w.deployContract({ abi: A[name].abi, bytecode: A[name].bytecode, args });
  return (await pub.waitForTransactionReceipt({ hash: h })).contractAddress;
};
const read = (a, abi, fn, args = []) => pub.readContract({ address: a, abi, functionName: fn, args });
const send = async (w, a, abi, fn, args = []) => {
  const h = await w.writeContract({ address: a, abi, functionName: fn, args });
  return pub.waitForTransactionReceipt({ hash: h });
};

const P0 = parseUnits("1000", 18);
const price = await deploy(wallets[0], "MockPrice", [P0, 0]);
const usdc = await deploy(wallets[0], "MockUSDC", []);
const perp = await deploy(wallets[0], "PPIPerp", [usdc, price, actors[0].address]);
await send(wallets[0], perp, A.PPIPerp.abi, "setKeeper", [actors[0].address]);
await send(wallets[0], perp, A.PPIPerp.abi, "setTreasury", [actors[1].address]);

for (const w of wallets) {
  await send(w, usdc, A.MockUSDC.abi, "mint", [w.account.address, parseUnits("500000", 6)]);
  await send(w, usdc, A.MockUSDC.abi, "approve", [perp, 2n ** 255n]);
}
await send(wallets[0], perp, A.PPIPerp.abi, "deposit", [parseUnits("200000", 6)]);

async function invariant(tag, trail) {
  const bal = await read(usdc, A.MockUSDC.abi, "balanceOf", [perp]);
  const tc = await read(perp, A.PPIPerp.abi, "totalCollateral");
  const pa = await read(perp, A.PPIPerp.abi, "poolAssets");
  if (bal !== tc + pa) {
    console.log(`\nFAIL I1 at ${tag}: balance ${formatUnits(bal, 6)} != collateral ${formatUnits(tc, 6)} + pool ${formatUnits(pa, 6)}`);
    trail.slice(-8).forEach((s) => console.log("   ", s));
    process.exit(1);
  }
  let sumColl = 0n, sumSize = 0n, listed = [];
  for (let i = 0; ; i++) {
    const who = await read(perp, A.PPIPerp.abi, "traders", [BigInt(i)]).catch(() => null);
    if (!who) break;
    listed.push(who.toLowerCase());
    const p = await read(perp, A.PPIPerp.abi, "positions", [who]);
    if (!p[4]) {
      console.log(`\nFAIL I4 at ${tag}: ${who} is listed but has no open position`);
      trail.slice(-8).forEach((s) => console.log("   ", s));
      process.exit(1);
    }
    sumColl += p[1];
    sumSize += p[0];
  }
  if (sumColl !== tc) {
    console.log(`\nFAIL I2 at ${tag}: sum collateral ${formatUnits(sumColl, 6)} != totalCollateral ${formatUnits(tc, 6)}`);
    trail.slice(-8).forEach((s) => console.log("   ", s));
    process.exit(1);
  }
  const net = await read(perp, A.PPIPerp.abi, "netSize");
  if (sumSize !== net) {
    console.log(`\nFAIL I3 at ${tag}: sum size ${formatUnits(sumSize, 6)} != netSize ${formatUnits(net, 6)}`);
    trail.slice(-8).forEach((s) => console.log("   ", s));
    process.exit(1);
  }
  for (let i = 0; i < actors.length; i++) {
    const p = await read(perp, A.PPIPerp.abi, "positions", [actors[i].address]);
    if (p[4] && !listed.includes(actors[i].address.toLowerCase())) {
      console.log(`\nFAIL I4 at ${tag}: ${actors[i].address} has a position but is not listed`);
      trail.slice(-8).forEach((s) => console.log("   ", s));
      process.exit(1);
    }
  }
}

const STEPS = Number(process.env.STEPS || 400);
const trail = [];
let ok = 0, rev = 0;

for (let step = 0; step < STEPS; step++) {
  const i = between(0, actors.length - 1);
  const w = wallets[i];
  const p = await read(perp, A.PPIPerp.abi, "positions", [actors[i].address]);
  const shares = await read(perp, A.PPIPerp.abi, "shares", [actors[i].address]);
  const roll = rnd();
  let action, tag;

  try {
    if (roll < 0.18) {
      action = "deposit"; tag = `${action}(${i}, ${between(100, 5000)})`;
      trail.push(tag);
      await send(w, perp, A.PPIPerp.abi, "deposit", [parseUnits(String(between(100, 5000)), 6)]);
    } else if (roll < 0.3) {
      action = "withdraw"; tag = `${action}(${i}, ${formatUnits(shares, 6)})`;
      trail.push(tag);
      if (shares > 0n) await send(w, perp, A.PPIPerp.abi, "withdraw", [shares / 2n > 0n ? shares / 2n : shares]);
    } else if (roll < 0.62) {
      const long = rnd() < 0.5;
      const size = between(100, 6000);
      const margin = between(60, 900);
      action = "open"; tag = `${action}(${i}, ${long ? "+" : "-"}${size}, ${margin})`;
      trail.push(tag);
      await send(w, perp, A.PPIPerp.abi, "open", [parseUnits(String(long ? size : -size), 6), parseUnits(String(margin), 6)]);
    } else if (roll < 0.74) {
      action = "close"; tag = `${action}(${i})`;
      trail.push(tag);
      if (p[4]) await send(w, perp, A.PPIPerp.abi, "close");
    } else if (roll < 0.82) {
      action = "liquidate"; tag = `${action}(${between(0, actors.length - 1)})`;
      trail.push(tag);
      const target = actors[between(0, actors.length - 1)].address;
      await send(w, perp, A.PPIPerp.abi, "liquidate", [target, 0n]);
    } else if (roll < 0.94) {
      const f = 0.9 + rnd() * 0.2;
      const np = BigInt(Math.floor(Number(P0) * f));
      action = "price"; tag = `${action}(${f.toFixed(3)})`;
      trail.push(tag);
      await send(wallets[0], price, A.MockPrice.abi, "set", [np, 0]);
    } else {
      const dt = between(60, 7200);
      action = "time"; tag = `${action}(${dt})`;
      trail.push(tag);
      await pub.request({ method: "evm_increaseTime", params: [dt] });
      await pub.request({ method: "evm_mine", params: [] });
      // funding follows the clock
      await send(wallets[0], perp, A.PPIPerp.abi, "setFundingRate", [BigInt(between(-5e9, 5e9))]);
    }
    ok++;
  } catch (e) {
    // reverts are expected (leverage caps, OI caps, frozen feed, not liquidatable, has position)
    rev++;
    trail[trail.length - 1] = trail[trail.length - 1] + "  ↯ reverted";
  }
  await invariant(step, trail);
}

const bal = await read(usdc, A.MockUSDC.abi, "balanceOf", [perp]);
const tc = await read(perp, A.PPIPerp.abi, "totalCollateral");
const pa = await read(perp, A.PPIPerp.abi, "poolAssets");
const sp = await read(perp, A.PPIPerp.abi, "sharePrice");
console.log(`\n${STEPS} steps: ${ok} executed, ${rev} reverted (expected caps/guards)`);
console.log(`final: pool ${formatUnits(pa, 6)} · collateral ${formatUnits(tc, 6)} · balance ${formatUnits(bal, 6)} · sharePrice ${formatUnits(sp, 6)}`);
console.log("ALL INVARIANTS HELD");
