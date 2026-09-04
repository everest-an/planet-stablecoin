// Planet 成品合约部署脚本 —— 部署后配置完整协议。
//
// 前置：`anchor deploy` 已把程序部署到目标网络。
// 用法：
//   anchor deploy
//   npx ts-node scripts/deploy.ts   （或用 tsx/ts-node 运行）
//
// 职责：
//   1. 创建 PLT mint（Token-2022，mint authority = reserve PDA）
//   2. 创建协议 USDC 金库（owner = reserve PDA）
//   3. 初始化 reserve / risk / attestation
//   4. 设置初始商品篮子
//
// 注意：真实 USDC 的 mint 地址在 mainnet 是 EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v，
// 在 devnet 需先用 mock USDC。此脚本默认 devnet 用 mock USDC。

import * as anchor from "@coral-xyz/anchor";
import {
  TOKEN_PROGRAM_ID,
  TOKEN_2022_PROGRAM_ID,
  createMint,
  createAccount,
} from "@solana/spl-token";
import { Planet } from "../target/types/planet";

const USD = 1_000_000;

async function main() {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program = anchor.workspace.Planet as Program<Planet>;
  const payer = (provider.wallet as anchor.Wallet).payer;
  const authority = provider.wallet.publicKey;

  const [reservePda] = anchor.web3.PublicKey.findProgramAddressSync(
    [Buffer.from("reserve")],
    program.programId
  );
  const [riskPda] = anchor.web3.PublicKey.findProgramAddressSync(
    [Buffer.from("risk")],
    program.programId
  );
  const [attestationPda] = anchor.web3.PublicKey.findProgramAddressSync(
    [Buffer.from("attestation")],
    program.programId
  );

  // 1. PLT mint（Token-2022，mint authority = reserve PDA）
  const pltMint = await createMint(
    provider.connection,
    payer,
    reservePda,
    null,
    6,
    undefined,
    undefined,
    TOKEN_2022_PROGRAM_ID
  );

  // 2. USDC mint（devnet mock；mainnet 换真实 USDC mint）
  const usdcMint = await createMint(
    provider.connection,
    payer,
    authority,
    null,
    6,
    undefined,
    undefined,
    TOKEN_PROGRAM_ID
  );

  // 3. 协议 USDC 金库（owner = reserve PDA）
  const usdcVault = await createAccount(
    provider.connection,
    payer,
    usdcMint,
    reservePda
  );

  // 4. initialize reserve
  await program.methods.initialize(authority).rpc();

  // 5. init risk（$10 万/笔、$100 万/窗口、1 小时窗口）
  await program.methods
    .initRisk(authority, new anchor.BN(100_000 * USD), new anchor.BN(1_000_000 * USD), new anchor.BN(3600))
    .rpc();

  // 6. init attestation（托管方）
  await program.methods.initAttestation(authority).rpc();

  // 7. set assets（初始 2 商品篮子，权重各 50%）
  await program.methods
    .setAssets([
      {
        name: "WTI",
        weight: new anchor.BN(500_000),
        basePrice: new anchor.BN(100 * USD),
        positionValue: new anchor.BN(500_000 * USD),
      },
      {
        name: "XAU",
        weight: new anchor.BN(500_000),
        basePrice: new anchor.BN(2000 * USD),
        positionValue: new anchor.BN(500_000 * USD),
      },
    ])
    .rpc();

  await program.methods.computePpi().rpc();

  console.log("=== Planet deployed ===");
  console.log("programId:", program.programId.toBase58());
  console.log("reservePda:", reservePda.toBase58());
  console.log("riskPda:", riskPda.toBase58());
  console.log("attestationPda:", attestationPda.toBase58());
  console.log("pltMint:", pltMint.toBase58());
  console.log("usdcMint:", usdcMint.toBase58());
  console.log("usdcVault:", usdcVault.toBase58());
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
