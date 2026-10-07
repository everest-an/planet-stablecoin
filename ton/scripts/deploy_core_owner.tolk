import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@wrappers/PlanetTimelock.gen"
import "@wrappers/PlanetCore.gen"

// Migrates the live PlanetCore's ownership to a PlanetTimelock, so every privileged action
// (basket changes via GovernanceSetWeight/GovernanceAddAsset, limits, fees, SetOwner) must go
// through Propose -> delay -> Execute. Testnet uses a 60s delay (fast to demo, still a real
// gate); production would use 24h+ and a TON multisig as the timelock's owner.
//
//   cd ton && acton script scripts/deploy_core_owner.tolk --net testnet

fun main() {
    val deployer = scripts.wallet("deployer");
    val core = PlanetCore.fromAddress(address("kQBUIDOcKIQZS_AMXjOL3usH69c3HIo0YudLoo_49eE0X2NJ"));

    // Timelock: 60s reaction window, owned by the deployer (production: a multisig).
    val tl = PlanetTimelock.fromStorage({
        owner: deployer.address,
        delay: 60,
        hasPending: false,
        dest: deployer.address,
        body: beginCell().endCell(),
        eta: 0,
    });
    tl.deploy(deployer.address, { value: ton("0.12") });
    println("PlanetTimelock (core owner, 60s) -> {}", tl.address);

    // Move Core ownership to the timelock.
    core.sendSetOwner(deployer.address, 0, tl.address, { value: ton("0.05") });
    println("Core owner migrated to the timelock (Propose -> 60s -> Execute).");
}
