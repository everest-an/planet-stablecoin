// Demo 初始化脚本：初始化 reserve/risk/attestation + 设资产 + 提交储备证明。
// 用于前端仪表盘演示（只读展示，不需要 SPL 金库）。
//
// 用法（前置：localnet 已启动 + 程序已部署）：
//   npx ts-node scripts/init-demo.ts

import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { Planet } from "../target/types/planet";

const USD = 1_000_000;

async function main() {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program = anchor.workspace.Planet as Program<Planet>;
  const authority = provider.wallet.publicKey;

  const [attestationPda] = anchor.web3.PublicKey.findProgramAddressSync(
    [Buffer.from("attestation")],
    program.programId
  );

  await program.methods.initialize(authority).rpc();
  await program.methods
    .initRisk(authority, new anchor.BN(100_000 * USD), new anchor.BN(1_000_000 * USD), new anchor.BN(3600))
    .rpc();
  await program.methods.initAttestation(authority).rpc();
  await program.methods
    .setAssets([
      { name: "WTI", weight: new anchor.BN(500_000), basePrice: new anchor.BN(100 * USD), positionValue: new anchor.BN(500_000 * USD) },
      { name: "XAU", weight: new anchor.BN(500_000), basePrice: new anchor.BN(2000 * USD), positionValue: new anchor.BN(500_000 * USD) },
    ])
    .rpc();
  await program.methods.computePpi().rpc();
  await program.methods
    .submitAttestation(new anchor.BN(5_000_000 * USD), Array(32).fill(0))
    .accounts({ attestation: attestationPda, custodian: authority })
    .rpc();

  console.log("demo initialized: PPI=1.0, supply=$1M, attestation=$5M");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
