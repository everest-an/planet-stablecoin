import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@acton/build"
import "@contracts/oracle_state"
import "@contracts/limits"
import "@wrappers/PlanetCore.gen"
import "@wrappers/JettonMinter.gen"

// Deploys the immutable core stack and wires it together:
//   1) PlanetCore   (owner = deployer; oracle = deployer as a safe placeholder)
//   2) JettonMinter (admin = PlanetCore, so core may MintNewJettons)
//   3) PlanetCore.SetJettonMinter(minter)
//
// PlanetBasket is NOT deployed: it is deprecated (BK-1) and the live basket belongs to
// PlanetCore (assetAt / assetCount).
//
// Attached values are deliberately LEAN: any excess is parked in the contract FOREVER
// (unrecoverable) — the previous Core accumulated 1.63 TON that way. See docs/deploy-runbook.md.
//
// Emulation (no network, validates the flow):
//     cd ton && acton script scripts/deploy.tolk
// Real testnet (requires `wallets.toml` with a funded wallet):
//     acton script scripts/deploy.tolk --net testnet
//
// NOTE: on a real network, `oracle` must be set to the RedStone/DIA adapter address
// afterwards (see docs/oracle-ton.md) — here it defaults to the deployer.

fun main() {
    val deployer = scripts.wallet("deployer");

    // 1) PlanetCore. Uses a placeholder minter address, wired in step 3.
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
        limitsState: Limits { maxPerTx: 0, arbRebateBps: 0, riskFund: 0, bond: address("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c"), bondOpen: false, bondPaid: 0 }.toCell(),
    });
    core.deploy(deployer.address, { value: ton("0.08") });
    println("PlanetCore    -> {}", core.address);

    // 2) PLT Jetton minter, admin = PlanetCore.
    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: core.address,
        content: beginCell().endCell(),
        jettonWalletCode: build("JettonWallet"),
    });
    minter.deploy(deployer.address, { value: ton("0.05") });
    println("PLT Minter    -> {}  (admin = PlanetCore)", minter.address);

    // 3) Wire PlanetCore -> minter.
    core.sendSetJettonMinter(deployer.address, 0, minter.address, { value: ton("0.05") });

    // 4) PlanetBasket is intentionally NOT deployed (deprecated, BK-1): the basket lives in
    //    PlanetCore, and a second dead registry only adds a misleading address to the site.

    // Verify the contracts are ACTUALLY live before declaring success. `deploy()` only
    // broadcasts; if the wallet is out of gas the messages never land and the account
    // stays uninitialised — these get-method calls would then fail loudly.
    println("verify: core.assetCount = {}", core.assetCount());
    println("verify: core.ppi        = {}", core.ppi());
    println("verify: minter.supply   = {}", minter.getJettonData().totalSupply);

    println("Deploy complete.");
}
