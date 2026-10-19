import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@wrappers/PlanetCore.gen"
import "@contracts/oracle_state"
import "@contracts/limits"

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
        assets: [],
        cams: [],
        assetCount: 0,
        baseLocked: false,
        oracleState: OracleState { oracle: deployer.address, signerCount: 0, threshold: 0, signers: [], lastOracleUpdate: 0 }.toCell(),
        limitsState: Limits { maxPerTx: 0, arbRebateBps: 0, riskFund: 0, bond: address("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c"), bondOpen: false, bondPaid: 0 }.toCell(),
    });
    core.deploy(deployer.address, { value: ton("0.1") });
    expect(core.ppi()).toEqual(1000000);
    expect(core.reserve()).toEqual(0);
}
