import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@wrappers/PlanetBond.gen"

// Deploys ONLY PlanetBond (the existing Core/Minter/Basket are already live; re-running
// the full deploy script would re-deploy them). `core` is a reference-only field here.
//
//   cd ton && acton script scripts/deploy_bond.tolk --net testnet

fun main() {
    val deployer = scripts.wallet("deployer");

    val bond = PlanetBond.fromStorage({
        owner: deployer.address,
        core: deployer.address,   // reference only (set to the live Core later if needed)
        open: false,              // owner opens the sale when PPI < 0.95
        premiumBps: 500,          // 5% face premium
        totalIssued: 0,
        bonds: [],
    });
    bond.deploy(deployer.address, { value: ton("0.2") });
    println("PlanetBond -> {}", bond.address);
    println("Deploy complete.");
}
