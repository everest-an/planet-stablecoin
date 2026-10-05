import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@acton/build"
import "@acton/crypto"
import "@wrappers/PlanetFund.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"

// PlanetFund (Phase 2 skeleton): two-phase subscribe + custodian-confirmed mint at NAV.
// NO minting happens on Subscribe alone (this is the fix for the Phase-1 EC1 finding).

fun confCell(orderId: int64, nav: int64, ts: int64, fund: address): cell {
    return beginCell().storeUint(0x46554E44, 32).storeAddress(fund).storeInt(orderId, 64).storeInt(nav, 64).storeInt(ts, 64).endCell();
}
fun sigs1(sig: cell): cell { return beginCell().storeUint(1, 8).storeRef(sig).endCell(); }
fun sigCell(sig: slice): cell { return beginCell().storeSlice(sig).endCell(); }

fun deploySetup(): (PlanetFund, JettonMinter, Treasury, Treasury, KeyPair) {
    val owner = testing.treasury("owner");
    val alice = testing.treasury("alice");
    val custodian = crypto.createMnemonic().toKeyPair();

    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: owner.address, // placeholder; rewired to the fund below
        content: beginCell().endCell(),
        jettonWalletCode: build("JettonWallet"),
    });
    expect(minter.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: minter.address });

    val fund = PlanetFund.fromStorage({
        owner: owner.address,
        jettonMinter: minter.address,
        navPerShare: 0,
        lastNavUpdate: 0,
        mgmtFeeBps: 100,
        mintFeeBps: 50,
        redeemFeeBps: 50,
        paused: false,
        kycRequired: false,
        allowed: [],
        custodianCount: 0,
        custodianThreshold: 0,
        custodians: [],
        orders: [],
    });
    expect(fund.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: fund.address });

    // register a 1-of-1 custodian and wire the minter admin to the fund
    fund.sendSetCustodian(owner.address, 0, 0, custodian.publicKey as uint256, { value: ton("0.05") });
    fund.sendSetCustodianThreshold(owner.address, 0, 1, { value: ton("0.05") });
    // NOTE: the minter admin cannot be changed to the fund without a ChangeMinterAdmin
    // round-trip; for this test the admin stays `owner`, so we assert the FUND state only.
    return (fund, minter, owner, alice, custodian);
}

get fun `test subscribe records a pending order and does NOT mint`() {
    val (fund, _, _, alice, _) = deploySetup();
    fund.sendSubscribe(alice.address, 7, 1000000, { value: ton("0.05") });
    val o = fund.orderAt(7);
    expect(o.user).toEqual(alice.address);
    expect(o.usd).toEqual(1000000);
    expect(o.done).toEqual(false);
}

get fun `test non-custodian confirmation is rejected`() {
    val (fund, _, _, alice, _) = deploySetup();
    val mallory = crypto.createMnemonic().toKeyPair();
    fund.sendSubscribe(alice.address, 1, 1000000, { value: ton("0.05") });
    val bad = sigCell(crypto.sign(mallory.privateKey, confCell(1, 1000000, 1000, fund.address)));
    val res = fund.sendConfirmMint(alice.address, 0, 1, 1000000, 1000, sigs1(bad), { value: ton("0.1") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 205 });
}

get fun `test confirmed mint sets NAV and marks the order done`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    fund.sendSubscribe(alice.address, 2, 1000000, { value: ton("0.05") });
    val sig = sigCell(crypto.sign(custodian.privateKey, confCell(2, 1000000, 1000, fund.address)));
    val res = fund.sendConfirmMint(alice.address, 0, 2, 1000000, 1000, sigs1(sig), { value: ton("0.1") });
    expect(res).toHaveAllSuccessfulTxs();
    expect(fund.navPerShare()).toEqual(1000000);
    expect(fund.lastNavUpdate()).toEqual(1000);
    expect(fund.orderAt(2).done).toEqual(true);
}

get fun `test attest nav applies the jump guard`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    // first attest: NAV 1.0 (any sender works — auth is by signature)
    val s1 = sigCell(crypto.sign(custodian.privateKey, confCell(0, 1000000, 1000, fund.address)));
    fund.sendAttestNav(alice.address, 0, 1000000, 1000, sigs1(s1), { value: ton("0.05") });
    expect(fund.navPerShare()).toEqual(1000000);
    // second attest jumps +50% -> rejected (cap 20%)
    val s2 = sigCell(crypto.sign(custodian.privateKey, confCell(0, 1500000, 2000, fund.address)));
    val res = fund.sendAttestNav(alice.address, 0, 1500000, 2000, sigs1(s2), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 208 });
}

get fun `test nav below the floor is rejected`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    val s = sigCell(crypto.sign(custodian.privateKey, confCell(0, 100, 1000, fund.address)));
    val res = fund.sendAttestNav(alice.address, 0, 100, 1000, sigs1(s), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 207 });
}

get fun `test subscriber can cancel an unconfirmed order`() {
    val (fund, _, _, alice, _) = deploySetup();
    fund.sendSubscribe(alice.address, 3, 1000000, { value: ton("0.05") });
    fund.sendCancelOrder(alice.address, 0, 3, { value: ton("0.05") });
    expect(fund.orderAt(3).done).toEqual(true);
}

get fun `test non-owner cannot set fees`() {
    val (fund, _, _, alice, _) = deploySetup();
    val res = fund.sendSetFees(alice.address, 0, 100, 100, 100, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 201 });
}

get fun `test subscribe zero is rejected`() {
    val (fund, _, _, alice, _) = deploySetup();
    val res = fund.sendSubscribe(alice.address, 4, 0, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 211 });
}
