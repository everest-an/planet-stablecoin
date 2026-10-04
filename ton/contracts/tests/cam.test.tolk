import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@wrappers/PlanetCore.gen"
import "@contracts/oracle_state"
import "@contracts/limits"

// CAM Phase A: the owner registers a per-index CAM adapter; the CAM pushes standardized
// data (price / volatility / liquidity / riskState). A treasury plays the CAM role here.
// See docs/commodity-cam.md.

fun deployCoreCam(): (PlanetCore, Treasury, Treasury, Treasury) {
    val deployer = testing.treasury("deployer");
    val cam = testing.treasury("cam");
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
        cams: [],
        assetCount: 0,
        baseLocked: false,
        oracleState: OracleState { oracle: deployer.address, lastOracleUpdate: 0 }.toCell(),
        limitsState: Limits { maxPerTx: 0 }.toCell(),
    });
    expect(core.deploy(deployer.address, { value: ton("0.3") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, deployer, cam, mallory);
}

get fun `test owner can register a cam`() {
    val (core, deployer, cam, _) = deployCoreCam();
    core.sendSetCam(deployer.address, 0, 0, cam.address, { value: ton("0.05") });
    expect(core.camAt(0)).toEqual(cam.address);
}

get fun `test non-owner cannot register a cam`() {
    val (core, _, _, mallory) = deployCoreCam();
    val res = core.sendSetCam(mallory.address, 0, 0, mallory.address, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: mallory.address, to: core.address, exitCode: 101 });
}

get fun `test cam can push standardized data and update ppi`() {
    val (core, deployer, cam, _) = deployCoreCam();
    core.sendSetCam(deployer.address, 0, 0, cam.address, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    // price 1.10, volatility 5%, liquidity 80%, risk normal
    core.sendCamUpdate(cam.address, 0, 0, 1100000, 50000, 800000, 0, 1000, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1100000);
    expect(core.assetAt(0).volatility).toEqual(50000);
    expect(core.assetAt(0).liquidity).toEqual(800000);
    expect(core.assetAt(0).riskState).toEqual(0);
    expect(core.lastOracleUpdate()).toEqual(1000);
}

get fun `test non-cam cannot push`() {
    val (core, deployer, cam, mallory) = deployCoreCam();
    core.sendSetCam(deployer.address, 0, 0, cam.address, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val res = core.sendCamUpdate(mallory.address, 0, 0, 2000000, 0, 1000000, 0, 1000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: mallory.address, to: core.address, exitCode: 112 });
}

get fun `test stale cam update is rejected`() {
    val (core, deployer, cam, _) = deployCoreCam();
    core.sendSetCam(deployer.address, 0, 0, cam.address, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    core.sendCamUpdate(cam.address, 0, 0, 1100000, 0, 1000000, 0, 1000, { value: ton("0.05") });
    val replay = core.sendCamUpdate(cam.address, 0, 0, 1200000, 0, 1000000, 0, 1000, { value: ton("0.05") });
    expect(replay).toHaveFailedTx({ from: cam.address, to: core.address, exitCode: 104 });
}

get fun `test frozen asset is excluded from ppi`() {
    val (core, deployer, cam, _) = deployCoreCam();
    core.sendSetBasketAsset(deployer.address, 0, 0, 500000, 1000000, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 1, 500000, 1000000, { value: ton("0.05") });
    core.sendSetCam(deployer.address, 0, 0, cam.address, { value: ton("0.05") });
    core.sendSetCam(deployer.address, 0, 1, cam.address, { value: ton("0.05") });

    // both at base -> PPI 1.0
    core.sendCamUpdate(cam.address, 0, 0, 1000000, 0, 1000000, 0, 100, { value: ton("0.05") });
    core.sendCamUpdate(cam.address, 0, 1, 1000000, 0, 1000000, 0, 200, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1000000);

    // asset 0 misbehaves (price 2.0) -> PPI 1.5 (polluted)
    core.sendCamUpdate(cam.address, 0, 0, 2000000, 0, 1000000, 0, 300, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1500000);

    // CAM marks asset 0 frozen -> excluded, PPI renormalised over asset 1 -> back to 1.0
    core.sendCamUpdate(cam.address, 0, 0, 2000000, 0, 1000000, 2, 400, { value: ton("0.05") });
    expect(core.assetAt(0).riskState).toEqual(2);
    expect(core.ppi()).toEqual(1000000);
}
