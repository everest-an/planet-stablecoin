import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@wrappers/PlanetCore.gen"

// PlanetCore flow tests: admin control, pausing, and fee/burn accounting that the
// pure-math unit tests (planet_core.test.tolk) do not exercise.
//
// Deploys PlanetCore with a placeholder minter; these tests assert PlanetCore's own
// state, so they do not need the jetton minter wired up (see jetton_mint.test.tolk
// for the full mint → minter → wallet link).

fun deployCore(): (PlanetCore, Treasury, Treasury) {
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
        oracle: deployer.address,
        lastOracleUpdate: 0,
    });
    expect(core.deploy(deployer.address, { value: ton("0.3") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, deployer, alice);
}

// ---------------- UpdatePrice (ERR_NOT_OWNER = 101) ----------------

get fun `test owner can update price`() {
    val (core, deployer, _) = deployCore();
    core.sendUpdatePrice(deployer.address, 0, 1100000, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1100000);
}

get fun `test non-owner cannot update price`() {
    val (core, _, alice) = deployCore();
    val res = core.sendUpdatePrice(alice.address, 0, 2000000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 101 });
    expect(core.ppi()).toEqual(1000000);
}

// ---------------- SetJettonMinter ----------------

get fun `test owner can set jetton minter`() {
    val (core, deployer, alice) = deployCore();
    core.sendSetJettonMinter(deployer.address, 0, alice.address, { value: ton("0.05") });
    expect(core.jettonMinter()).toEqual(alice.address);
}

get fun `test non-owner cannot set jetton minter`() {
    val (core, _, alice) = deployCore();
    val res = core.sendSetJettonMinter(alice.address, 0, alice.address, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 101 });
}

// ---------------- Pause (ERR_PAUSED = 100) ----------------

get fun `test non-owner cannot pause`() {
    val (core, _, alice) = deployCore();
    val res = core.sendSetPaused(alice.address, 0, true, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 101 });
}

get fun `test pause blocks mint and unpause restores it`() {
    val (core, deployer, alice) = deployCore();

    core.sendSetPaused(deployer.address, 0, true, { value: ton("0.05") });
    val blocked = core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    expect(blocked).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 100 });
    expect(core.supply()).toEqual(0);

    core.sendSetPaused(deployer.address, 0, false, { value: ton("0.05") });
    core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    expect(core.supply()).toEqual(995000);
    expect(core.reserve()).toEqual(1000000);
}

// ---------------- Fee accounting (45/30/25) ----------------

get fun `test mint accrues fees split 45-30-25`() {
    val (core, _, alice) = deployCore();
    core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    // fee = 5000 → burn 2250 / reserve 1500 / staking 1250
    expect(core.feesBurn()).toEqual(2250);
    expect(core.feesReserve()).toEqual(1500);
    expect(core.feesStaking()).toEqual(1250);
}

// ---------------- Burn accounting (ERR_SUPPLY = 102) ----------------

get fun `test core burn reduces supply and reserve`() {
    val (core, _, alice) = deployCore();
    core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    // burn 500000 PLT at PPI 1.0 → received = 500000 * 0.995 = 497500
    core.sendBurn(alice.address, 0, 500000, { value: ton("0.05") });
    expect(core.supply()).toEqual(495000);
    expect(core.reserve()).toEqual(502500);
}

get fun `test burn above supply fails`() {
    val (core, _, alice) = deployCore();
    val res = core.sendBurn(alice.address, 0, 1, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 102 });
}
