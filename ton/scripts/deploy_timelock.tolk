import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@wrappers/PlanetTimelock.gen"
import "@wrappers/PlanetCore.gen"

// Deploys PlanetTimelock to TON testnet and proves the delayed-owner flow on-chain:
//
//   1) prod timelock: delay = 24h (this is what Core.owner should be migrated to;
//      set its owner to a TON multisig wallet in production -> M-of-N + delay).
//   2) demo timelock (delay = 0) + tl2 (owner = demo): demo proposes SetDelay(777)
//      on tl2, then executes -> prove Propose -> Execute -> replay delivery.
//   3) Core owner round-trip through the timelock: SetOwner(Core, demo) directly,
//      then the demo timelock proposes+executes SetOwner(Core, deployer) -> proves a
//      TIMELOCKED owner action on the live Core, and restores the deployer as owner.
//
//   cd ton && acton script scripts/deploy_timelock.tolk --net testnet

fun main() {
    val deployer = scripts.wallet("deployer");
    val core = address("kQAyzbletVLCFV7IsR1Vik6hxYVLIANZ7oBYE9wRJPGKnQBV");

    // 1) production-style timelock (24h reaction window)
    val prod = PlanetTimelock.fromStorage({
        owner: deployer.address, delay: 86400, hasPending: false,
        dest: deployer.address, body: beginCell().endCell(), eta: 0,
    });
    prod.deploy(deployer.address, { value: ton("0.1") });
    println("PlanetTimelock (24h)  -> {}", prod.address);

    // 2) demo timelock (0s) + a target whose owner is the demo timelock
    val demo = PlanetTimelock.fromStorage({
        owner: deployer.address, delay: 0, hasPending: false,
        dest: deployer.address, body: beginCell().endCell(), eta: 0,
    });
    demo.deploy(deployer.address, { value: ton("0.1") });
    println("PlanetTimelock (demo) -> {}", demo.address);

    val tl2 = PlanetTimelock.fromStorage({
        owner: demo.address, delay: 0, hasPending: false,
        dest: deployer.address, body: beginCell().endCell(), eta: 0,
    });
    tl2.deploy(deployer.address, { value: ton("0.1") });
    println("PlanetTimelock (tl2)  -> {}", tl2.address);

    // 2a) timelock drives a target: propose SetDelay(777) on tl2, then execute
    //     TlSetDelay { queryId: 0, delay: 777 }  (op 0x20000004)
    val setDelayBody = beginCell().storeUint(0x20000004, 32).storeInt(0, 64).storeInt(777, 64).endCell();
    demo.sendTlPropose(deployer.address, 0, tl2.address, setDelayBody, { value: ton("0.05") });
    demo.sendTlExecute(deployer.address, 0, { value: ton("0.15") });

    // 3) Core owner round-trip: SetOwner(Core, demo) directly (current owner = deployer)
    core.sendSetOwner(deployer.address, 0, demo.address, { value: ton("0.05") });

    // then a TIMELOCKED owner action: demo proposes+executes SetOwner(Core, deployer)
    //     SetOwner { queryId: 0, newOwner: deployer }  (op 0x10000014)
    val restoreBody = beginCell().storeUint(0x10000014, 32).storeInt(0, 64).storeAddress(deployer.address).endCell();
    demo.sendTlPropose(deployer.address, 0, core, restoreBody, { value: ton("0.05") });
    demo.sendTlExecute(deployer.address, 0, { value: ton("0.15") });

    println("Timelock deploy + flow done.");
}
