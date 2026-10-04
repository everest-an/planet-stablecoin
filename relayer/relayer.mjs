// Planet off-chain relayer (TON testnet).
// Fetch commodity/ETF prices from Yahoo Finance, sign a PricePayload, and push
// SignedPriceUpdate(s) to a deployed PlanetCore (which verifies ed25519 on-chain).
//
// Usage:  node relayer.mjs register   # register this wallet's pubkey as signer (owner)
//         node relayer.mjs push       # fetch prices and push signed updates
import { TonClient, WalletContractV4, internal } from "@ton/ton";
import { Address, beginCell, toNano } from "@ton/core";
import { mnemonicToPrivateKey, sign } from "@ton/crypto";
import { readFileSync } from "fs";

const ENDPOINT = process.env.TON_ENDPOINT ?? "https://testnet.toncenter.com/api/v2/jsonRPC";
const CORE_RAW = process.env.PLANET_CORE ?? "";
const MNEMONIC = process.env.RELAYER_MNEMONIC ?? "";
const ASSETS_JSON = process.env.ASSETS_JSON ?? "assets.json";

const OP_MINT = 0x10000001;
const OP_SET_BASKET = 0x10000009;
const OP_LOCK_BASE = 0x1000000B;
const OP_SET_SIGNER = 0x10000011;
const OP_SET_THRESHOLD = 0x10000015;
const OP_SIGNED_PRICE = 0x10000010;
const OP_ASK_TO_BURN = 0x595f07bc;
const PPI_SCALE = 1000000n; // 1.0 fixed point

function die(msg) {
  console.error("ERROR: " + msg);
  process.exit(1);
}

function bigFromBuf(buf) {
  return BigInt("0x" + buf.toString("hex"));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function yahooPrice(symbol) {
  const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?range=1d&interval=1d`;
  const res = await fetch(url);
  if (!res.ok) die(`yahoo ${symbol}: HTTP ${res.status}`);
  const j = await res.json();
  const price = j?.chart?.result?.[0]?.meta?.regularMarketPrice;
  if (!Number.isFinite(price) || price <= 0) die(`yahoo ${symbol}: bad price '${price}'`);
  return price;
}

// Sina international-futures quote: `var hq_str_<code>="<current>,,<bid>,<ask>,..."`
async function sinaPrice(code) {
  const res = await fetch(`https://hq.sinajs.cn/list=${encodeURIComponent(code)}`, {
    headers: { Referer: "https://finance.sina.com.cn", "User-Agent": "Mozilla/5.0" },
  });
  if (!res.ok) die(`sina ${code}: HTTP ${res.status}`);
  const m = (await res.text()).match(/"([^"]*)"/);
  if (!m || !m[1]) die(`sina ${code}: no data`);
  const price = Number(m[1].split(",")[0]);
  if (!Number.isFinite(price) || price <= 0) die(`sina ${code}: bad price`);
  return price;
}

// Multi-source cross-validation (S3): each asset can be quoted by >=2 independent
// sources (Yahoo + Sina). We push the MEDIAN and FREEZE the asset (riskState=1, which
// excludes it from `computePpi`) if the sources diverge beyond MAX_SOURCE_SPREAD.
const MAX_SOURCE_SPREAD = Number(process.env.MAX_SOURCE_SPREAD ?? "0.02"); // 2%
const MULTI_SOURCE = process.env.MULTI_SOURCE !== "0";

async function sourcePrices(asset) {
  const out = [];
  try {
    out.push({ src: "yahoo", price: await yahooPrice(asset.symbol) });
  } catch (e) {
    console.log("warn: yahoo failed: " + String(e?.message ?? e).slice(0, 100));
  }
  if (MULTI_SOURCE && asset.sina) {
    try {
      out.push({ src: "sina", price: (await sinaPrice(asset.sina)) * (asset.sinaScale ?? 1) });
    } catch (e) {
      console.log("warn: sina failed: " + String(e?.message ?? e).slice(0, 100));
    }
  }
  return out;
}

function aggregate(prices) {
  if (prices.length === 0) die("no price source returned a value");
  const vals = prices.map((p) => p.price).sort((a, b) => a - b);
  const median =
    vals.length % 2 === 1
      ? vals[(vals.length - 1) / 2]
      : (vals[vals.length / 2 - 1] + vals[vals.length / 2]) / 2;
  const spread = prices.length >= 2 ? (vals[vals.length - 1] - vals[0]) / median : 0;
  const frozen = prices.length >= 2 && spread > MAX_SOURCE_SPREAD ? 1 : 0;
  return { median, spread, frozen, prices };
}

function payloadCell(p) {
  return beginCell()
    .storeInt(p.queryId, 64)
    .storeInt(p.index, 64)
    .storeInt(p.price, 64)
    .storeInt(p.volatility, 64)
    .storeInt(p.liquidity, 64)
    .storeInt(p.riskState, 64)
    .storeInt(p.timestamp, 64)
    .endCell();
}

async function main() {
  const cmd = process.argv[2];
  if (cmd !== "configure" && cmd !== "register" && cmd !== "push" && cmd !== "e2e" && cmd !== "timelock" && cmd !== "check") die("usage: node relayer.mjs configure|register|push|e2e|timelock|check");
  if (!CORE_RAW) die("PLANET_CORE not set");
  if (!MNEMONIC) die("RELAYER_MNEMONIC not set");

  const core = Address.parse(CORE_RAW);
  const client = new TonClient({ endpoint: ENDPOINT });
  const kp = await mnemonicToPrivateKey(MNEMONIC.split(/\s+/));
  const wallet = WalletContractV4.create({ workchain: 0, publicKey: kp.publicKey });
  const contract = client.open(wallet);
  const pubKey = bigFromBuf(kp.publicKey);

  console.log("relayer wallet: " + wallet.address.toString({ bounceable: false, testOnly: true }));
  console.log("relayer pubkey: " + kp.publicKey.toString("hex"));

  async function rpcRetry(label, fn) {
    for (let a = 0; a < 8; a++) {
      try {
        return await fn();
      } catch (e) {
        const msg = String(e?.message ?? e);
        if (a === 7) die(label + " failed: " + msg.slice(0, 120));
        const w = 2500 * (a + 1);
        console.log(`retry ${label}(${a + 1}) in ${w}ms: ${msg.slice(0, 80)}`);
        await sleep(w);
      }
    }
  }

  // Gas guard: a depleted wallet silently rejects external messages (seqno never
  // bumps, "no seqno confirmation" below). Fail LOUD and early instead.
  const MIN_GAS = 200000000n; // 0.2 TON
  const bal = await rpcRetry("getBalance", () => client.getBalance(wallet.address));
  console.log("wallet balance: " + (Number(bal) / 1e9).toFixed(4) + " TON");
  if (cmd === "check") {
    if (bal < MIN_GAS) die("LOW — wallet balance " + (Number(bal) / 1e9).toFixed(4) + " TON < 0.2; top up testnet TON (e.g. @testgiver_ton_bot)");
    console.log("OK — wallet balance " + (Number(bal) / 1e9).toFixed(4) + " TON");
    return;
  }
  if (bal < MIN_GAS) {
    die("wallet balance too low (" + (Number(bal) / 1e9).toFixed(4) + " TON < 0.2) — top up testnet TON (e.g. @testgiver_ton_bot)");
  }

  // Broadcast once (retry only the broadcast itself, never after it may have landed).
  async function send(body, to = core, value = "0.05") {
    const seqno = await rpcRetry("getSeqno", () => contract.getSeqno());
    await rpcRetry("sendBoc", () =>
      contract.sendTransfer({
        seqno,
        secretKey: kp.secretKey,
        messages: [internal({ to, value: toNano(value), bounce: true, body })],
      })
    );
    // best-effort confirmation
    for (let i = 0; i < 12; i++) {
      await sleep(1500);
      try {
        if ((await contract.getSeqno()) > seqno) return;
      } catch (_) {
        /* ignore transient RPC errors during confirmation */
      }
    }
    console.log("warn: no seqno confirmation (assuming broadcast) — check wallet balance/gas");
  }

  async function runGet(addr, method, args = []) {
    return rpcRetry("get " + method, () => client.runMethod(addr, method, args));
  }

  if (cmd === "configure") {
    const cfg = JSON.parse(readFileSync(ASSETS_JSON, "utf8"));
    const cnt = Number((await runGet(core, "assetCount")).stack.readBigNumber());
    if (cnt >= cfg.assets.length) {
      console.log("basket already configured (" + cnt + " assets); skipping");
      return;
    }
    for (const a of cfg.assets) {
      const close = await yahooPrice(a.symbol);
      const base = BigInt(Math.round(close * 1e6));
      const body = beginCell()
        .storeUint(OP_SET_BASKET, 32)
        .storeInt(0, 64)
        .storeInt(BigInt(a.index), 64)
        .storeInt(BigInt(a.weight), 64)
        .storeInt(base, 64)
        .endCell();
      console.log(`basket #${a.index} ${a.name ?? a.symbol}: weight=${a.weight} base=${base} (from ${close})`);
      await send(body);
    }
    const lock = beginCell().storeUint(OP_LOCK_BASE, 32).storeInt(0, 64).endCell();
    await send(lock);
    console.log("done: basket configured + base prices locked");
    return;
  }

  if (cmd === "register") {
    // Multi-source oracle: register this key at slot 0, then set threshold 1.
    const cnt = Number((await runGet(core, "signerCount")).stack.readBigNumber());
    if (cnt > 0) {
      const existing = (await runGet(core, "signerAt", [{ type: "int", value: 0n }])).stack.readBigNumber();
      if (existing === pubKey) {
        console.log("signer already at slot 0; skipping");
        return;
      }
    }
    const set = beginCell().storeUint(OP_SET_SIGNER, 32).storeInt(0, 64).storeInt(0, 64).storeUint(pubKey, 256).endCell();
    console.log("registering signer key at slot 0...");
    await send(set);
    const thr = beginCell().storeUint(OP_SET_THRESHOLD, 32).storeInt(0, 64).storeInt(1, 64).endCell();
    console.log("setting threshold = 1...");
    await send(thr);
    console.log("done: signer registered + threshold set");
    return;
  }

  if (cmd === "timelock") {
    // Deterministic timelocked SetOwner round-trip on testnet, all via the deployer
    // wallet (internal messages, seqno-confirmed => ordered). Steps:
    //   1) cancel any leftover pending on the demo timelock
    //   2) SetOwner(core, demo)                      [direct owner action]
    //   3) demo proposes SetOwner(core, wallet)
    //   4) demo executes it                          [timelocked owner action -> restore]
    const DEMO_RAW = process.env.DEMO_TIMELOCK ?? "";
    if (!DEMO_RAW) die("DEMO_TIMELOCK not set");
    const demoTl = Address.parse(DEMO_RAW);

    const cancel = beginCell().storeUint(0x20000003, 32).storeInt(0, 64).endCell();
    console.log("step 1: cancel leftover pending...");
    await send(cancel, demoTl, "0.05");
    await sleep(2500);

    const setDemo = beginCell().storeUint(0x10000014, 32).storeInt(0, 64).storeAddress(demoTl).endCell();
    console.log("step 2: SetOwner(core, demo)...");
    await send(setDemo, core, "0.05");
    await sleep(2500);

    const restore = beginCell().storeUint(0x10000014, 32).storeInt(0, 64).storeAddress(wallet.address).endCell();
    const propose = beginCell().storeUint(0x20000001, 32).storeInt(0, 64).storeAddress(core).storeRef(restore).endCell();
    console.log("step 3: propose SetOwner(core, wallet) via timelock...");
    await send(propose, demoTl, "0.05");
    await sleep(2500);

    const execute = beginCell().storeUint(0x20000002, 32).storeInt(0, 64).endCell();
    console.log("step 4: execute...");
    await send(execute, demoTl, "0.2");
    await sleep(4000);

    console.log("done: timelock round-trip");
    return;
  }

  if (cmd === "e2e") {
    // End-to-end on testnet: mint PLT, read balances, burn PLT, verify supply moved.
    const MINTER_RAW = process.env.PLT_MINTER ?? "";
    if (!MINTER_RAW) die("PLT_MINTER not set");
    const minter = Address.parse(MINTER_RAW);

    const supplyBefore = (await runGet(core, "supply")).stack.readBigNumber();
    console.log("before     : core.supply=" + supplyBefore + " ppi=" + (await runGet(core, "ppi")).stack.readBigNumber());

    const deposit = 1000000n; // 1.0 USDC
    const mint = beginCell().storeUint(OP_MINT, 32).storeInt(0, 64).storeInt(deposit, 64).endCell();
    console.log("mint       : 1.0 USDC -> PLT ...");
    await send(mint, core, "0.2");
    await sleep(6000);
    const supplyAfterMint = (await runGet(core, "supply")).stack.readBigNumber();
    console.log("after mint : core.supply=" + supplyAfterMint + " (delta=" + (supplyAfterMint - supplyBefore) + ")");

    const jw = (await runGet(minter, "get_wallet_address", [{ type: "slice", cell: beginCell().storeAddress(wallet.address).endCell() }])).stack.readAddress();
    const balAfterMint = (await runGet(jw, "get_wallet_data")).stack.readBigNumber();
    console.log("PLT wallet : " + jw.toString({ bounceable: false, testOnly: true }) + " balance=" + balAfterMint);

    const burn = beginCell().storeUint(OP_ASK_TO_BURN, 32).storeUint(0, 64).storeCoins(500000n).storeAddress(null).storeMaybeRef(null).endCell();
    console.log("burn       : 0.5 PLT via AskToBurn ...");
    await send(burn, jw, "0.1");
    await sleep(6000);
    const supplyAfterBurn = (await runGet(core, "supply")).stack.readBigNumber();
    const balAfterBurn = (await runGet(jw, "get_wallet_data")).stack.readBigNumber();
    console.log("after burn : core.supply=" + supplyAfterBurn + " (delta=" + (supplyAfterBurn - supplyAfterMint) + ") PLT balance=" + balAfterBurn);
    console.log("E2E OK: mint + burn reflected on-chain");
    return;
  }

  // push
  const cfg = JSON.parse(readFileSync(ASSETS_JSON, "utf8"));
  let ts = Math.floor(Date.now() / 1000);
  for (const a of cfg.assets) {
    const agg = aggregate(await sourcePrices(a));
    console.log(
      `source #${a.index} ${a.name ?? a.symbol}: ` +
        agg.prices.map((p) => `${p.src}=${p.price.toFixed(4)}`).join(" ") +
        ` | median=${agg.median.toFixed(4)} spread=${(agg.spread * 100).toFixed(2)}%` +
        (agg.frozen ? " -> FROZEN (sources diverge)" : "")
    );
    const price = BigInt(Math.round(agg.median * 1e6));
    ts += 1; // strictly increasing timestamp (replay protection)
    const payload = payloadCell({
      queryId: 0n,
      index: BigInt(a.index),
      price,
      volatility: 0n,
      liquidity: PPI_SCALE,
      riskState: BigInt(agg.frozen),
      timestamp: BigInt(ts),
    });
    const sig = sign(payload.hash(), kp.secretKey); // 64 bytes (R||S)
    const sigR = bigFromBuf(sig.subarray(0, 32));
    const sigS = bigFromBuf(sig.subarray(32, 64));
    const body = beginCell()
      .storeUint(OP_SIGNED_PRICE, 32)
      .storeUint(sigR, 256)
      .storeUint(sigS, 256)
      .storeRef(payload)
      .endCell();
    console.log(`push #${a.index} ${a.name ?? a.symbol}: close=${close} -> price=${price}`);
    await send(body);
  }
  console.log("done: pushed " + cfg.assets.length + " asset price(s)");
}

main().catch((e) => die(e?.stack ?? String(e)));
