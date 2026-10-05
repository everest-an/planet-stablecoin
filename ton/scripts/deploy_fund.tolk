import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@acton/build"
import "@wrappers/PlanetFund.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"

// Deploys PlanetFund to TON testnet and exercises the two-phase subscribe end-to-end:
//   deploy minter (admin -> fund) + fund -> register a 1-of-1 custodian (the deployer
//   key) -> Subscribe -> sign the confirm payload -> ConfirmMint mints PLT shares at NAV.
//
//   cd ton && acton script scripts/deploy_fund.tolk --net testnet

fun main() {
    val deployer = scripts.wallet("deployer");

    // 1) PLT minter for the fund (admin starts as the deployer, then moves to the fund).
    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: deployer.address,
        content: beginCell().endCell(),
        jettonWalletCode: build("JettonWallet"),
    });
    minter.deploy(deployer.address, { value: ton("0.1") });
    println("PLT minter (fund) -> {}", minter.address);

    // 2) The fund, wired to the minter.
    val fund = PlanetFund.fromStorage({
        owner: deployer.address,
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
        // empty OrdersStore (two empty maps = two "0" maybe-bits); placeholder fund wallet.
        ordersStore: beginCell().storeUint(0, 1).storeUint(0, 1).endCell(),
        fundWallet: beginCell().storeAddress(deployer.address).endCell(),
    });
    fund.deploy(deployer.address, { value: ton("0.15") });
    println("PlanetFund        -> {}", fund.address);

    // 3) Wire the minter admin to the fund (so the fund may MintNewJettons).
    minter.sendChangeMinterAdmin(deployer.address, 0, fund.address, { value: ton("0.05") });

    // 3b) Point the fund at its OWN jetton wallet (verified on share receipt at redemption).
    fund.sendSetFundWallet(deployer.address, 0, minter.getWalletAddress(fund.address), { value: ton("0.05") });

    // 4) Register a 1-of-1 custodian (the deployer key, for this testnet demo).
    fund.sendSetCustodian(deployer.address, 0, 0, deployer.publicKey() as uint256, { value: ton("0.05") });
    fund.sendSetCustodianThreshold(deployer.address, 0, 1, { value: ton("0.05") });

    // 5) Two-phase subscribe: register the order, then custodian-confirm the mint.
    val orderId = 1;
    val nav = 1000000;      // NAV 1.0 per share
    val ts = 1000000;       // attestation timestamp
    fund.sendSubscribe(deployer.address, orderId, 1000000, { value: ton("0.05") }); // 1.0 USDC

    val hashCell = beginCell()
        .storeUint(0x46554E44, 32)     // "FUND"
        .storeAddress(fund.address)
        .storeInt(orderId, 64)
        .storeInt(nav, 64)
        .storeInt(ts, 64)
        .endCell();
    val sig = deployer.sign(hashCell);
    val sigs = beginCell().storeUint(1, 8).storeRef(beginCell().storeSlice(sig).endCell()).endCell();

    fund.sendConfirmMint(deployer.address, 0, orderId, nav, ts, sigs, { value: ton("0.2") });

    // 6) Redemption is two-phase and now requires the shares to actually arrive: the subscriber
    //    registers a request, transfers PLT shares to the FUND's jetton wallet (the transfer
    //    notification marks the redeem funded and burns the shares), and only then can the
    //    custodian confirm the payout. We register the request here; funding + confirm are
    //    exercised end-to-end in the test suite.
    val redeemId = 2;
    fund.sendRequestRedeem(deployer.address, redeemId, 500000, { value: ton("0.05") });
    println("Redeem request registered (transfer shares to the fund wallet, then ConfirmRedeem).");
    println("Fund deploy + two-phase subscribe done.");
}
