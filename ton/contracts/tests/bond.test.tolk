import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@wrappers/PlanetBond.gen"

// Stabilization bond (C3b): open/close sale, subscribe (principal + premium), redeem.
// Mock accounting; see docs/peg-stability.md §7.

fun deployBond(): (PlanetBond, Treasury, Treasury) {
    val owner = testing.treasury("owner");
    val alice = testing.treasury("alice");
    val bond = PlanetBond.fromStorage({
        owner: owner.address,
        core: owner.address,
        open: false,
        premiumBps: 500,
        totalIssued: 0,
        bonds: [],
    });
    expect(bond.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: bond.address });
    return (bond, owner, alice);
}

get fun `test owner can open sale and set premium`() {
    val (bond, owner, _) = deployBond();
    bond.sendSetOpen(owner.address, 0, true, { value: ton("0.05") });
    expect(bond.isOpen()).toEqual(true);
    bond.sendSetPremium(owner.address, 0, 1000, { value: ton("0.05") });
    expect(bond.premiumBps()).toEqual(1000);
}

get fun `test non-owner cannot open sale`() {
    val (bond, _, alice) = deployBond();
    val res = bond.sendSetOpen(alice.address, 0, true, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: bond.address, exitCode: 101 });
}

get fun `test subscribe when open records face with premium`() {
    val (bond, owner, alice) = deployBond();
    bond.sendSetOpen(owner.address, 0, true, { value: ton("0.05") });
    bond.sendSetPremium(owner.address, 0, 500, { value: ton("0.05") }); // 5%
    bond.sendSubscribe(alice.address, 0, 1000000, { value: ton("0.05") });
    val b = bond.bondAt(alice.address);
    expect(b.principal).toEqual(1000000);
    expect(b.face).toEqual(1050000); // 1e6 * 1.05
    expect(bond.totalIssued()).toEqual(1050000);
}

get fun `test subscribe accumulates`() {
    val (bond, owner, alice) = deployBond();
    bond.sendSetOpen(owner.address, 0, true, { value: ton("0.05") });
    bond.sendSetPremium(owner.address, 0, 0, { value: ton("0.05") }); // no premium
    bond.sendSubscribe(alice.address, 0, 1000000, { value: ton("0.05") });
    bond.sendSubscribe(alice.address, 0, 500000, { value: ton("0.05") });
    val b = bond.bondAt(alice.address);
    expect(b.principal).toEqual(1500000);
    expect(b.face).toEqual(1500000);
}

get fun `test subscribe when closed is rejected`() {
    val (bond, _, alice) = deployBond();
    val res = bond.sendSubscribe(alice.address, 0, 1000000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: bond.address, exitCode: 200 });
}

get fun `test redeem marks bond and reduces total issued`() {
    val (bond, owner, alice) = deployBond();
    bond.sendSetOpen(owner.address, 0, true, { value: ton("0.05") });
    bond.sendSetPremium(owner.address, 0, 500, { value: ton("0.05") });
    bond.sendSubscribe(alice.address, 0, 1000000, { value: ton("0.05") });
    bond.sendRedeem(alice.address, 0, { value: ton("0.05") });
    expect(bond.totalIssued()).toEqual(0);
    expect(bond.bondAt(alice.address).redeemed).toEqual(true);
}

get fun `test double redeem is rejected`() {
    val (bond, owner, alice) = deployBond();
    bond.sendSetOpen(owner.address, 0, true, { value: ton("0.05") });
    bond.sendSubscribe(alice.address, 0, 1000000, { value: ton("0.05") });
    bond.sendRedeem(alice.address, 0, { value: ton("0.05") });
    val res = bond.sendRedeem(alice.address, 0, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: bond.address, exitCode: 202 });
}

get fun `test subscribe with zero amount is rejected`() {
    val (bond, owner, alice) = deployBond();
    bond.sendSetOpen(owner.address, 0, true, { value: ton("0.05") });
    val res = bond.sendSubscribe(alice.address, 0, 0, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: bond.address, exitCode: 203 });
}

get fun `test redeem with no bond is rejected`() {
    val (bond, owner, alice) = deployBond();
    bond.sendSetOpen(owner.address, 0, true, { value: ton("0.05") });
    val res = bond.sendRedeem(alice.address, 0, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: bond.address, exitCode: 201 });
}
