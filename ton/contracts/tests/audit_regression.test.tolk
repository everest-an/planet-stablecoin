import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@wrappers/PlanetCore.gen"
import "@contracts/oracle_state"
import "@contracts/limits"

// Regression tests for the audit remediations (docs/audit-report.md): AR2 (reserve
// underflow), AR3 (redeem-fee clamp at extreme PPI), OR4 (legacy UpdatePrice gate).

fun deployCoreAt(reserve: int64, supply: int64, ppi: int64, baseLocked: bool): (PlanetCore, Treasury, Treasury) {
    val deployer = testing.treasury("deployer");
    val minter = testing.treasury("minter");
    val core = PlanetCore.fromStorage({
        owner: deployer.address,
        jettonMinter: minter.address,
        totalReserve: reserve,
        totalSupply: supply,
        currentPpi: ppi,
        feesToBurn: 0,
        feesToReserve: 0,
        feesToStaking: 0,
        paused: false,
        assets: [],
        cams: [],
        assetCount: 0,
        baseLocked: baseLocked,
        oracleState: OracleState { oracle: deployer.address, signerCount: 0, threshold: 0, signers: [], lastOracleUpdate: 0 }.toCell(),
        limitsState: Limits { maxPerTx: 0, arbRebateBps: 0, riskFund: 0 }.toCell(),
    });
    expect(core.deploy(deployer.address, { value: ton("0.3") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, deployer, minter);
}

// AR2: a burn whose payout exceeds the reserve must be rejected (no int64 underflow).
get fun `test burn mirror rejects payout above reserve`() {
    val (core, _, minter) = deployCoreAt(0, 1000000, 1000000, false);
    val res = core.sendBurnMirror(minter.address, 0, 500000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: minter.address, to: core.address, exitCode: 118 });
}

// AR3: at an extreme PPI the redeem fee is clamped to 20%, so the payout can never
// go negative. gross = 1e6 * 3.0 = 3e6; fee clamp 20% -> received 2.4e6.
get fun `test redeem fee is clamped at extreme ppi`() {
    val (core, _, minter) = deployCoreAt(10000000, 1000000, 3000000, false);
    core.sendBurnMirror(minter.address, 0, 1000000, { value: ton("0.05") });
    expect(core.reserve()).toEqual(7600000);
    expect(core.supply()).toEqual(0);
}

// OR4: the legacy UpdatePrice must be rejected once base prices are locked.
get fun `test UpdatePrice rejected after base lock`() {
    val (core, deployer, _) = deployCoreAt(0, 0, 1000000, true);
    val res = core.sendUpdatePrice(deployer.address, 0, 2000000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: deployer.address, to: core.address, exitCode: 108 });
}
