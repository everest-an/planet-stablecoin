import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/emulation/network"
import "@wrappers/PlanetTimelock.gen"
import "@wrappers/PlanetCore.gen"

const DEMO = "kQCMwDVPftkUbRWPMzJGCjoC4YXnFGfN3myTJ1rbeCuSdPAt";
const CORE = "kQAzxh1PoqeXWVYQrABxZky8_bAXddjoGTPbqN4tv8Zsfuul";

// Step 3: the demo timelock proposes a delayed SetOwner(Core, deployer).
fun main() {
    val deployer = scripts.wallet("deployer");
    val demo = PlanetTimelock.fromAddress(address(DEMO));
    val body = beginCell().storeUint(0x10000014, 32).storeInt(0, 64).storeAddress(deployer.address).endCell();
    demo.sendTlPropose(deployer.address, 0, address(CORE), body, { value: ton("0.05") });
    println("proposed SetOwner(Core, deployer) via timelock");
}
