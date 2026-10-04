import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@wrappers/PlanetTimelock.gen"
import "@wrappers/PlanetCore.gen"

const DEMO = "kQCMwDVPftkUbRWPMzJGCjoC4YXnFGfN3myTJ1rbeCuSdPAt";
const CORE = "kQB_jRsajqfsRNI8Pp7pqr1zlAbBhIoMBzITYWEainyEm2bH";

// Step 1: clear any leftover pending proposal on the demo timelock (no message to Core).
fun main() {
    val deployer = scripts.wallet("deployer");
    val demo = PlanetTimelock.fromAddress(address(DEMO));
    demo.sendTlCancel(deployer.address, 0, { value: ton("0.05") });
    println("demo pending cancelled");
}
