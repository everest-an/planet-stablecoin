import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@contracts/oracle_state"
import "@contracts/limits"
import "@wrappers/PlanetTimelock.gen"
import "@wrappers/PlanetCore.gen"

// PlanetTimelock: delayed-owner contract. Owner proposes an action; it can only be
// executed after `delay` seconds (giving holders a reaction window), or cancelled.
// Set the timelock's owner to a TON multisig wallet for M-of-N + delay together.

fun deployTimelock(delay: int64): (PlanetTimelock, Treasury, Treasury) {
    val owner = testing.treasury("owner");
    val other = testing.treasury("other");
    val tl = PlanetTimelock.fromStorage({
        owner: owner.address,
        delay: delay,
        hasPending: false,
        dest: owner.address,
        body: beginCell().endCell(),
        eta: 0,
    });
    expect(tl.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: tl.address });
    return (tl, owner, other);
}

get fun `test non-owner cannot propose`() {
    val (tl, _, other) = deployTimelock(0);
    val res = tl.sendTlPropose(other.address, 0, other.address, beginCell().endCell(), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: other.address, to: tl.address, exitCode: 101 });
}

get fun `test propose with zero delay can be executed`() {
    val (tl, owner, _) = deployTimelock(0);
    tl.sendTlPropose(owner.address, 0, owner.address, beginCell().endCell(), { value: ton("0.05") });
    expect(tl.hasPending()).toEqual(true);
    tl.sendTlExecute(owner.address, 0, { value: ton("0.2") });
    expect(tl.hasPending()).toEqual(false);
}

get fun `test delayed proposal cannot be executed too early`() {
    val (tl, owner, _) = deployTimelock(100000);
    tl.sendTlPropose(owner.address, 0, owner.address, beginCell().endCell(), { value: ton("0.05") });
    val res = tl.sendTlExecute(owner.address, 0, { value: ton("0.2") });
    expect(res).toHaveFailedTx({ from: owner.address, to: tl.address, exitCode: 212 });
}

get fun `test cancel clears pending`() {
    val (tl, owner, _) = deployTimelock(100000);
    tl.sendTlPropose(owner.address, 0, owner.address, beginCell().endCell(), { value: ton("0.05") });
    tl.sendTlCancel(owner.address, 0, { value: ton("0.05") });
    expect(tl.hasPending()).toEqual(false);
    val res = tl.sendTlExecute(owner.address, 0, { value: ton("0.2") });
    expect(res).toHaveFailedTx({ from: owner.address, to: tl.address, exitCode: 210 });
}

get fun `test second propose while one is pending is rejected`() {
    val (tl, owner, _) = deployTimelock(0);
    tl.sendTlPropose(owner.address, 0, owner.address, beginCell().endCell(), { value: ton("0.05") });
    val res = tl.sendTlPropose(owner.address, 0, owner.address, beginCell().endCell(), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: owner.address, to: tl.address, exitCode: 211 });
}

get fun `test ownership changes only through propose + execute`() {
    val (tl, owner, other) = deployTimelock(0);
    tl.sendTlSetDelay(owner.address, 0, 3600, { value: ton("0.05") });
    expect(tl.delay()).toEqual(3600);

    // TL-1: a direct owner call must be rejected — accepting it would let a (possibly stolen)
    // owner key hand over ownership with no delay window at all.
    expect(tl.sendTlSetOwner(owner.address, 0, other.address, { value: ton("0.05") }))
        .toHaveFailedTx({ from: owner.address, to: tl.address, exitCode: 101 });

    // The only path: propose TlSetOwner (0x20000005) against the timelock itself, then execute.
    // Execute replays the body from the timelock, so the sender is the timelock — which is the
    // one sender allowed to change ownership.
    val body = beginCell()
        .storeUint(0x20000005, 32)
        .storeInt(0, 64)
        .storeAddress(other.address)
        .endCell();
    tl.sendTlPropose(owner.address, 0, tl.address, body, { value: ton("0.05") });
    tl.sendTlExecute(owner.address, 0, { value: ton("0.2") });
    expect(tl.tlOwner()).toEqual(other.address);
}

get fun `test execute replays the proposed body to the target`() {
    // tl proposes a SetDelay(777) on `target`; execute must deliver it. target's
    // owner is tl itself, so target accepts the replayed message (sender == owner).
    val owner = testing.treasury("owner");
    val tl = PlanetTimelock.fromStorage({
        owner: owner.address, delay: 0, hasPending: false,
        dest: owner.address, body: beginCell().endCell(), eta: 0,
    });
    expect(tl.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: tl.address });
    val target = PlanetTimelock.fromStorage({
        owner: tl.address, delay: 0, hasPending: false,
        dest: owner.address, body: beginCell().endCell(), eta: 0,
    });
    expect(target.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: target.address });

    // TlSetDelay { queryId: 0, delay: 777 } encoded by hand (op 0x20000004)
    val inner = beginCell().storeUint(0x20000004, 32).storeInt(0, 64).storeInt(777, 64).endCell();
    tl.sendTlPropose(owner.address, 0, target.address, inner, { value: ton("0.05") });
    tl.sendTlExecute(owner.address, 0, { value: ton("0.3") });
    expect(target.delay()).toEqual(777);
}

// The real scenario: a timelock gates a CORE owner action. tl (owner=deployer) proposes
// SetOwner(core, other) and executes it; Core must accept (sender == tl == core.owner).
get fun `test timelock gates a Core owner action end-to-end`() {
    val deployer = testing.treasury("deployer");
    val other = testing.treasury("other");
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
        limitsState: Limits { maxPerTx: 0, arbRebateBps: 0, riskFund: 0 }.toCell(),
    });
    expect(core.deploy(deployer.address, { value: ton("0.3") }))
        .toHaveSuccessfulDeploy({ to: core.address });

    val tl = PlanetTimelock.fromStorage({
        owner: deployer.address, delay: 0, hasPending: false,
        dest: deployer.address, body: beginCell().endCell(), eta: 0,
    });
    expect(tl.deploy(deployer.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: tl.address });

    // migrate Core ownership to the timelock (direct owner action)
    core.sendSetOwner(deployer.address, 0, tl.address, { value: ton("0.05") });
    expect(core.owner()).toEqual(tl.address);

    // timelock proposes + executes SetOwner(core, other)
    val body = beginCell().storeUint(0x10000014, 32).storeInt(0, 64).storeAddress(other.address).endCell();
    tl.sendTlPropose(deployer.address, 0, core.address, body, { value: ton("0.05") });
    tl.sendTlExecute(deployer.address, 0, { value: ton("0.2") });

    expect(core.owner()).toEqual(other.address);
    expect(tl.hasPending()).toEqual(false);
}

get fun `test cancel with no pending is rejected`() {
    val (tl, owner, _) = deployTimelock(0);
    val res = tl.sendTlCancel(owner.address, 0, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: owner.address, to: tl.address, exitCode: 210 });
}

get fun `test negative delay is rejected`() {
    val (tl, owner, _) = deployTimelock(0);
    val res = tl.sendTlSetDelay(owner.address, 0, -1, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: owner.address, to: tl.address, exitCode: 213 });
}

// Exercise every getter (delay/tlOwner/pendingEta/pendingDest were never read).
get fun `test timelock getters`() {
    val (tl, owner, other) = deployTimelock(3600);
    expect(tl.delay()).toEqual(3600);
    expect(tl.tlOwner()).toEqual(owner.address);
    expect(tl.hasPending()).toEqual(false);
    tl.sendTlPropose(owner.address, 0, other.address, beginCell().endCell(), { value: ton("0.05") });
    expect(tl.hasPending()).toEqual(true);
    expect(tl.pendingEta() > 0).toEqual(true);
    expect(tl.pendingDest()).toEqual(other.address);
}

get fun `test non-owner timelock actions are rejected`() {
    val (tl, _, other) = deployTimelock(0);
    expect(tl.sendTlExecute(other.address, 0, { value: ton("0.05") })).toHaveFailedTx({ from: other.address, to: tl.address, exitCode: 101 });
    expect(tl.sendTlCancel(other.address, 0, { value: ton("0.05") })).toHaveFailedTx({ from: other.address, to: tl.address, exitCode: 101 });
    expect(tl.sendTlSetDelay(other.address, 0, 10, { value: ton("0.05") })).toHaveFailedTx({ from: other.address, to: tl.address, exitCode: 101 });
    expect(tl.sendTlSetOwner(other.address, 0, other.address, { value: ton("0.05") })).toHaveFailedTx({ from: other.address, to: tl.address, exitCode: 101 });
}
