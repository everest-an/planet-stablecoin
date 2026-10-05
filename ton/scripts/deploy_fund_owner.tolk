import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@wrappers/PlanetFund.gen"
import "@wrappers/PlanetTimelock.gen"

// Migrates the live PlanetFund's ownership to a PlanetTimelock, so every privileged
// action (SetFees / SetCustodian / SetPaused / SetKyc / SetOwner ...) must go through
// Propose -> delay -> Execute. In production the timelock's owner would be a TON multisig.
//
//   cd ton && acton script scripts/deploy_fund_owner.tolk --net testnet

fun main() {
    val deployer = scripts.wallet("deployer");
    val fund = PlanetFund.fromAddress(address("kQAYbx_u7I7yhcYU8yxeewWdh3gnS067IgaWeV8UlYItug1o"));

    // A timelock with a 60s reaction window (production: 24h+), owned by the deployer.
    val tl = PlanetTimelock.fromStorage({
        owner: deployer.address,
        delay: 60,
        hasPending: false,
        dest: deployer.address,
        body: beginCell().endCell(),
        eta: 0,
    });
    tl.deploy(deployer.address, { value: ton("0.15") });
    println("PlanetTimelock (fund owner) -> {}", tl.address);

    // Move fund ownership to the timelock.
    fund.sendSetOwner(deployer.address, 0, tl.address, { value: ton("0.05") });
    println("Fund ownership migrated to the timelock.");
}
