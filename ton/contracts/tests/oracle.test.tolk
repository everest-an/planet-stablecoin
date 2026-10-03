import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@wrappers/PlanetCore.gen"

// Oracle seam tests: the owner designates a price oracle; only that oracle may push
// a price, and pushes must move strictly forward in time (replay protection).
//
// This is the integration point for RedStone/DIA — see docs/oracle-ton.md.

fun deployCoreForOracle(): (PlanetCore, Treasury, Treasury, Treasury) {
    val deployer = testing.treasury("deployer");
    val oracleAcc = testing.treasury("oracle");
    val mallory = testing.treasury("mallory");
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
    return (core, deployer, oracleAcc, mallory);
}

get fun `test owner can set oracle`() {
    val (core, deployer, oracleAcc, _) = deployCoreForOracle();
    core.sendSetOracle(deployer.address, 0, oracleAcc.address, { value: ton("0.05") });
    expect(core.oracle()).toEqual(oracleAcc.address);
}

get fun `test non-owner cannot set oracle`() {
    val (core, _, _, mallory) = deployCoreForOracle();
    val res = core.sendSetOracle(mallory.address, 0, mallory.address, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: mallory.address, to: core.address, exitCode: 101 });
}

get fun `test oracle can push price`() {
    val (core, deployer, oracleAcc, _) = deployCoreForOracle();
    core.sendSetOracle(deployer.address, 0, oracleAcc.address, { value: ton("0.05") });
    core.sendOracleUpdatePrice(oracleAcc.address, 0, 1050000, 1000, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1050000);
    expect(core.lastOracleUpdate()).toEqual(1000);
}

get fun `test non-oracle cannot push price`() {
    val (core, deployer, oracleAcc, mallory) = deployCoreForOracle();
    core.sendSetOracle(deployer.address, 0, oracleAcc.address, { value: ton("0.05") });
    val res = core.sendOracleUpdatePrice(mallory.address, 0, 2000000, 1000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: mallory.address, to: core.address, exitCode: 103 });
    expect(core.ppi()).toEqual(1000000);
}

get fun `test stale oracle price is rejected`() {
    val (core, deployer, oracleAcc, _) = deployCoreForOracle();
    core.sendSetOracle(deployer.address, 0, oracleAcc.address, { value: ton("0.05") });
    core.sendOracleUpdatePrice(oracleAcc.address, 0, 1050000, 1000, { value: ton("0.05") });

    // replaying the same timestamp must be rejected
    val replay = core.sendOracleUpdatePrice(oracleAcc.address, 0, 9999999, 1000, { value: ton("0.05") });
    expect(replay).toHaveFailedTx({ from: oracleAcc.address, to: core.address, exitCode: 104 });
    expect(core.ppi()).toEqual(1050000);
    expect(core.lastOracleUpdate()).toEqual(1000);
}
