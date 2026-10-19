import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@wrappers/PlanetBond.gen"
import "@wrappers/PlanetCore.gen"

// Deploys ONLY PlanetBond (the existing Core/Minter/Basket are already live; re-running
// the full deploy script would re-deploy them).
//
// The bond is wired to the Core twice:
//   1) `core` is baked into the Bond's storage at deploy time. The Bond accepts the
//      automatic `SetOpen` trigger ONLY from its owner or from this address.
//   2) PlanetCore must learn the bond with `SetBond` (op 0x10000019) to drive it.
//
// On the live testnet the Core owner is a 60s PlanetTimelock, so step 2 must go through
// Propose -> 60s -> Execute. This script performs it directly only when the deployer is
// still the Core owner (fresh/emulated stacks) and otherwise prints the timelock body.
//
//   cd ton && acton script scripts/deploy_bond.tolk --net testnet

// Live testnet Core (v1.8). Update this after a Core redeploy.
const CORE = "kQBUIDOcKIQZS_AMXjOL3usH69c3HIo0YudLoo_49eE0X2NJ";

fun main() {
    val deployer = scripts.wallet("deployer");
    val core = PlanetCore.fromAddress(address(CORE));

    val bond = PlanetBond.fromStorage({
        owner: deployer.address,
        core: core.address,       // auto-trigger authority (SetOpen)
        open: false,              // PPI < 0.95 opens it automatically once wired
        premiumBps: 500,          // 5% face premium
        totalIssued: 0,
        bonds: [],
    });
    bond.deploy(deployer.address, { value: ton("0.2") });
    println("PlanetBond -> {}", bond.address);

    if (!scripts.isContractDeployed(core.address)) {
        println("Core {} is not deployed in this environment — skipping the SetBond check.", core.address);
        println("On testnet: SetBond(queryId=0, bond={}) via the Core owner (op 0x10000019).", bond.address);
    } else if (core.owner() == deployer.address) {
        core.sendSetBond(deployer.address, 0, bond.address, { value: ton("0.05") });
        println("Core.bond wired directly (deployer is still the Core owner).");
    } else {
        println("Core owner is {} — wire Core.bond through the timelock:", core.owner());
        println("  target = {}", core.address);
        println("  body   = SetBond(queryId=0, bond={})  // op 0x10000019", bond.address);
        println("  then   Propose -> delay -> Execute");
    }
    println("Deploy complete.");
}
