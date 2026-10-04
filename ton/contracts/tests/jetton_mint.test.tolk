import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@acton/build"
import "@wrappers/PlanetCore.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@contracts/oracle_state"
import "@contracts/limits"

// Full-link integration test:
//   user Mint → PlanetCore (PPI accounting) → JettonMinter MintNewJettons
//   → auto-deploy recipient's JettonWallet → PLT balance credited.
//
// This exercises the wiring that the unit tests cannot: the mint message the
// PlanetCore forwards must actually create the recipient wallet and credit PLT.

// Deploys PlanetCore + the PLT Jetton minter, with PlanetCore as the minter admin.
fun deployPlanetMintSetup(): (PlanetCore, JettonMinter, Treasury, Treasury) {
    val deployer = testing.treasury("deployer");
    val alice = testing.treasury("alice");

    // 1) PlanetCore. The minter address is a placeholder here because a contract's
    //    address is fixed at deploy time; we point it at the real minter via
    //    SetJettonMinter once the minter exists (avoids a circular address dependency).
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
    expect(core.deploy(deployer.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: core.address });

    // 2) PLT Jetton minter, with PlanetCore as admin so it may send MintNewJettons.
    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: core.address,
        content: beginCell().endCell(),
        jettonWalletCode: build("JettonWallet"),
    });
    expect(minter.deploy(deployer.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: minter.address });

    // 3) Wire PlanetCore → minter (owner-gated SetJettonMinter).
    core.sendSetJettonMinter(deployer.address, 0, minter.address, { value: ton("0.05") });

    return (core, minter, deployer, alice);
}

get fun `test mint credits PLT through the jetton minter`() {
    val (core, minter, _, alice) = deployPlanetMintSetup();

    val deposit = 1000000;   // 1.0 USDC (6 decimals)
    val expectedPlt = 995000; // mint at PPI 1.0, 0.5% fee

    val res = core.sendMint(alice.address, 0, deposit, { value: ton("1") });
    expect(res).toHaveAllSuccessfulTxs();

    // The minter's total supply reflects the freshly minted PLT.
    expect(minter.getJettonData().totalSupply).toEqual(expectedPlt);

    // The recipient's auto-deployed wallet holds the PLT (the real end-to-end check).
    val wallet = JettonWallet.fromAddress(minter.getWalletAddress(alice.address));
    expect(wallet.getWalletData().jettonBalance).toEqual(expectedPlt);

    // PlanetCore accounting.
    expect(core.supply()).toEqual(expectedPlt);
    expect(core.reserve()).toEqual(deposit);
}

get fun `test wallet burn reduces minter supply`() {
    val (core, minter, _, alice) = deployPlanetMintSetup();

    core.sendMint(alice.address, 0, 1000000, { value: ton("1") });
    val wallet = JettonWallet.fromAddress(minter.getWalletAddress(alice.address));
    expect(wallet.getWalletData().jettonBalance).toEqual(995000);

    // alice burns 100000 PLT through her own wallet (TEP-74 AskToBurn).
    val res = wallet.sendAskToBurn(alice.address, 0, 100000, null, null, { value: ton("0.2") });
    expect(res).toHaveAllSuccessfulTxs();

    expect(wallet.getWalletData().jettonBalance).toEqual(895000);
    expect(minter.getJettonData().totalSupply).toEqual(895000);
    // the minter mirrors the burn to PlanetCore, keeping core accounting in sync
    expect(core.supply()).toEqual(895000);
    expect(core.reserve()).toEqual(900500); // 1e6 - burnAmount(100000, 1e6)=99500
}

get fun `test wallet transfer moves PLT to recipient`() {
    val (core, minter, _, alice) = deployPlanetMintSetup();
    val bob = testing.treasury("bob");

    core.sendMint(alice.address, 0, 1000000, { value: ton("1") });
    val aliceWallet = JettonWallet.fromAddress(minter.getWalletAddress(alice.address));
    expect(aliceWallet.getWalletData().jettonBalance).toEqual(995000);

    // non-empty forward payload is required by the wallet's AskToTransfer handler.
    val payload = beginCell().storeUint(1, 1).endCell().beginParse();
    val res = aliceWallet.sendAskToTransfer(
        alice.address, 0, 200000, bob.address, null, null, 0, payload, { value: ton("0.2") },
    );
    expect(res).toHaveAllSuccessfulTxs();

    val bobWallet = JettonWallet.fromAddress(minter.getWalletAddress(bob.address));
    expect(bobWallet.getWalletData().jettonBalance).toEqual(200000);
    expect(aliceWallet.getWalletData().jettonBalance).toEqual(795000);
    expect(minter.getJettonData().totalSupply).toEqual(995000);
}

get fun `test non-owner cannot transfer PLT`() {
    val (core, minter, _, alice) = deployPlanetMintSetup();
    val mallory = testing.treasury("mallory");

    core.sendMint(alice.address, 0, 1000000, { value: ton("1") });
    val wallet = JettonWallet.fromAddress(minter.getWalletAddress(alice.address));

    val payload = beginCell().storeUint(1, 1).endCell().beginParse();
    val res = wallet.sendAskToTransfer(
        mallory.address, 0, 1, mallory.address, null, null, 0, payload, { value: ton("0.2") },
    );
    expect(res).toHaveFailedTx({ from: mallory.address, to: wallet.address, exitCode: 705 });
}

get fun `test transfer above balance fails`() {
    val (core, minter, _, alice) = deployPlanetMintSetup();

    core.sendMint(alice.address, 0, 1000000, { value: ton("1") });
    val wallet = JettonWallet.fromAddress(minter.getWalletAddress(alice.address));

    val payload = beginCell().storeUint(1, 1).endCell().beginParse();
    val res = wallet.sendAskToTransfer(
        alice.address, 0, 2000000, alice.address, null, null, 0, payload, { value: ton("0.2") },
    );
    expect(res).toHaveFailedTx({ from: alice.address, to: wallet.address, exitCode: 706 });
}

get fun `test transfer with forward payload notifies recipient and returns excesses`() {
    val (core, minter, _, alice) = deployPlanetMintSetup();
    val bob = testing.treasury("bob");

    core.sendMint(alice.address, 0, 1000000, { value: ton("1") });
    val aliceWallet = JettonWallet.fromAddress(minter.getWalletAddress(alice.address));

    // forwardTonAmount > 0 → recipient gets a TransferNotificationForRecipient;
    // sendExcessesTo non-null → the receiving wallet returns leftover TON.
    val payload = beginCell().storeUint(1, 1).endCell().beginParse();
    val res = aliceWallet.sendAskToTransfer(
        alice.address, 0, 100000, bob.address, alice.address, null, ton("0.05"), payload, { value: ton("0.5") },
    );
    expect(res).toHaveAllSuccessfulTxs();

    val bobWallet = JettonWallet.fromAddress(minter.getWalletAddress(bob.address));
    expect(bobWallet.getWalletData().jettonBalance).toEqual(100000);
    expect(aliceWallet.getWalletData().jettonBalance).toEqual(895000);
}
