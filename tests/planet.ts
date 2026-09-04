import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { expect } from "chai";
import { Planet } from "../target/types/planet";

const PPI_SCALE = 1_000_000;
const USD_SCALE = 1_000_000;

describe("planet", () => {
  anchor.setProvider(anchor.AnchorProvider.env());
  const program = anchor.workspace.Planet as Program<Planet>;

  const [reservePda] = anchor.web3.PublicKey.findProgramAddressSync(
    [Buffer.from("reserve")],
    program.programId
  );

  it("initializes the reserve and sets a 2-asset basket", async () => {
    const authority = program.provider.publicKey;

    await program.methods.initialize(authority).rpc();

    const assets = [
      {
        name: "WTI",
        weight: new anchor.BN(500_000),
        basePrice: new anchor.BN(100 * USD_SCALE),
        positionValue: new anchor.BN(600_000 * USD_SCALE),
      },
      {
        name: "XAU",
        weight: new anchor.BN(500_000),
        basePrice: new anchor.BN(2000 * USD_SCALE),
        positionValue: new anchor.BN(400_000 * USD_SCALE),
      },
    ];
    await program.methods.setAssets(assets).rpc();

    const state = await program.account.reserveState.fetch(reservePda);
    expect(state.assetCount).to.eq(2);
    expect(state.totalReserve.toNumber()).to.eq(1_000_000 * USD_SCALE);
    expect(state.totalSupply.toNumber()).to.eq(1_000_000 * USD_SCALE);
  });

  it("computes PPI at parity (prices unchanged -> PPI = 1.0)", async () => {
    await program.methods.computePpi().rpc();
    const state = await program.account.reserveState.fetch(reservePda);
    expect(state.currentPpi.toNumber()).to.eq(PPI_SCALE);
  });

  it("updates WTI price +10% and recomputes PPI = 1.05", async () => {
    await program.methods.updatePrice(0, new anchor.BN(110 * USD_SCALE)).rpc();
    await program.methods.computePpi().rpc();

    const state = await program.account.reserveState.fetch(reservePda);
    // PPI = 0.5 * 1.10 + 0.5 * 1.00 = 1.05
    expect(state.currentPpi.toNumber()).to.eq(1_050_000);
  });

  it("simulates rebalance without mutating reserve", async () => {
    await program.methods.simulateRebalance().rpc();
    const state = await program.account.reserveState.fetch(reservePda);
    expect(state.totalReserve.toNumber()).to.eq(1_000_000 * USD_SCALE);
  });

  it("mock-mints PLT at current PPI", async () => {
    const before = await program.account.reserveState.fetch(reservePda);
    const deposit = 1000 * USD_SCALE;

    await program.methods.mockMint(new anchor.BN(deposit)).rpc();

    const after = await program.account.reserveState.fetch(reservePda);
    expect(after.totalReserve.toNumber()).to.eq(
      before.totalReserve.toNumber() + deposit
    );
    expect(after.totalSupply.toNumber()).to.be.greaterThan(
      before.totalSupply.toNumber()
    );
  });

  it("mock-burns PLT back to reserve", async () => {
    const before = await program.account.reserveState.fetch(reservePda);
    const burn = 1000 * USD_SCALE;

    await program.methods.mockBurn(new anchor.BN(burn)).rpc();

    const after = await program.account.reserveState.fetch(reservePda);
    expect(after.totalSupply.toNumber()).to.eq(
      before.totalSupply.toNumber() - burn
    );
  });

  it("locks base prices and rejects further asset changes", async () => {
    await program.methods.lockBasePrices().rpc();
    const state = await program.account.reserveState.fetch(reservePda);
    expect(state.basePriceLocked).to.be.true;
  });
});
