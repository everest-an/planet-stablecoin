import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@acton/build"
import "@contracts/jetton/messages"
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
    //    The content cell MUST be unique: an identical storage would otherwise collide with
    //    another JettonMinter already deployed (same code+storage => same address, and the
    //    deploy would be ignored). A real TEP-64 JSON metadata URI should replace this marker.
    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: deployer.address,
        content: beginCell().storeUint(0x504C5447, 32).storeUint(0x0001, 16).endCell(), // "PLTG" + ver
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

    // 4) mint the genesis supply to the deployer (the distributor) — ONCE ONLY.
    //    The PLTG minter's address is DETERMINISTIC (its code and storage are unchanged), so a
    //    re-run REUSES the existing minter instead of creating a new one. An unconditional mint
    //    therefore silently doubles the supply — which actually happened (1e15 -> 2e15). Guard on
    //    the live totalSupply so the genesis allocation is minted exactly once.
    if ((minter.getJettonData().totalSupply as int) == 0) {
        val step = InternalTransferStep {
            queryId: 0,
            jettonAmount: PLTG_SUPPLY as coins,
            transferInitiator: null,
            sendExcessesTo: null,
            forwardTonAmount: 0,
            forwardPayload: beginCell().endCell().beginParse(),
        };
        // The wrapper's sendMintNewJettons takes the step STRUCT (it wraps it into a cell itself).
        minter.sendMintNewJettons(deployer.address, 0, deployer.address, ton("0.05"), step, { value: ton("0.2") });
        println("minted PLTG genesis supply = {}", PLTG_SUPPLY);
    } else {
        println("PLTG genesis supply already minted (totalSupply = {}); skipping", minter.getJettonData().totalSupply);
    }

    // Verify the deploys ACTUALLY landed. deploy()/send only broadcast: a drained wallet
    // leaves the accounts uninitialised (and the mint silently un-applied), so read them
    // back and fail loudly instead of reporting a fake success.
    println("verify: pltg.totalSupply = {}", minter.getJettonData().totalSupply);
    println("verify: gov.totalStaked  = {}", gov.totalStaked());
    println("verify: gov.pltMinter    = {}", gov.pltMinter());

    println("PLTG + PlanetGov deploy done.");
}
