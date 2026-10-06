import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@acton/build"
import "@wrappers/PlanetGov.gen"

// PlanetGov (PLTG governance): staking credits + pro-rata dividends + stake-weighted voting.
// Staking arrives as a TEP-74 transfer notification from the gov's OWN jetton wallet.

// A TransferNotificationForRecipient body with transferInitiator present.
fun stakeBody(qid: uint64, amt: int, staker: address): cell {
    return beginCell()
        .storeUint(0x7362d09c, 32)
        .storeUint(qid, 64)
        .storeCoins(amt)
        .storeUint(1, 1) // transferInitiator is present (originator of the stake)
        .storeAddress(staker)
        .endCell();
}

fun deployGov(): (PlanetGov, Treasury, Treasury, Treasury) {
    val owner = testing.treasury("owner");
    val alice = testing.treasury("alice");
    val gw = testing.treasury("gw");
    val minter = testing.treasury("minter");
    val gov = PlanetGov.fromStorage({
        owner: owner.address,
        pltMinter: minter.address,
        govWallet: beginCell().storeAddress(owner.address).endCell(),
        totalStaked: 0,
        accRewardPerShare: 0,
        accRewards: 0,
        paused: false,
        proposals: [],
        stakes: [],
        lastVote: [],
    });
    expect(gov.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: gov.address });
    gov.sendSetGovWallet(owner.address, 0, gw.address, { value: ton("0.05") });
    return (gov, owner, alice, gw);
}

fun stake(gov: PlanetGov, gw: Treasury, staker: Treasury, amt: int) {
    gov.sendAny(gw.address, stakeBody(1, amt, staker.address), { value: ton("0.05") });
}

get fun `test stake credits the staker and the total`() {
    val (gov, _, alice, gw) = deployGov();
    stake(gov, gw, alice, 1000000);
    expect(gov.totalStaked()).toEqual(1000000);
    expect(gov.stakeOf(alice.address).amount).toEqual(1000000);
    expect(gov.govWallet()).toEqual(gw.address);
}

get fun `test a stake from a non-wallet sender is rejected`() {
    val (gov, _, alice, _) = deployGov();
    val res = gov.sendAny(alice.address, stakeBody(1, 1000000, alice.address), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: alice.address, to: gov.address, exitCode: 405 });
}

get fun `test notify rewards accrues and claim pays`() {
    val (gov, owner, alice, gw) = deployGov();
    stake(gov, gw, alice, 1000000);
    gov.sendNotifyRewards(owner.address, 0, 1000, { value: ton("0.05") });
    expect(gov.accRewards()).toEqual(1000);
    expect(gov.pendingOf(alice.address)).toEqual(1000); // sole staker gets the whole pool
    val res = gov.sendClaim(alice.address, 0, { value: ton("0.1") });
    expect(res).toHaveSuccessfulTx();
    expect(gov.pendingOf(alice.address)).toEqual(0);
}

get fun `test claim with no rewards is rejected`() {
    val (gov, _, alice, gw) = deployGov();
    stake(gov, gw, alice, 1000000);
    expect(gov.sendClaim(alice.address, 0, { value: ton("0.1") }))
        .toHaveFailedTx({ from: alice.address, to: gov.address, exitCode: 406 });
}

get fun `test rewards split pro-rata across two stakers`() {
    val (gov, owner, alice, gw) = deployGov();
    val bob = testing.treasury("bob");
    stake(gov, gw, alice, 3000000);
    stake(gov, gw, bob, 1000000);
    gov.sendNotifyRewards(owner.address, 0, 4000, { value: ton("0.05") });
    expect(gov.pendingOf(alice.address)).toEqual(3000);
    expect(gov.pendingOf(bob.address)).toEqual(1000);
}

get fun `test unstake reduces the stake and total`() {
    val (gov, _, alice, gw) = deployGov();
    stake(gov, gw, alice, 1000000);
    val res = gov.sendUnstake(alice.address, 0, 400000, { value: ton("0.1") });
    expect(res).toHaveSuccessfulTx();
    expect(gov.totalStaked()).toEqual(600000);
    expect(gov.stakeOf(alice.address).amount).toEqual(600000);
}

get fun `test unstake beyond the stake is rejected`() {
    val (gov, _, alice, gw) = deployGov();
    stake(gov, gw, alice, 1000000);
    expect(gov.sendUnstake(alice.address, 0, 2000000, { value: ton("0.1") }))
        .toHaveFailedTx({ from: alice.address, to: gov.address, exitCode: 403 });
}

get fun `test non-owner cannot notify rewards`() {
    val (gov, _, alice, gw) = deployGov();
    stake(gov, gw, alice, 1000000);
    expect(gov.sendNotifyRewards(alice.address, 0, 1000, { value: ton("0.05") }))
        .toHaveFailedTx({ from: alice.address, to: gov.address, exitCode: 401 });
}

get fun `test proposal requires a staker`() {
    val (gov, _, alice, _) = deployGov();
    expect(gov.sendPropose(alice.address, 0, 1, 1, 5, 4102444800, { value: ton("0.05") }))
        .toHaveFailedTx({ from: alice.address, to: gov.address, exitCode: 404 });
}

get fun `test staker can propose and the vote is weighted by stake`() {
    val (gov, _, alice, gw) = deployGov();
    stake(gov, gw, alice, 1000000);
    gov.sendPropose(alice.address, 0, 1, 1, 5, 4102444800, { value: ton("0.05") });
    expect(gov.proposalAt(1).endTs).toEqual(4102444800);
    val res = gov.sendVote(alice.address, 0, 1, true, { value: ton("0.05") });
    expect(res).toHaveSuccessfulTx();
    expect(gov.proposalAt(1).forVotes).toEqual(1000000);
    expect(gov.proposalAt(1).againstVotes).toEqual(0);
    expect(gov.lastVoteOf(alice.address)).toEqual(1);
}

get fun `test a second vote on the same proposal is rejected`() {
    val (gov, _, alice, gw) = deployGov();
    stake(gov, gw, alice, 1000000);
    gov.sendPropose(alice.address, 0, 1, 1, 5, 4102444800, { value: ton("0.05") });
    gov.sendVote(alice.address, 0, 1, true, { value: ton("0.05") });
    expect(gov.sendVote(alice.address, 0, 1, true, { value: ton("0.05") }))
        .toHaveFailedTx({ from: alice.address, to: gov.address, exitCode: 408 });
}

get fun `test voting on an unknown proposal is rejected`() {
    val (gov, _, alice, gw) = deployGov();
    stake(gov, gw, alice, 1000000);
    expect(gov.sendVote(alice.address, 0, 99, true, { value: ton("0.05") }))
        .toHaveFailedTx({ from: alice.address, to: gov.address, exitCode: 410 });
}

get fun `test owner setters are owner-gated`() {
    val (gov, _, alice, _) = deployGov();
    expect(gov.sendSetPaused(alice.address, 0, true, { value: ton("0.05") }))
        .toHaveFailedTx({ from: alice.address, to: gov.address, exitCode: 401 });
    expect(gov.sendSetGovWallet(alice.address, 0, alice.address, { value: ton("0.05") }))
        .toHaveFailedTx({ from: alice.address, to: gov.address, exitCode: 401 });
    expect(gov.sendSetOwner(alice.address, 0, alice.address, { value: ton("0.05") }))
        .toHaveFailedTx({ from: alice.address, to: gov.address, exitCode: 401 });
}
