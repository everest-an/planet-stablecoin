// 托管方储备证明提交脚本 —— 把链下 ETF 持仓映射到链上。
//
// 职责(对应 docs/custodian.md):
//   1. 读取 holdings.json(链下持仓明细)
//   2. 计算 holdings_hash = SHA256(规范化持仓串)
//   3. 计算 total_value = Σ(份额 × 价格)，定点 6 位小数
//   4. 用托管方私钥签名 submit_attestation 交易
//
// 用法:
//   HOLDINGS=./holdings.json KEYPAIR=~/.config/solana/custodian.json \
//     npx ts-node scripts/attest.ts
//
// holdings.json 示例见 docs/custodian.md 第 2 节。

import * as anchor from "@coral-xyz/anchor";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { createHash } from "crypto";
import { Planet } from "../target/types/planet";

const USD = 1_000_000; // 6 位小数定点

interface Holding {
  symbol: string;
  etf: string;
  shares: number;
  price_usd: number;
  value_usd: number;
}

interface HoldingsFile {
  version: string;
  timestamp: number;
  custodian: string;
  holdings: Holding[];
  total_value_usd: number;
}

// 规范化持仓串 → 哈希（键按固定顺序，价格/价值固定 2 位小数，保证确定性）
function canonicalHash(holdings: Holding[], timestamp: number, custodian: string): Buffer {
  const parts = holdings
    .map(
      (h) =>
        `${h.symbol}:${h.etf}:${h.shares}:${h.price_usd.toFixed(2)}:${h.value_usd.toFixed(2)}`
    )
    .sort();
  const msg = `${custodian}|${timestamp}|${parts.join("|")}`;
  return createHash("sha256").update(msg).digest();
}

function toFixedPoint(usd: number): anchor.BN {
  return new anchor.BN(Math.round(usd * USD));
}

async function main() {
  const holdingsPath = process.env.HOLDINGS ?? "./holdings.json";
  const keypairPath =
    process.env.KEYPAIR ?? path.join(os.homedir(), ".config", "solana", "custodian.json");

  const data: HoldingsFile = JSON.parse(fs.readFileSync(holdingsPath, "utf8"));

  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program = anchor.workspace.Planet as Program<Planet>;

  const secret = JSON.parse(fs.readFileSync(keypairPath, "utf8"));
  const custodian = anchor.web3.Keypair.fromSecretKey(new Uint8Array(secret));

  // 用托管方 keypair 构造新 provider（签名者 = custodian）
  const custodianProvider = new anchor.AnchorProvider(
    provider.connection,
    new anchor.Wallet(custodian),
    {}
  );
  const custodianProgram = new anchor.Program(
    program.idl,
    program.programId,
    custodianProvider
  ) as Program<Planet>;

  const [attestationPda] = anchor.web3.PublicKey.findProgramAddressSync(
    [Buffer.from("attestation")],
    program.programId
  );

  const hash = canonicalHash(data.holdings, data.timestamp, data.custodian);
  const totalValue = toFixedPoint(data.total_value_usd);

  console.log("=== attestation ===");
  console.log("custodian:", custodian.publicKey.toBase58());
  console.log("total_value:", data.total_value_usd, "USD ->", totalValue.toString());
  console.log("holdings_hash:", hash.toString("hex"));

  const tx = await custodianProgram.methods
    .submitAttestation(totalValue, Array.from(hash))
    .accounts({ attestation: attestationPda, custodian: custodian.publicKey })
    .rpc();

  console.log("submit_attestation tx:", tx);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
