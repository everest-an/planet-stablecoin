import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@wrappers/PlanetTimelock.gen"
import "@wrappers/PlanetCore.gen"

const DEMO = "kQCMwDVPftkUbRWPMzJGCjoC4YXnFGfN3myTJ1rbeCuSdPAt";
const CORE = "kQAzxh1PoqeXWVYQrABxZky8_bAXddjoGTPbqN4tv8Zsfuul";

// Step 2: migrate Core ownership to the demo timelock (single owner message).
fun main() {
    val deployer = scripts.wallet("deployer");
    val core = PlanetCore.fromAddress(address(CORE));
    core.sendSetOwner(deployer.address, 0, address(DEMO), { value: ton("0.05") });
    println("Core owner -> demo timelock");
}
