import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@wrappers/PlanetCore.gen"
import "@contracts/oracle_state"
import "@contracts/limits"

// Stability mechanisms (batch A): per-tx mint cap and the hard off-peg mint freeze.
// Band-fee pure math lives in planet_core.test.tolk (which imports the contract source).
// See docs/peg-stability.md.

fun deployCoreStability(): (PlanetCore, Treasury, Treasury) {
    val deployer = testing.treasury("deployer");
    val alice = testing.treasury("alice");
    val core = PlanetCore.fromStorage({
        owner: deployer.address,
        jettonMinter: deployer.address,
        totalReserve: 0,
        totalSupply: 0,
        currentPpi: 1000000,
        feesToBurn: 0,
        feesToReserve: 0,
        feesToStaking: 0,
        paused: false,
        assets: [],
        cams: [],
        assetCount: 0,
        baseLocked: false,
        oracleState: OracleState { oracle: deployer.address, signerKey: 0, lastOracleUpdate: 0 }.toCell(),
        limitsState: Limits { maxPerTx: 0, arbRebateBps: 0, riskFund: 0 }.toCell(),
    });
    expect(core.deploy(deployer.address, { value: ton("0.3") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, deployer, alice);
}

// ---------------- Per-tx limit ----------------

get fun `test owner can set per-tx limit`() {
    val (core, deployer, _) = deployCoreStability();
    core.sendSetLimits(deployer.address, 0, 500000, { value: ton("0.05") });
    expect(core.maxPerTx()).toEqual(500000);
}

get fun `test non-owner cannot set limit`() {
    val (core, _, alice) = deployCoreStability();
    val res = core.sendSetLimits(alice.address, 0, 500000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 101 });
}

get fun `test mint above per-tx limit is rejected`() {
    val (core, deployer, alice) = deployCoreStability();
    core.sendSetLimits(deployer.address, 0, 500000, { value: ton("0.05") });
    val res = core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    expect(res).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 111 });
    // within the limit succeeds: 400000 * 0.995
    core.sendMint(alice.address, 0, 400000, { value: ton("0.5") });
    expect(core.supply()).toEqual(398000);
}

// ---------------- Off-peg behaviour ----------------

get fun `test band fee applies on mint off-peg`() {
    val (core, deployer, alice) = deployCoreStability();
    // push PPI to 1.04 (4% dev, elevated band) via owner emergency override
    core.sendUpdatePrice(deployer.address, 0, 1040000, { value: ton("0.05") });
    core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    // fee = 10000 -> 45/30/25 = 4500/3000/2500
    expect(core.feesBurn()).toEqual(4500);
    expect(core.feesReserve()).toEqual(2000);
    expect(core.feesStaking()).toEqual(2500);
    expect(core.riskFund()).toEqual(1000);
}

get fun `test extreme deviation freezes mint`() {
    val (core, deployer, alice) = deployCoreStability();
    core.sendUpdatePrice(deployer.address, 0, 1200000, { value: ton("0.05") }); // 20% dev
    val res = core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    expect(res).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 110 });
}

// ---------------- Arbitrage incentive (C2) ----------------

get fun `test owner can set arbitrage rebate`() {
    val (core, deployer, _) = deployCoreStability();
    core.sendSetArb(deployer.address, 0, 50, { value: ton("0.05") });
    expect(core.arbRebateBps()).toEqual(50);
}

get fun `test non-owner cannot set arbitrage rebate`() {
    val (core, _, alice) = deployCoreStability();
    val res = core.sendSetArb(alice.address, 0, 50, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 101 });
}

get fun `test mint fee at 5% without arbitrage`() {
    val (core, deployer, alice) = deployCoreStability();
    core.sendUpdatePrice(deployer.address, 0, 1050000, { value: ton("0.05") });
    core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    // band fee 100 bps -> fee 10000 -> burn 4500
    expect(core.feesBurn()).toEqual(4500);
}

get fun `test arbitrage rebate reduces mint fee when rich`() {
    val (core, deployer, alice) = deployCoreStability();
    core.sendSetArb(deployer.address, 0, 50, { value: ton("0.05") });
    core.sendUpdatePrice(deployer.address, 0, 1050000, { value: ton("0.05") });
    core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    // effective 50 bps -> fee 5000 -> burn 2250
    expect(core.feesBurn()).toEqual(2250);
}

// ---------------- Risk fund (C3) ----------------

get fun `test risk fund accrues from fees`() {
    val (core, _, alice) = deployCoreStability();
    core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    expect(core.riskFund()).toEqual(500); // 10% of fee 5000
}

get fun `test owner can cover deficit from risk fund`() {
    val (core, deployer, alice) = deployCoreStability();
    core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") }); // riskFund 500
    expect(core.reserve()).toEqual(1000000);
    core.sendCoverDeficit(deployer.address, 0, 300, { value: ton("0.05") });
    expect(core.riskFund()).toEqual(200);
    expect(core.reserve()).toEqual(1000300);
}

get fun `test cover deficit above risk fund fails`() {
    val (core, deployer, alice) = deployCoreStability();
    core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") }); // riskFund 500
    val res = core.sendCoverDeficit(deployer.address, 0, 1000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: deployer.address, to: core.address, exitCode: 115 });
}

