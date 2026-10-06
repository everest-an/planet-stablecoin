import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@acton/build"
import "@contracts/oracle_state"
import "@contracts/limits"
import "@wrappers/PlanetCore.gen"

// Staleness guard: PlanetCore must never mint against an oracle price older than MAX_ORACLE_AGE
// (6h). Without it a stalled oracle freezes the PPI and anyone can keep minting at that price.
// The guard is skipped while lastOracleUpdate == 0 (a fresh deployment can bootstrap).

fun deployCoreWithLu(lu: int64): (PlanetCore, Treasury, Treasury) {
    val owner = testing.treasury("owner");
    val alice = testing.treasury("alice");
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
        oracleState: OracleState { oracle: owner.address, signerCount: 0, threshold: 0, signers: [], lastOracleUpdate: lu }.toCell(),
        limitsState: Limits { maxPerTx: 0, arbRebateBps: 0, riskFund: 0 }.toCell(),
    });
    expect(core.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, owner, alice);
}

get fun `test mint is rejected when the oracle price is stale`() {
    val now = blockchain.now() as int64;
    val (core, _, alice) = deployCoreWithLu(now - 100000); // older than the 6h window
    expect(core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") }))
        .toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 104 }); // ERR_STALE_PRICE
}

get fun `test mint works when the oracle price is fresh`() {
    val now = blockchain.now() as int64;
    val (core, _, alice) = deployCoreWithLu(now);
    val res = core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    expect(res).toHaveSuccessfulTx();
    expect(core.reserve()).toEqual(1000000);
}

get fun `test a fresh deployment (never pushed) can still bootstrap`() {
    val (core, _, alice) = deployCoreWithLu(0); // lastOracleUpdate == 0 -> guard skipped
    expect(core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") }))
        .toHaveSuccessfulTx();
}
