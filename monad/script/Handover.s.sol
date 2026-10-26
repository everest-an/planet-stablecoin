// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PlanetCore} from "../src/PlanetCore.sol";
import {PlanetToken} from "../src/PlanetToken.sol";

/**
 * Moves ownership of the core and the token to the deployed PlanetTimelock.
 *
 * WHY THIS EXISTS: the deploy script has to keep the deployer as owner long enough to wire the
 * token, the oracle, the deposit token and the basket. But leaving it there means every privileged
 * action — forcePrice, setRelayer, setRiskState, pause, setMinter — executes instantly with one key,
 * while the documentation promises a 60-second delay. That gap is the single largest hole in the
 * system: `token.owner` can call setMinter(self), mint unlimited PLT, point the minter back at the
 * core and redeem the reserve.
 *
 * After this runs, every admin action must go propose -> wait delay -> execute through the timelock,
 * and the relayer (a separate role) keeps pushing prices without touching ownership.
 *
 * Order matters: deploy -> configure basket -> handover. Configuration needs owner rights.
 *
 * Env: KEY, CORE, TOKEN, TIMELOCK
 */
contract Handover is Script {
    function run() external {
        uint256 pk = vm.envUint("KEY");
        address coreAddr = vm.envAddress("CORE");
        address tokenAddr = vm.envAddress("TOKEN");
        address timelock = vm.envAddress("TIMELOCK");

        vm.startBroadcast(pk);
        PlanetCore(coreAddr).setOwner(timelock);
        PlanetToken(tokenAddr).setOwner(timelock);
        vm.stopBroadcast();

        address coreOwner = PlanetCore(coreAddr).owner();
        address tokenOwner = PlanetToken(tokenAddr).owner();

        console.log("core.owner  ->", coreOwner);
        console.log("token.owner ->", tokenOwner);
        if (coreOwner != timelock || tokenOwner != timelock) revert("handover did not take");
    }
}
