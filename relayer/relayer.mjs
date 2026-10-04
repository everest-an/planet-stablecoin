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
  if (cmd !== "register" && cmd !== "push") die("usage: node relayer.mjs register|push");
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

  async function send(body) {
    const seqno = await contract.getSeqno();
    await contract.sendTransfer({
      seqno,
      secretKey: kp.secretKey,
      messages: [internal({ to: core, value: toNano("0.05"), bounce: true, body })],
    });
    // wait until the seqno advances (tx accepted)
    for (let i = 0; i < 10; i++) {
      await new Promise((r) => setTimeout(r, 1500));
      if ((await contract.getSeqno()) > seqno) return;
    }
    die("timeout waiting for seqno increment");
  }

  if (cmd === "register") {
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
