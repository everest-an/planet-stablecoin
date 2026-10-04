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

const OP_SET_BASKET = 0x10000009;
const OP_LOCK_BASE = 0x1000000B;
const OP_SET_SIGNER = 0x10000011;
const OP_SIGNED_PRICE = 0x10000010;
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
  if (cmd !== "configure" && cmd !== "register" && cmd !== "push") die("usage: node relayer.mjs configure|register|push");
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

  // Broadcast once (retry only the broadcast itself, never after it may have landed).
  async function send(body) {
    const seqno = await rpcRetry("getSeqno", () => contract.getSeqno());
    await rpcRetry("sendBoc", () =>
      contract.sendTransfer({
        seqno,
        secretKey: kp.secretKey,
        messages: [internal({ to: core, value: toNano("0.05"), bounce: true, body })],
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
    console.log("warn: no seqno confirmation (assuming broadcast)");
  }

  async function runGet(addr, method) {
    return rpcRetry("get " + method, () => client.runMethod(addr, method));
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
    const cur = (await runGet(core, "signerKey")).stack.readBigNumber();
    if (cur === pubKey) {
      console.log("signer already set; skipping");
      return;
    }
    const body = beginCell().storeUint(OP_SET_SIGNER, 32).storeInt(0, 64).storeUint(pubKey, 256).endCell();
    console.log("registering signer key on core...");
    await send(body);
    console.log("done: signer registered");
    return;
  }

  // push
  const cfg = JSON.parse(readFileSync(ASSETS_JSON, "utf8"));
  let ts = Math.floor(Date.now() / 1000);
  for (const a of cfg.assets) {
    const close = await yahooPrice(a.symbol);
    const price = BigInt(Math.round(close * 1e6));
    ts += 1; // strictly increasing timestamp (replay protection)
    const payload = payloadCell({
      queryId: 0n,
      index: BigInt(a.index),
      price,
      volatility: 0n,
      liquidity: PPI_SCALE,
      riskState: 0n,
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
