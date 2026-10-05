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
        fundWallet: deployer.address,
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
        redeems: [],
    });
    fund.deploy(deployer.address, { value: ton("0.15") });
    println("PlanetFund        -> {}", fund.address);

    // 3) Wire the minter admin to the fund (so the fund may MintNewJettons).
    minter.sendChangeMinterAdmin(deployer.address, 0, fund.address, { value: ton("0.05") });

    // 3b) Point the fund at its own jetton wallet (for share receipt on redemption).
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

    // 6) Redemption: request + custodian-confirmed payout (NAV 1.0, fee 0.5%).
    val redeemId = 2;
    val ts2 = 1000001;
    fund.sendRequestRedeem(deployer.address, redeemId, 500000, { value: ton("0.05") });
    val rhashCell = beginCell()
        .storeUint(0x46554E44, 32)
        .storeAddress(fund.address)
        .storeInt(redeemId, 64)
        .storeInt(nav, 64)
        .storeInt(ts2, 64)
        .endCell();
    val rsig = deployer.sign(rhashCell);
    val rsigs = beginCell().storeUint(1, 8).storeRef(beginCell().storeSlice(rsig).endCell()).endCell();
    fund.sendConfirmRedeem(deployer.address, 0, redeemId, nav, ts2, rsigs, { value: ton("0.2") });

    println("Fund deploy + two-phase subscribe + redeem done.");
}
