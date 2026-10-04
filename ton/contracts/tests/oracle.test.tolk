import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@wrappers/PlanetCore.gen"
import "@contracts/oracle_state"

// Oracle + on-chain PPI tests: the owner designates an oracle and configures the
// basket; the oracle pushes per-asset prices; PlanetCore computes PPI on-chain
// (PPI = Σ w_i · currentPrice_i / basePrice_i). See docs/ppi-multiasset.md.

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
        assets: [],
        assetCount: 0,
        baseLocked: false,
        oracleState: OracleState { oracle: deployer.address, lastOracleUpdate: 0 }.toCell(),
    });
    expect(core.deploy(deployer.address, { value: ton("0.3") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, deployer, oracleAcc, mallory);
}

// ---------------- SetOracle ----------------

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

// ---------------- Basket configuration (owner-gated) ----------------

get fun `test owner can configure basket assets`() {
    val (core, deployer, _, _) = deployCoreForOracle();
    core.sendSetBasketAsset(deployer.address, 0, 0, 600000, 1000000, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 1, 400000, 1000000, { value: ton("0.05") });
    expect(core.assetCount()).toEqual(2);
    expect(core.assetAt(0).weight).toEqual(600000);
    expect(core.assetAt(1).basePrice).toEqual(1000000);
}

get fun `test non-owner cannot configure basket`() {
    val (core, _, _, mallory) = deployCoreForOracle();
    val res = core.sendSetBasketAsset(mallory.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: mallory.address, to: core.address, exitCode: 101 });
}

get fun `test zero base price is rejected`() {
    val (core, deployer, _, _) = deployCoreForOracle();
    val res = core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 0, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: deployer.address, to: core.address, exitCode: 106 });
}

// ---------------- Oracle pushes asset prices; PPI computed on-chain ----------------

get fun `test single-asset ppi is computed on-chain`() {
    val (core, deployer, oracleAcc, _) = deployCoreForOracle();
    core.sendSetOracle(deployer.address, 0, oracleAcc.address, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    // price 1.10 → PPI = 1.0 · 1.10 / 1.0 = 1.10
    core.sendOracleUpdateAssetPrice(oracleAcc.address, 0, 0, 1100000, 1000, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1100000);
    expect(core.lastOracleUpdate()).toEqual(1000);
}

get fun `test multi-asset ppi is computed on-chain`() {
    val (core, deployer, oracleAcc, _) = deployCoreForOracle();
    core.sendSetOracle(deployer.address, 0, oracleAcc.address, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 400000, 1000000, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 1, 350000, 1000000, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 2, 250000, 1000000, { value: ton("0.05") });
    core.sendOracleUpdateAssetPrice(oracleAcc.address, 0, 0, 1100000, 100, { value: ton("0.05") });
    core.sendOracleUpdateAssetPrice(oracleAcc.address, 0, 1, 950000, 200, { value: ton("0.05") });
    core.sendOracleUpdateAssetPrice(oracleAcc.address, 0, 2, 1020000, 300, { value: ton("0.05") });
    // PPI = 0.40·1.10 + 0.35·0.95 + 0.25·1.02 = 0.44 + 0.3325 + 0.255 = 1.0275
    expect(core.ppi()).toEqual(1027500);
}

get fun `test non-oracle cannot push an asset price`() {
    val (core, deployer, oracleAcc, mallory) = deployCoreForOracle();
    core.sendSetOracle(deployer.address, 0, oracleAcc.address, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val res = core.sendOracleUpdateAssetPrice(mallory.address, 0, 0, 2000000, 1000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: mallory.address, to: core.address, exitCode: 103 });
    expect(core.ppi()).toEqual(1000000);
}

get fun `test stale asset price is rejected`() {
    val (core, deployer, oracleAcc, _) = deployCoreForOracle();
    core.sendSetOracle(deployer.address, 0, oracleAcc.address, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    core.sendOracleUpdateAssetPrice(oracleAcc.address, 0, 0, 1100000, 1000, { value: ton("0.05") });
    // replaying the same timestamp must be rejected
    val replay = core.sendOracleUpdateAssetPrice(oracleAcc.address, 0, 0, 9999999, 1000, { value: ton("0.05") });
    expect(replay).toHaveFailedTx({ from: oracleAcc.address, to: core.address, exitCode: 104 });
    expect(core.ppi()).toEqual(1100000);
}

get fun `test price push rejected until weights sum to 100%`() {
    val (core, deployer, oracleAcc, _) = deployCoreForOracle();
    core.sendSetOracle(deployer.address, 0, oracleAcc.address, { value: ton("0.05") });
    // weights 40% + 40% = 80% → incomplete basket
    core.sendSetBasketAsset(deployer.address, 0, 0, 400000, 1000000, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 1, 400000, 1000000, { value: ton("0.05") });
    val res = core.sendOracleUpdateAssetPrice(oracleAcc.address, 0, 0, 1100000, 1000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: oracleAcc.address, to: core.address, exitCode: 107 });
}

get fun `test locked base prices freeze the basket`() {
    val (core, deployer, _, _) = deployCoreForOracle();
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    core.sendLockBasePrices(deployer.address, 0, { value: ton("0.05") });
    val res = core.sendSetBasketAsset(deployer.address, 0, 1, 0, 2000000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: deployer.address, to: core.address, exitCode: 108 });
}
