import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@acton/build"
import "@contracts/oracle_state"
import "@contracts/limits"
import "@wrappers/PlanetCore.gen"

// PlanetCore governance basket management: append new assets + re-weight EXISTING assets
// AFTER base prices are locked (the white paper's "the weight set is adjusted periodically
// by governance"). Appending is append-only (never overwrites an existing index) and no
// single commodity weight may exceed 15% (MAX_ASSET_WEIGHT).

fun deployCore(): (PlanetCore, Treasury) {
    val owner = testing.treasury("owner");
    val core = PlanetCore.fromStorage({
        owner: owner.address,
        jettonMinter: owner.address,
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
        oracleState: OracleState { oracle: owner.address, signerCount: 0, threshold: 0, signers: [], lastOracleUpdate: 0 }.toCell(),
        limitsState: Limits { maxPerTx: 0, arbRebateBps: 0, riskFund: 0 }.toCell(),
    });
    expect(core.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, owner);
}

get fun `test governance can append a basket asset`() {
    val (core, owner) = deployCore();
    core.sendGovernanceAddAsset(owner.address, 0, 140000, 70000000, { value: ton("0.05") });
    expect(core.assetCount()).toEqual(1);
    val a = core.assetAt(0);
    expect(a.weight).toEqual(140000);
    expect(a.basePrice).toEqual(70000000);
    expect(a.currentPrice).toEqual(70000000);
}

get fun `test governance append is append-only and preserves existing indices`() {
    val (core, owner) = deployCore();
    core.sendGovernanceAddAsset(owner.address, 0, 140000, 70000000, { value: ton("0.05") });
    core.sendGovernanceAddAsset(owner.address, 0, 110000, 80000000, { value: ton("0.05") });
    expect(core.assetCount()).toEqual(2);
    expect(core.assetAt(0).weight).toEqual(140000);
    expect(core.assetAt(0).basePrice).toEqual(70000000);
    expect(core.assetAt(1).weight).toEqual(110000);
    expect(core.assetAt(1).basePrice).toEqual(80000000);
}

get fun `test governance append rejects a weight over 15%`() {
    val (core, owner) = deployCore();
    val res = core.sendGovernanceAddAsset(owner.address, 0, 150001, 1000000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: owner.address, to: core.address, exitCode: 107 });
}

get fun `test governance append rejects zero weight and zero base`() {
    val (core, owner) = deployCore();
    expect(core.sendGovernanceAddAsset(owner.address, 0, 0, 1000000, { value: ton("0.05") }))
        .toHaveFailedTx({ from: owner.address, to: core.address, exitCode: 107 });
    expect(core.sendGovernanceAddAsset(owner.address, 0, 100000, 0, { value: ton("0.05") }))
        .toHaveFailedTx({ from: owner.address, to: core.address, exitCode: 106 });
}

get fun `test governance can re-weight an existing asset after lock`() {
    val (core, owner) = deployCore();
    core.sendGovernanceAddAsset(owner.address, 0, 140000, 70000000, { value: ton("0.05") });
    core.sendLockBasePrices(owner.address, 0, { value: ton("0.05") });
    expect(core.baseLocked()).toEqual(true);
    core.sendGovernanceSetWeight(owner.address, 0, 0, 120000, { value: ton("0.05") });
    expect(core.assetAt(0).weight).toEqual(120000);
    expect(core.assetAt(0).basePrice).toEqual(70000000); // basePrice is never touched
    // the plain (pre-lock) setter is still rejected once locked
    expect(core.sendSetBasketAsset(owner.address, 0, 0, 120000, 1, { value: ton("0.05") }))
        .toHaveFailedTx({ from: owner.address, to: core.address, exitCode: 108 });
}

get fun `test governance re-weight rejects a bad index and a bad weight`() {
    val (core, owner) = deployCore();
    core.sendGovernanceAddAsset(owner.address, 0, 140000, 70000000, { value: ton("0.05") });
    expect(core.sendGovernanceSetWeight(owner.address, 0, 5, 100000, { value: ton("0.05") }))
        .toHaveFailedTx({ from: owner.address, to: core.address, exitCode: 109 });
    expect(core.sendGovernanceSetWeight(owner.address, 0, 0, 200000, { value: ton("0.05") }))
        .toHaveFailedTx({ from: owner.address, to: core.address, exitCode: 107 });
}

get fun `test governance ops are owner-only`() {
    val (core, _) = deployCore();
    val mallory = testing.treasury("mallory");
    expect(core.sendGovernanceAddAsset(mallory.address, 0, 100000, 1000000, { value: ton("0.05") }))
        .toHaveFailedTx({ from: mallory.address, to: core.address, exitCode: 101 });
    expect(core.sendGovernanceSetWeight(mallory.address, 0, 0, 100000, { value: ton("0.05") }))
        .toHaveFailedTx({ from: mallory.address, to: core.address, exitCode: 101 });
}
