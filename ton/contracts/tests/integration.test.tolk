import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@wrappers/PlanetCore.gen"

// Phase 1 integration test: deploy PlanetCore and assert initial state.

get fun `test deploy PlanetCore sets initial ppi`() {
    val deployer = testing.treasury("deployer");
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
    });
    core.deploy(deployer.address, { value: ton("0.1") });
    expect(core.ppi()).toEqual(1000000);
    expect(core.reserve()).toEqual(0);
}
