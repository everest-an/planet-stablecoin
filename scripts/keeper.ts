// Planet off-chain keeper —— 定时触发链上 simulate_rebalance。
//
// 说明：白皮书原用 Clockwork 定时任务，但 Clockwork 已于 2023-10 停运。
// 阶段一改用 off-chain keeper：由 GitHub Actions cron / Cloudflare Workers cron /
// 任意 VPS 定时调用本脚本，触发链上 rebalance 指令。
//
// 用法（设置环境变量后运行）：
//   RPC_URL=https://api.devnet.solana.com KEYPAIR=~/.config/solana/id.json node scripts/keeper.ts
//
// 阶段一仅触发「模拟再平衡」（只写日志，不执行 DEX 交易）。
// 阶段二接入 Jupiter 后，可扩展为真实调仓。

import * as anchor from "@coral-xyz/anchor";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { Planet } from "../target/types/planet";

async function main() {
  const rpcUrl = process.env.RPC_URL ?? "https://api.devnet.solana.com";
  const keypairPath =
    process.env.KEYPAIR ?? path.join(os.homedir(), ".config", "solana", "id.json");

  const connection = new anchor.web3.Connection(rpcUrl, "confirmed");
  const secret = JSON.parse(fs.readFileSync(keypairPath, "utf8"));
  const wallet = anchor.web3.Keypair.fromSecretKey(new Uint8Array(secret));
  const provider = new anchor.AnchorProvider(connection, new anchor.Wallet(wallet), {});
  anchor.setProvider(provider);

  const program = anchor.workspace.Planet as Program<Planet>;

  const [reservePda] = anchor.web3.PublicKey.findProgramAddressSync(
    [Buffer.from("reserve")],
    program.programId
  );

  console.log("reserve PDA:", reservePda.toBase58());
  const tx = await program.methods.simulateRebalance().rpc();
  console.log("simulateRebalance tx:", tx);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
