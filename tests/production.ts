import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { expect } from "chai";
import { Planet } from "../target/types/planet";
import {
  TOKEN_PROGRAM_ID,
  TOKEN_2022_PROGRAM_ID,
  createMint,
  createInitializeAccountInstruction,
  mintTo,
  getOrCreateAssociatedTokenAccount,
  getAccount,
} from "@solana/spl-token";

const USD = 1_000_000; // 6 decimals

// 手工创建普通 token 账户（owner 可为 off-curve 的 PDA）。
// 新版 @solana/spl-token 的 createAccount 走 ATA，会因 off-curve owner 报 TokenOwnerOffCurveError。
async function createPlainTokenAccount(
  connection: anchor.web3.Connection,
  payer: anchor.web3.Keypair,
  mint: anchor.web3.PublicKey,
  owner: anchor.web3.PublicKey
): Promise<anchor.web3.PublicKey> {
  const kp = anchor.web3.Keypair.generate();
  const lamports = await connection.getMinimumBalanceForRentExemption(165);
  const tx = new anchor.web3.Transaction().add(
    anchor.web3.SystemProgram.createAccount({
      fromPubkey: payer.publicKey,
      newAccountPubkey: kp.publicKey,
      lamports,
      space: 165,
      programId: TOKEN_PROGRAM_ID,
    }),
    createInitializeAccountInstruction(kp.publicKey, mint, owner, TOKEN_PROGRAM_ID)
  );
  await anchor.web3.sendAndConfirmTransaction(connection, tx, [payer, kp]);
  return kp.publicKey;
}

describe("planet production", () => {
  anchor.setProvider(anchor.AnchorProvider.env());
  const program = anchor.workspace.Planet as Program<Planet>;
  const provider = anchor.AnchorProvider.env();
  const user = (provider.wallet as anchor.Wallet).payer;

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

  let pltMint: anchor.web3.PublicKey;
  let usdcMint: anchor.web3.PublicKey;
  let usdcVault: anchor.web3.PublicKey;
  let userUsdc: anchor.web3.PublicKey;
  let userPlt: anchor.web3.PublicKey;

  before(async () => {
    // PLT mint（Token-2022，mint authority = reserve PDA，合约用它铸 PLT）
    pltMint = await createMint(
      provider.connection,
      user,
      reservePda,
      null,
      6,
      undefined,
      undefined,
      TOKEN_2022_PROGRAM_ID
    );

    // USDC mint（mock，Token 程序，6 decimals）
    usdcMint = await createMint(provider.connection, user, user.publicKey, null, 6);

    // 协议 USDC 金库（owner = reserve PDA，普通 token 账户）
    usdcVault = await createPlainTokenAccount(provider.connection, user, usdcMint, reservePda);

    // 用户 USDC 账户 + 铸 $1M
    userUsdc = (
      await getOrCreateAssociatedTokenAccount(
        provider.connection,
        user,
        usdcMint,
        user.publicKey
      )
    ).address;
    await mintTo(
      provider.connection,
      user,
      usdcMint,
      userUsdc,
      user.publicKey,
      1_000_000 * USD
    );

    // 用户 PLT 账户（Token-2022）
    userPlt = (
      await getOrCreateAssociatedTokenAccount(
        provider.connection,
        user,
        pltMint,
        user.publicKey,
        false,
        undefined,
        undefined,
        TOKEN_2022_PROGRAM_ID
      )
    ).address;
  });

  it("initializes reserve/risk/attestation and sets a 2-asset basket", async () => {
    await program.methods.initialize(user.publicKey).rpc();
    await program.methods
      .initRisk(user.publicKey, new anchor.BN(100_000 * USD), new anchor.BN(1_000_000 * USD), new anchor.BN(3600))
      .rpc();
    await program.methods.initAttestation(user.publicKey).rpc();

    const assets = [
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
    ];
    await program.methods.setAssets(assets).rpc();
    await program.methods.computePpi().rpc();

    const state = await program.account.reserveState.fetch(reservePda);
    expect(state.currentPpi.toNumber()).to.eq(1_000_000); // PPI = 1.0
  });

  it("mints PLT: 存 USDC -> 铸 PLT（真实 SPL，含 0.5% 手续费）", async () => {
    const deposit = 100_000 * USD;
    const beforeUsdc = (await getAccount(provider.connection, userUsdc)).amount;
    const beforePlt = (await getAccount(provider.connection, userPlt, undefined, TOKEN_2022_PROGRAM_ID)).amount;

    await program.methods
      .mint(new anchor.BN(deposit))
      .accounts({
        reserve: reservePda,
        risk: riskPda,
        usdcFrom: userUsdc,
        usdcVault,
        pltMint,
        pltTo: userPlt,
        user: user.publicKey,
        usdcTokenProgram: TOKEN_PROGRAM_ID,
        pltTokenProgram: TOKEN_2022_PROGRAM_ID,
      })
      .rpc();

    const afterUsdc = (await getAccount(provider.connection, userUsdc)).amount;
    const afterPlt = (await getAccount(provider.connection, userPlt, undefined, TOKEN_2022_PROGRAM_ID)).amount;

    // USDC 减少 deposit
    expect(BigInt(beforeUsdc) - BigInt(afterUsdc)).to.eq(BigInt(deposit));
    // PLT 增加 minted = deposit × 0.995（PPI=1.0）
    expect(BigInt(afterPlt) - BigInt(beforePlt)).to.eq(BigInt(99_500 * USD));
  });

  it("burns PLT: 销毁 PLT -> 释放 USDC（真实 SPL）", async () => {
    const burnAmount = 50_000 * USD;
    const beforeUsdc = (await getAccount(provider.connection, userUsdc)).amount;
    const beforePlt = (await getAccount(provider.connection, userPlt, undefined, TOKEN_2022_PROGRAM_ID)).amount;

    await program.methods
      .burn(new anchor.BN(burnAmount))
      .accounts({
        reserve: reservePda,
        risk: riskPda,
        usdcVault,
        usdcTo: userUsdc,
        pltMint,
        pltFrom: userPlt,
        user: user.publicKey,
        usdcTokenProgram: TOKEN_PROGRAM_ID,
        pltTokenProgram: TOKEN_2022_PROGRAM_ID,
      })
      .rpc();

    const afterUsdc = (await getAccount(provider.connection, userUsdc)).amount;
    const afterPlt = (await getAccount(provider.connection, userPlt, undefined, TOKEN_2022_PROGRAM_ID)).amount;

    // PLT 减少 burnAmount
    expect(BigInt(beforePlt) - BigInt(afterPlt)).to.eq(BigInt(burnAmount));
    // USDC 增加 received = burn × 0.995（PPI=1.0）
    expect(BigInt(afterUsdc) - BigInt(beforeUsdc)).to.eq(BigInt(49_750 * USD));
  });

  it("submits attestation and verifies reserve collateralization", async () => {
    await program.methods
      .submitAttestation(new anchor.BN(5_000_000 * USD), Array(32).fill(0))
      .accounts({ attestation: attestationPda, custodian: user.publicKey })
      .rpc();

    await program.methods
      .verifyReserve()
      .accounts({ reserve: reservePda, attestation: attestationPda })
      .rpc();
  });

  it("migration state is forward-only", async () => {
    // Normal -> FreezeMint（合法）
    await program.methods
      .setMigrationState({ freezeMint: {} } as any)
      .accounts({ reserve: reservePda, authority: user.publicKey })
      .rpc();

    // FreezeMint -> Normal（非法，回退）应失败
    let failed = false;
    try {
      await program.methods
        .setMigrationState({ normal: {} } as any)
        .accounts({ reserve: reservePda, authority: user.publicKey })
        .rpc();
    } catch {
      failed = true;
    }
    expect(failed).to.be.true;
  });
});
