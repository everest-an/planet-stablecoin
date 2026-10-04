// Planet 前端逻辑：读链上 PDA（ReserveState / RiskState / ReserveAttestation）+ 渲染。
// 依赖 @solana/web3.js（CDN IIFE，暴露 window.solanaWeb3）。

const { Connection, PublicKey } = window.solanaWeb3;

const RPC_URL = "http://127.0.0.1:8899"; // localnet；devnet 换 https://api.devnet.solana.com
const PROGRAM_ID = "CvC6bETKBjrGFjSg3smuagAom1oMvCc4Gks2mK1VftVp";

const MIGRATION_STATES = ["Normal", "FreezeMint", "Migration", "NativeOnly"];
const USD = 1_000_000; // 6 位小数

const connection = new Connection(RPC_URL, "confirmed");

function u64(buf, o) {
  return Number(buf.readBigUInt64LE(o));
}
function i64(buf, o) {
  return Number(buf.readBigInt64LE(o));
}
function fmtUsd(raw) {
  return "$" + (raw / USD).toLocaleString("en-US", { maximumFractionDigits: 2 });
}
function fmtPpi(raw) {
  return (raw / USD).toFixed(4);
}
function pct(ratio) {
  return (ratio * 100).toFixed(2) + "%";
}
function nameOf(buf, o) {
  return new TextDecoder().decode(buf.slice(o, o + 16)).replace(/\0/g, "");
}

function decodeReserve(data) {
  let o = 8;
  const authority = new PublicKey(data.slice(o, o + 32)).toBase58();
  o += 32;
  const totalReserve = u64(data, o); o += 8;
  const totalSupply = u64(data, o); o += 8;
  const ppi = u64(data, o); o += 8;
  const basePriceLocked = data[o] === 1; o += 1;
  const migrationState = data[o]; o += 1;
  const assetCount = data[o]; o += 1;
  const vecLen = data.readUInt32LE(o); o += 4;
  const assets = [];
  for (let i = 0; i < vecLen; i++) {
    const name = nameOf(data, o); o += 16;
    const weight = u64(data, o); o += 8;
    const basePrice = u64(data, o); o += 8;
    const currentPrice = u64(data, o); o += 8;
    const positionValue = u64(data, o); o += 8;
    assets.push({ name, weight, basePrice, currentPrice, positionValue });
  }
  return { authority, totalReserve, totalSupply, ppi, basePriceLocked, migrationState, assetCount, assets };
}

function decodeRisk(data) {
  let o = 8 + 32;
  const maxPerTx = u64(data, o); o += 8;
  const maxPerWindow = u64(data, o); o += 8;
  const windowSize = u64(data, o); o += 8;
  const windowStart = i64(data, o); o += 8;
  const amountInWindow = u64(data, o); o += 8;
  const globallyPaused = data[o] === 1;
  return { maxPerTx, maxPerWindow, windowSize, windowStart, amountInWindow, globallyPaused };
}

function decodeAttestation(data) {
  let o = 8;
  const custodian = new PublicKey(data.slice(o, o + 32)).toBase58();
  o += 32;
  const totalValue = u64(data, o); o += 8;
  o += 32; // holdings_hash
  const attestedAt = i64(data, o);
  return { custodian, totalValue, attestedAt };
}

function setText(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}

async function refresh() {
  try {
    const programId = new PublicKey(PROGRAM_ID);
    const [reservePda] = PublicKey.findProgramAddressSync([new TextEncoder().encode("reserve")], programId);
    const [riskPda] = PublicKey.findProgramAddressSync([new TextEncoder().encode("risk")], programId);
    const [attestationPda] = PublicKey.findProgramAddressSync([new TextEncoder().encode("attestation")], programId);

    const reserveInfo = await connection.getAccountInfo(reservePda);
    if (!reserveInfo) {
      setText("network", "not deployed");
      return;
    }
    const reserve = decodeReserve(reserveInfo.data);

    setText("network", "localnet · live");
    setText("ppi-value", fmtPpi(reserve.ppi));
    setText("total-supply", fmtUsd(reserve.totalSupply));
    setText("total-reserve", fmtUsd(reserve.totalReserve));
    setText("migration-state", MIGRATION_STATES[reserve.migrationState] ?? reserve.migrationState);

    // 抵押率 = 储备 / 供应
    const collateral = reserve.totalSupply > 0 ? reserve.totalReserve / reserve.totalSupply : 0;
    setText("collateral", pct(collateral));

    // 商品篮子
    const tbody = document.getElementById("assets-body");
    tbody.innerHTML = "";
    for (const a of reserve.assets) {
      const tr = document.createElement("tr");
      tr.innerHTML = `<td>${a.name}</td><td>${pct(a.weight / USD)}</td><td>$${(a.basePrice / USD).toFixed(2)}</td><td>$${(a.currentPrice / USD).toFixed(2)}</td><td>${fmtUsd(a.positionValue)}</td>`;
      tbody.appendChild(tr);
    }

    // 风控
    const riskInfo = await connection.getAccountInfo(riskPda);
    if (riskInfo) {
      const risk = decodeRisk(riskInfo.data);
      setText("max-per-tx", fmtUsd(risk.maxPerTx));
      setText("max-per-window", fmtUsd(risk.maxPerWindow));
      setText("paused", risk.globallyPaused ? "paused" : "live");
    }

    // 储备证明
    const attInfo = await connection.getAccountInfo(attestationPda);
    if (attInfo) {
      const att = decodeAttestation(attInfo.data);
      setText("attest-value", att.totalValue > 0 ? fmtUsd(att.totalValue) : "未提交");
      setText("attest-time", att.attestedAt > 0 ? new Date(att.attestedAt * 1000).toLocaleString() : "—");
      setText("custodian", att.custodian.slice(0, 16) + "…");
    }
  } catch (err) {
    setText("network", "error");
    console.error(err);
  }
}

refresh();
setInterval(refresh, 5000);
