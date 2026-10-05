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

// A TEP-74 TransferNotificationForRecipient body (as the fund's own jetton wallet would send):
// opcode | queryId | jettonAmount | transferInitiator(null bit) | (empty forward payload)
fun notifBody(qid: uint64, amt: int): cell {
    return beginCell()
        .storeUint(0x7362d09c, 32)
        .storeUint(qid, 64)
        .storeCoins(amt)
        .storeUint(0, 1)
        .endCell();
}

// An empty OrdersStore cell: two empty maps = two "0" maybe-bits.
fun emptyOrdersStore(): cell {
    return beginCell().storeUint(0, 1).storeUint(0, 1).endCell();
}

fun deploySetup(): (PlanetFund, JettonMinter, Treasury, Treasury, KeyPair) {
    val owner = testing.treasury("owner");
    val alice = testing.treasury("alice");
    val custodian = crypto.createMnemonic().toKeyPair();

    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: owner.address,
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
        ordersStore: emptyOrdersStore(),
        fundWallet: beginCell().storeAddress(owner.address).endCell(),
    });
    expect(fund.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: fund.address });

    // minter admin -> fund (so the fund may MintNewJettons); register a 1-of-1 custodian
    minter.sendChangeMinterAdmin(owner.address, 0, fund.address, { value: ton("0.05") });
    fund.sendSetCustodian(owner.address, 0, 0, custodian.publicKey as uint256, { value: ton("0.05") });
    fund.sendSetCustodianThreshold(owner.address, 0, 1, { value: ton("0.05") });
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

get fun `test confirm mint credits ETF shares at NAV net of fee`() {
    val (fund, minter, _, alice, custodian) = deploySetup();
    fund.sendSubscribe(alice.address, 2, 1000000, { value: ton("0.05") });
    val sig = sigCell(crypto.sign(custodian.privateKey, confCell(2, 1000000, 1000, fund.address)));
    val res = fund.sendConfirmMint(alice.address, 0, 2, 1000000, 1000, sigs1(sig), { value: ton("0.3") });
    expect(res).toHaveAllSuccessfulTxs();
    expect(fund.navPerShare()).toEqual(1000000);
    expect(fund.orderAt(2).done).toEqual(true);
    // shares = 1e6 * 1e6/1e6 * (1 - 50/10000) = 995000
    expect(minter.getJettonData().totalSupply).toEqual(995000);
}

get fun `test non-custodian confirmation is rejected`() {
    val (fund, _, _, alice, _) = deploySetup();
    val mallory = crypto.createMnemonic().toKeyPair();
    fund.sendSubscribe(alice.address, 1, 1000000, { value: ton("0.05") });
    val bad = sigCell(crypto.sign(mallory.privateKey, confCell(1, 1000000, 1000, fund.address)));
    val res = fund.sendConfirmMint(alice.address, 0, 1, 1000000, 1000, sigs1(bad), { value: ton("0.1") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 205 });
}

get fun `test confirm mint with no order is rejected`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    val sig = sigCell(crypto.sign(custodian.privateKey, confCell(9, 1000000, 1000, fund.address)));
    val res = fund.sendConfirmMint(alice.address, 0, 9, 1000000, 1000, sigs1(sig), { value: ton("0.1") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 203 });
}

get fun `test double confirm is rejected`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    fund.sendSubscribe(alice.address, 5, 1000000, { value: ton("0.05") });
    val s1 = sigCell(crypto.sign(custodian.privateKey, confCell(5, 1000000, 1000, fund.address)));
    fund.sendConfirmMint(alice.address, 0, 5, 1000000, 1000, sigs1(s1), { value: ton("0.3") });
    val s2 = sigCell(crypto.sign(custodian.privateKey, confCell(5, 1000000, 2000, fund.address)));
    val res = fund.sendConfirmMint(alice.address, 0, 5, 1000000, 2000, sigs1(s2), { value: ton("0.1") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 204 });
}

get fun `test stale confirmation timestamp is rejected`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    val a = sigCell(crypto.sign(custodian.privateKey, confCell(0, 1000000, 2000, fund.address)));
    fund.sendAttestNav(alice.address, 0, 1000000, 2000, sigs1(a), { value: ton("0.05") });
    fund.sendSubscribe(alice.address, 6, 1000000, { value: ton("0.05") });
    val s = sigCell(crypto.sign(custodian.privateKey, confCell(6, 1000000, 1000, fund.address)));
    val res = fund.sendConfirmMint(alice.address, 0, 6, 1000000, 1000, sigs1(s), { value: ton("0.1") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 209 });
}

get fun `test attest nav applies the jump guard`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    val s1 = sigCell(crypto.sign(custodian.privateKey, confCell(0, 1000000, 1000, fund.address)));
    fund.sendAttestNav(alice.address, 0, 1000000, 1000, sigs1(s1), { value: ton("0.05") });
    expect(fund.navPerShare()).toEqual(1000000);
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

get fun `test non-subscriber cannot cancel an order`() {
    val (fund, _, _, alice, _) = deploySetup();
    val bob = testing.treasury("bob");
    fund.sendSubscribe(alice.address, 8, 1000000, { value: ton("0.05") });
    val res = fund.sendCancelOrder(bob.address, 0, 8, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: bob.address, to: fund.address, exitCode: 201 });
}

get fun `test subscribe zero is rejected`() {
    val (fund, _, _, alice, _) = deploySetup();
    val res = fund.sendSubscribe(alice.address, 4, 0, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 211 });
}

get fun `test paused fund rejects subscribe`() {
    val (fund, _, owner, alice, _) = deploySetup();
    fund.sendSetPaused(owner.address, 0, true, { value: ton("0.05") });
    expect(fund.isPaused()).toEqual(true);
    val res = fund.sendSubscribe(alice.address, 11, 1000000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 202 });
}

get fun `test kyc gate blocks non-allowed subscribers`() {
    val (fund, _, owner, alice, _) = deploySetup();
    fund.sendSetKyc(owner.address, 0, true, { value: ton("0.05") });
    expect(fund.kycRequired()).toEqual(true);
    expect(fund.sendSubscribe(alice.address, 12, 1000000, { value: ton("0.05") }))
        .toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 210 });
    fund.sendAllow(owner.address, 0, alice.address, true, { value: ton("0.05") });
    fund.sendSubscribe(alice.address, 13, 1000000, { value: ton("0.05") });
    expect(fund.orderAt(13).done).toEqual(false);
}

get fun `test owner can set fees and jetton minter`() {
    val (fund, minter, owner, _, _) = deploySetup();
    fund.sendSetFees(owner.address, 0, 200, 100, 100, { value: ton("0.05") });
    expect(fund.mgmtFeeBps()).toEqual(200);
    expect(fund.mintFeeBps()).toEqual(100);
    expect(fund.redeemFeeBps()).toEqual(100);
    fund.sendSetJettonMinter(owner.address, 0, minter.address, { value: ton("0.05") });
    expect(fund.jettonMinter()).toEqual(minter.address);
}

get fun `test non-owner setters are rejected`() {
    val (fund, _, _, alice, _) = deploySetup();
    expect(fund.sendSetFees(alice.address, 0, 100, 100, 100, { value: ton("0.05") })).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 201 });
    expect(fund.sendSetPaused(alice.address, 0, true, { value: ton("0.05") })).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 201 });
    expect(fund.sendSetKyc(alice.address, 0, true, { value: ton("0.05") })).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 201 });
    expect(fund.sendAllow(alice.address, 0, alice.address, true, { value: ton("0.05") })).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 201 });
    expect(fund.sendSetCustodian(alice.address, 0, 0, 0, { value: ton("0.05") })).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 201 });
    expect(fund.sendSetCustodianThreshold(alice.address, 0, 1, { value: ton("0.05") })).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 201 });
    expect(fund.sendSetJettonMinter(alice.address, 0, alice.address, { value: ton("0.05") })).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 201 });
    expect(fund.sendSetOwner(alice.address, 0, alice.address, { value: ton("0.05") })).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 201 });
}

get fun `test owner can transfer ownership`() {
    val (fund, _, owner, alice, _) = deploySetup();
    fund.sendSetOwner(owner.address, 0, alice.address, { value: ton("0.05") });
    expect(fund.owner()).toEqual(alice.address);
}

get fun `test all fund getters are readable`() {
    val (fund, _, owner, _, _) = deploySetup();
    expect(fund.owner()).toEqual(owner.address);
    expect(fund.custodianCount()).toEqual(1);
    expect(fund.custodianThreshold()).toEqual(1);
    expect(fund.lastNavUpdate()).toEqual(0);
}

get fun `test unknown fund opcode is rejected`() {
    val (fund, _, owner, _, _) = deploySetup();
    val res = fund.sendAny(owner.address, beginCell().storeUint(0xDEAD, 32).endCell(), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: owner.address, to: fund.address, exitCode: 65535 });
}

fun deployBareFund(): (PlanetFund, Treasury) {
    val owner = testing.treasury("owner");
    val minter = testing.treasury("minter");
    val fund = PlanetFund.fromStorage({
        owner: owner.address, jettonMinter: minter.address, navPerShare: 0, lastNavUpdate: 0,
        mgmtFeeBps: 100, mintFeeBps: 50, redeemFeeBps: 50, paused: false, kycRequired: false,
        allowed: [], custodianCount: 0, custodianThreshold: 0, custodians: [],
        ordersStore: emptyOrdersStore(), fundWallet: beginCell().storeAddress(owner.address).endCell(),
    });
    expect(fund.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: fund.address });
    return (fund, owner);
}

get fun `test confirm mint with no custodian is rejected`() {
    val (fund, owner) = deployBareFund();
    fund.sendSubscribe(owner.address, 1, 1000000, { value: ton("0.05") });
    val res = fund.sendConfirmMint(owner.address, 0, 1, 1000000, 1000, sigs1(beginCell().endCell()), { value: ton("0.1") });
    expect(res).toHaveFailedTx({ from: owner.address, to: fund.address, exitCode: 206 });
}

get fun `test attest nav with no custodian is rejected`() {
    val (fund, owner) = deployBareFund();
    val res = fund.sendAttestNav(owner.address, 0, 1000000, 1000, sigs1(beginCell().endCell()), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: owner.address, to: fund.address, exitCode: 206 });
}

get fun `test confirm mint while paused is rejected`() {
    val (fund, _, owner, alice, custodian) = deploySetup();
    fund.sendSubscribe(alice.address, 20, 1000000, { value: ton("0.05") });
    fund.sendSetPaused(owner.address, 0, true, { value: ton("0.05") });
    val sig = sigCell(crypto.sign(custodian.privateKey, confCell(20, 1000000, 1000, fund.address)));
    val res = fund.sendConfirmMint(alice.address, 0, 20, 1000000, 1000, sigs1(sig), { value: ton("0.1") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 202 });
}

get fun `test confirm mint with bad nav is rejected`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    fund.sendSubscribe(alice.address, 21, 1000000, { value: ton("0.05") });
    val sig = sigCell(crypto.sign(custodian.privateKey, confCell(21, 100, 1000, fund.address)));
    val res = fund.sendConfirmMint(alice.address, 0, 21, 100, 1000, sigs1(sig), { value: ton("0.1") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 207 });
}

get fun `test confirm mint applies the nav jump guard`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    fund.sendSubscribe(alice.address, 22, 1000000, { value: ton("0.05") });
    val s1 = sigCell(crypto.sign(custodian.privateKey, confCell(22, 1000000, 1000, fund.address)));
    fund.sendConfirmMint(alice.address, 0, 22, 1000000, 1000, sigs1(s1), { value: ton("0.3") });
    fund.sendSubscribe(alice.address, 23, 1000000, { value: ton("0.05") });
    val s2 = sigCell(crypto.sign(custodian.privateKey, confCell(23, 2000000, 2000, fund.address)));
    val res = fund.sendConfirmMint(alice.address, 0, 23, 2000000, 2000, sigs1(s2), { value: ton("0.1") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 208 });
}

get fun `test attest nav stale timestamp is rejected`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    val s1 = sigCell(crypto.sign(custodian.privateKey, confCell(0, 1000000, 2000, fund.address)));
    fund.sendAttestNav(alice.address, 0, 1000000, 2000, sigs1(s1), { value: ton("0.05") });
    val s2 = sigCell(crypto.sign(custodian.privateKey, confCell(0, 1000000, 1000, fund.address)));
    val res = fund.sendAttestNav(alice.address, 0, 1000000, 1000, sigs1(s2), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 209 });
}

get fun `test cancel of a missing or done order is rejected`() {
    val (fund, _, _, alice, _) = deploySetup();
    // missing order
    expect(fund.sendCancelOrder(alice.address, 0, 99, { value: ton("0.05") }))
        .toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 203 });
    // done order
    fund.sendSubscribe(alice.address, 30, 1000000, { value: ton("0.05") });
    fund.sendCancelOrder(alice.address, 0, 30, { value: ton("0.05") });
    expect(fund.sendCancelOrder(alice.address, 0, 30, { value: ton("0.05") }))
        .toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 204 });
}

get fun `test invalid fee bps is rejected`() {
    val (fund, _, owner, _, _) = deploySetup();
    val res = fund.sendSetFees(owner.address, 0, 100, 20000, 100, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: owner.address, to: fund.address, exitCode: 211 });
}

get fun `test custodian threshold bounds are enforced`() {
    val (fund, _, owner, _, _) = deploySetup();
    expect(fund.sendSetCustodianThreshold(owner.address, 0, 0, { value: ton("0.05") }))
        .toHaveFailedTx({ from: owner.address, to: fund.address, exitCode: 212 });
    expect(fund.sendSetCustodianThreshold(owner.address, 0, 5, { value: ton("0.05") }))
        .toHaveFailedTx({ from: owner.address, to: fund.address, exitCode: 212 });
}

get fun `test custodian slot can be overwritten`() {
    val (fund, _, owner, _, _) = deploySetup();
    val b = crypto.createMnemonic().toKeyPair();
    fund.sendSetCustodian(owner.address, 0, 0, b.publicKey as uint256, { value: ton("0.05") });
    expect(fund.custodianCount()).toEqual(1);
    expect(fund.custodianAt(0)).toEqual(b.publicKey);
}

get fun `test SetOwner rejects the zero address`() {
    val (fund, _, owner, _, _) = deploySetup();
    val res = fund.sendSetOwner(owner.address, 0, address("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c"), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: owner.address, to: fund.address, exitCode: 201 });
}

// ---------------- Redemption ----------------

get fun `test redeem request + custodian confirm records the payout`() {
    val (fund, _, owner, alice, custodian) = deploySetup();
    val fw = testing.treasury("fw");
    fund.sendSetFundWallet(owner.address, 0, fw.address, { value: ton("0.05") });
    fund.sendRequestRedeem(alice.address, 40, 500000, { value: ton("0.05") });
    fund.sendAny(fw.address, notifBody(40, 500000), { value: ton("0.05") });
    val sig = sigCell(crypto.sign(custodian.privateKey, confCell(40, 1000000, 1000, fund.address)));
    val res = fund.sendConfirmRedeem(alice.address, 0, 40, 1000000, 1000, sigs1(sig), { value: ton("0.2") });
    expect(res).toHaveAllSuccessfulTxs();
    val r = fund.redeemAt(40);
    expect(r.done).toEqual(true);
    expect(r.payout).toEqual(497500); // 500000 * 1.0 * (1 - 50/10000)
}

// ---------------- TEP-74 share receipt (trustless redemption) ----------------

get fun `test redeem confirm before shares are funded is rejected`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    fund.sendRequestRedeem(alice.address, 60, 500000, { value: ton("0.05") });
    val sig = sigCell(crypto.sign(custodian.privateKey, confCell(60, 1000000, 1000, fund.address)));
    val res = fund.sendConfirmRedeem(alice.address, 0, 60, 1000000, 1000, sigs1(sig), { value: ton("0.2") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 214 });
}

get fun `test share notification from a non-wallet sender is rejected`() {
    val (fund, _, owner, alice, _) = deploySetup();
    val fw = testing.treasury("fw");
    fund.sendSetFundWallet(owner.address, 0, fw.address, { value: ton("0.05") });
    expect(fund.fundWallet()).toEqual(fw.address);
    fund.sendRequestRedeem(alice.address, 61, 500000, { value: ton("0.05") });
    val res = fund.sendAny(alice.address, notifBody(61, 500000), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 213 });
}

get fun `test share receipt from the fund wallet funds the redeem and allows payout`() {
    val (fund, _, owner, alice, custodian) = deploySetup();
    val fw = testing.treasury("fw");
    fund.sendSetFundWallet(owner.address, 0, fw.address, { value: ton("0.05") });
    fund.sendRequestRedeem(alice.address, 62, 500000, { value: ton("0.05") });
    expect(fund.redeemAt(62).funded).toEqual(false);
    fund.sendAny(fw.address, notifBody(62, 500000), { value: ton("0.05") });
    expect(fund.redeemAt(62).funded).toEqual(true);
    val sig = sigCell(crypto.sign(custodian.privateKey, confCell(62, 1000000, 1000, fund.address)));
    val res = fund.sendConfirmRedeem(alice.address, 0, 62, 1000000, 1000, sigs1(sig), { value: ton("0.2") });
    expect(res).toHaveAllSuccessfulTxs();
    val r = fund.redeemAt(62);
    expect(r.done).toEqual(true);
    expect(r.payout).toEqual(497500);
}

get fun `test share notification for an unknown redeem is rejected`() {
    val (fund, _, owner, _, _) = deploySetup();
    val fw = testing.treasury("fw");
    fund.sendSetFundWallet(owner.address, 0, fw.address, { value: ton("0.05") });
    val res = fund.sendAny(fw.address, notifBody(999, 500000), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: fw.address, to: fund.address, exitCode: 203 });
}

get fun `test redeem confirm with no request is rejected`() {
    val (fund, _, _, alice, custodian) = deploySetup();
    val sig = sigCell(crypto.sign(custodian.privateKey, confCell(41, 1000000, 1000, fund.address)));
    val res = fund.sendConfirmRedeem(alice.address, 0, 41, 1000000, 1000, sigs1(sig), { value: ton("0.1") });
    expect(res).toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 203 });
}

get fun `test redeem request zero is rejected`() {
    val (fund, _, _, alice, _) = deploySetup();
    expect(fund.sendRequestRedeem(alice.address, 42, 0, { value: ton("0.05") }))
        .toHaveFailedTx({ from: alice.address, to: fund.address, exitCode: 211 });
}

get fun `test subscriber can cancel a redeem request`() {
    val (fund, _, _, alice, _) = deploySetup();
    fund.sendRequestRedeem(alice.address, 43, 100, { value: ton("0.05") });
    fund.sendCancelRedeem(alice.address, 0, 43, { value: ton("0.05") });
    expect(fund.redeemAt(43).done).toEqual(true);
}

get fun `test non-subscriber cannot cancel a redeem request`() {
    val (fund, _, _, alice, _) = deploySetup();
    val bob = testing.treasury("bob");
    fund.sendRequestRedeem(alice.address, 44, 100, { value: ton("0.05") });
    val res = fund.sendCancelRedeem(bob.address, 0, 44, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: bob.address, to: fund.address, exitCode: 201 });
}
