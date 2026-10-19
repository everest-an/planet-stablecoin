import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@acton/crypto"
import "@wrappers/PlanetCore.gen"
import "@wrappers/PlanetBond.gen"
import "@contracts/oracle_state"
import "@contracts/limits"
import "@contracts/signed_price"

// C3b link: PlanetCore drives the stabilization bond automatically (PPI < 0.95 opens the
// sale, recovery >= 0.97 closes it), and settled bonds draw their face value from the risk
// fund. Pure emulation — no network.

fun zeroAddr(): address {
    return address("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c");
}

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
        assets: [],
        cams: [],
        assetCount: 0,
        baseLocked: false,
        oracleState: OracleState { oracle: deployer.address, signerCount: 0, threshold: 0, signers: [], lastOracleUpdate: 0 }.toCell(),
        limitsState: Limits { maxPerTx: 0, arbRebateBps: 0, riskFund: 0, bond: zeroAddr(), bondOpen: false, bondPaid: 0 }.toCell(),
    });
    expect(core.deploy(deployer.address, { value: ton("0.4") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, deployer, alice);
}

fun deployBond(core: PlanetCore, owner: Treasury): PlanetBond {
    val bond = PlanetBond.fromStorage({
        owner: owner.address,
        core: core.address,
        open: false,
        premiumBps: 500,
        totalIssued: 0,
        bonds: [],
    });
    expect(bond.deploy(owner.address, { value: ton("0.3") }))
        .toHaveSuccessfulDeploy({ to: bond.address });
    return bond;
}

// One 100%-weight asset at base 1.0, with the deployer as the registered oracle.
fun setSingleAsset(core: PlanetCore, deployer: Treasury) {
    core.sendSetOracle(deployer.address, 0, deployer.address, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
}

fun sigCell(sig: slice): cell {
    return beginCell().storeSlice(sig).endCell();
}

// Domain-separated signed cell: matches PlanetCore.priceHash (tag + core address + payload).
fun domCell(payload: cell, core: address): cell {
    return beginCell().storeUint(0x504C4E54, 32).storeAddress(core).storeRef(payload).endCell();
}

// ---------------- Wiring ----------------

get fun `test owner wires the bond and only the owner can`() {
    val (core, deployer, alice) = deployCore();
    val bond = deployBond(core, deployer);

    val res = core.sendSetBond(alice.address, 0, bond.address, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 101 });

    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });
    expect(core.bond() == bond.address).toEqual(true);
    expect(core.bondOpen()).toEqual(false);
    expect(core.bondPaid()).toEqual(0);
}

get fun `test clearing the bond disables the trigger`() {
    val (core, deployer, _) = deployCore();
    val bond = deployBond(core, deployer);
    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });
    core.sendSetBond(deployer.address, 0, zeroAddr(), { value: ton("0.05") });
    expect(core.bond() == zeroAddr()).toEqual(true);
    expect(core.bondOpen()).toEqual(false);
}

// ---------------- Automatic open / close ----------------

get fun `test ppi below 0.95 auto-opens the sale`() {
    val (core, deployer, _) = deployCore();
    val bond = deployBond(core, deployer);
    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });
    setSingleAsset(core, deployer);

    expect(bond.isOpen()).toEqual(false);
    core.sendOracleUpdateAssetPrice(deployer.address, 0, 0, 940000, 1000, { value: ton("0.05") });

    expect(core.ppi()).toEqual(940000);
    expect(core.bondOpen()).toEqual(true);
    expect(bond.isOpen()).toEqual(true);
}

get fun `test hysteresis keeps the sale open between 0.95 and 0.97`() {
    val (core, deployer, _) = deployCore();
    val bond = deployBond(core, deployer);
    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });
    setSingleAsset(core, deployer);

    core.sendOracleUpdateAssetPrice(deployer.address, 0, 0, 940000, 1000, { value: ton("0.05") });
    expect(bond.isOpen()).toEqual(true);

    // 0.96 is inside the hysteresis band: still open, no close notification.
    core.sendOracleUpdateAssetPrice(deployer.address, 0, 0, 960000, 2000, { value: ton("0.05") });
    expect(bond.isOpen()).toEqual(true);
    expect(core.bondOpen()).toEqual(true);

    // Recovery to 0.97 closes it.
    core.sendOracleUpdateAssetPrice(deployer.address, 0, 0, 970000, 3000, { value: ton("0.05") });
    expect(bond.isOpen()).toEqual(false);
    expect(core.bondOpen()).toEqual(false);
}

get fun `test ppi exactly at the trigger does not open`() {
    val (core, deployer, _) = deployCore();
    val bond = deployBond(core, deployer);
    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });
    setSingleAsset(core, deployer);

    core.sendOracleUpdateAssetPrice(deployer.address, 0, 0, 950000, 1000, { value: ton("0.05") });
    expect(core.bondOpen()).toEqual(false);
    expect(bond.isOpen()).toEqual(false);
}

get fun `test the pre-lock price path also syncs the bond`() {
    val (core, deployer, _) = deployCore();
    val bond = deployBond(core, deployer);
    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });

    core.sendUpdatePrice(deployer.address, 0, 940000, { value: ton("0.05") });
    expect(bond.isOpen()).toEqual(true);
}

get fun `test an undefined index never opens the sale`() {
    val (core, deployer, _) = deployCore();
    val bond = deployBond(core, deployer);
    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });

    core.sendUpdatePrice(deployer.address, 0, 0, { value: ton("0.05") });
    expect(core.bondOpen()).toEqual(false);
    expect(bond.isOpen()).toEqual(false);
}

get fun `test a cam push auto-opens the sale`() {
    val (core, deployer, _) = deployCore();
    val bond = deployBond(core, deployer);
    val cam = testing.treasury("cam");
    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });
    core.sendSetCam(deployer.address, 0, 0, cam.address, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });

    core.sendCamUpdate(cam.address, 0, 0, 940000, 0, 0, 0, 1000, { value: ton("0.05") });
    expect(bond.isOpen()).toEqual(true);
}

get fun `test a signed oracle push auto-opens the sale`() {
    val (core, deployer, alice) = deployCore();
    val bond = deployBond(core, deployer);
    val signer = crypto.createMnemonic().toKeyPair();
    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    core.sendSetSigner(deployer.address, 0, 0, signer.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 1, { value: ton("0.05") });

    val payload = PricePayload {
        queryId: 0,
        index: 0,
        price: 940000,
        volatility: 0,
        liquidity: 1000000,
        riskState: 0,
        timestamp: 1000,
    }.toCell();
    val sig = crypto.sign(signer.privateKey, domCell(payload, core.address));
    core.sendSignedPriceUpdate(alice.address, sigCell(sig), beginCell().endCell(), payload, { value: ton("0.05") });

    expect(bond.isOpen()).toEqual(true);
    expect(core.bondOpen()).toEqual(true);
}

// ---------------- Risk-fund settlement linkage ----------------

get fun `test settlement draws the face value from the risk fund`() {
    val (core, deployer, alice) = deployCore();
    val bond = deployBond(core, deployer);
    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });

    // 10,000 USDC deposit -> 50,000,000 fee -> 5,000,000 risk fund.
    core.sendMint(alice.address, 0, 10000000000, { value: ton("1") });
    expect(core.riskFund()).toEqual(5000000);

    bond.sendSetOpen(deployer.address, 0, true, { value: ton("0.05") });
    bond.sendSubscribe(alice.address, 0, 1000000, { value: ton("0.05") });
    bond.sendRedeem(alice.address, 0, { value: ton("0.05") });
    bond.sendSettleRedeem(deployer.address, 0, alice.address, { value: ton("0.05") });

    // face = 1,000,000 * 1.05 = 1,050,000, fully covered by the risk fund.
    expect(core.bondPaid()).toEqual(1050000);
    expect(core.riskFund()).toEqual(5000000 - 1050000);
    expect(bond.totalIssued()).toEqual(0);
}

get fun `test settlement is capped at the available risk fund`() {
    val (core, deployer, alice) = deployCore();
    val bond = deployBond(core, deployer);
    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });

    // 1.0 USDC deposit -> 5,000 fee -> 500 risk fund, far below the 1,050,000 face.
    core.sendMint(alice.address, 0, 1000000, { value: ton("0.5") });
    expect(core.riskFund()).toEqual(500);

    bond.sendSetOpen(deployer.address, 0, true, { value: ton("0.05") });
    bond.sendSubscribe(alice.address, 0, 1000000, { value: ton("0.05") });
    bond.sendRedeem(alice.address, 0, { value: ton("0.05") });
    bond.sendSettleRedeem(deployer.address, 0, alice.address, { value: ton("0.05") });

    expect(core.bondPaid()).toEqual(500);
    expect(core.riskFund()).toEqual(0);
    expect(bond.totalIssued()).toEqual(0);
}

get fun `test only the wired bond may report a settlement`() {
    val (core, deployer, alice) = deployCore();
    val bond = deployBond(core, deployer);
    core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });

    val res = core.sendPayBond(alice.address, 0, 100, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 124 });
}

get fun `test a settlement with no bond wired is rejected`() {
    val (core, _, alice) = deployCore();
    val res = core.sendPayBond(alice.address, 0, 100, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: core.address, exitCode: 124 });
}
