import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@acton/build"
import "@wrappers/JettonMinter.gen"

// JettonMinter admin path coverage: admin-only mutations, their rejection for
// non-admins, and the wallet-address discovery request (TEP-89).

fun deployMinter(): (JettonMinter, Treasury, Treasury) {
    val deployer = testing.treasury("deployer");
    val outsider = testing.treasury("outsider");
    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: deployer.address,
        content: beginCell().endCell(),
        jettonWalletCode: build("JettonWallet"),
    });
    expect(minter.deploy(deployer.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: minter.address });
    return (minter, deployer, outsider);
}

get fun `test minter admin can change admin`() {
    val (minter, deployer, outsider) = deployMinter();
    val res = minter.sendChangeMinterAdmin(deployer.address, 0, outsider.address, { value: ton("0.05") });
    expect(res).toHaveAllSuccessfulTxs();
    expect(minter.getJettonData().adminAddress).toEqual(outsider.address);
}

get fun `test non-admin cannot change admin`() {
    val (minter, _, outsider) = deployMinter();
    val res = minter.sendChangeMinterAdmin(outsider.address, 0, outsider.address, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: outsider.address, to: minter.address, exitCode: 73 });
}

get fun `test minter admin can change content`() {
    val (minter, deployer, _) = deployMinter();
    val res = minter.sendChangeMinterContent(deployer.address, 0, beginCell().storeUint(1, 1).endCell(), { value: ton("0.05") });
    expect(res).toHaveAllSuccessfulTxs();
}

get fun `test non-admin cannot change content`() {
    val (minter, _, outsider) = deployMinter();
    val res = minter.sendChangeMinterContent(outsider.address, 0, beginCell().endCell(), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: outsider.address, to: minter.address, exitCode: 73 });
}

get fun `test wallet address discovery request`() {
    val (minter, deployer, outsider) = deployMinter();
    // TEP-89: RequestWalletAddress is answered with the computed wallet address.
    val res = minter.sendRequestWalletAddress(outsider.address, 0, deployer.address, true, { value: ton("0.1") });
    expect(res).toHaveAllSuccessfulTxs();
}

get fun `test non-admin cannot mint`() {
    val (minter, _, outsider) = deployMinter();
    val res = minter.sendMintNewJettons(outsider.address, 0, outsider.address, ton("0.05"), beginCell().endCell(), { value: ton("0.1") });
    expect(res).toHaveFailedTx({ from: outsider.address, to: minter.address, exitCode: 73 });
}

get fun `test unauthorized burn notification is rejected`() {
    val (minter, _, outsider) = deployMinter();
    val res = minter.sendBurnNotificationForMinter(outsider.address, 0, 1000, outsider.address, null, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: outsider.address, to: minter.address, exitCode: 74 });
}

get fun `test unknown minter opcode is rejected`() {
    val (minter, _, outsider) = deployMinter();
    val res = minter.sendAny(outsider.address, beginCell().storeUint(0xDEAD, 32).endCell(), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: outsider.address, to: minter.address, exitCode: 65535 });
}
