import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@wrappers/PlanetTimelock.gen"
import "@wrappers/PlanetCore.gen"

const DEMO = "kQCMwDVPftkUbRWPMzJGCjoC4YXnFGfN3myTJ1rbeCuSdPAt";
const CORE = "kQB_jRsajqfsRNI8Pp7pqr1zlAbBhIoMBzITYWEainyEm2bH";

// Step 4: execute the pending timelocked action (delay = 0) -> restores deployer as owner.
fun main() {
    val deployer = scripts.wallet("deployer");
    val demo = PlanetTimelock.fromAddress(address(DEMO));
    demo.sendTlExecute(deployer.address, 0, { value: ton("0.15") });
    println("timelock execute sent");
}
