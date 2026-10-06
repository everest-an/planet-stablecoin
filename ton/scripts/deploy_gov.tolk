import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@acton/build"
import "@wrappers/PlanetGov.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"

// Deploys the PLTG governance stack:
//   1) a fixed-supply PLTG TEP-74 jetton minter (genesis supply minted to the deployer),
//   2) PlanetGov wired to that minter (staking + pro-rata fee dividends + stake-weighted
//      parameter voting — the 25% fee bucket from PlanetCore is fed in via NotifyRewards),
//   3) the gov's OWN PLTG jetton wallet (so it can receive stakes and send them back).
//
//   cd ton && acton script scripts/deploy_gov.tolk --net testnet

// 1e9 tokens, 6 decimals (matches the PLT convention).
const PLTG_SUPPLY = 1000000000000000;

fun main() {
    val deployer = scripts.wallet("deployer");

    // 1) PLTG jetton minter (admin = deployer, so the genesis supply can be minted below).
    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: deployer.address,
        content: beginCell().endCell(),
        jettonWalletCode: build("JettonWallet"),
    });
    minter.deploy(deployer.address, { value: ton("0.15") });
    println("PLTG Minter -> {}", minter.address);

    // 2) PlanetGov wired to the PLTG minter.
    val gov = PlanetGov.fromStorage({
        owner: deployer.address,
        pltMinter: minter.address,
        govWallet: beginCell().storeAddress(deployer.address).endCell(),
        totalStaked: 0,
        accRewardPerShare: 0,
        accRewards: 0,
        paused: false,
        proposals: [],
        stakes: [],
        lastVote: [],
    });
    gov.deploy(deployer.address, { value: ton("0.15") });
    println("PlanetGov   -> {}", gov.address);

    // 3) point the gov at its OWN PLTG jetton wallet (verified on stake receipt).
    gov.sendSetGovWallet(deployer.address, 0, minter.getWalletAddress(gov.address), { value: ton("0.05") });

    // 4) mint the genesis supply to the deployer (the distributor).
    val step = InternalTransferStep {
        queryId: 0,
        jettonAmount: PLTG_SUPPLY as coins,
        transferInitiator: null,
        sendExcessesTo: null,
        forwardTonAmount: 0,
        forwardPayload: beginCell().endCell().beginParse(),
    };
    minter.sendMintNewJettons(deployer.address, 0, deployer.address, ton("0.05"), step.toCell(), { value: ton("0.2") });
    println("minted PLTG genesis supply = {}", PLTG_SUPPLY);

    println("PLTG + PlanetGov deploy done.");
}
