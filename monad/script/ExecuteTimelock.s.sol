// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PlanetTimelock} from "../src/PlanetTimelock.sol";

/**
 * Executes the single pending timelock proposal, after its delay. Reverts if the proposal is too
 * early or past its grace window, and reverts if the inner call fails — a silent bounce would mean
 * the limits were never applied.
 *
 * Env: KEY, TIMELOCK
 */
contract ExecuteTimelock is Script {
    function run() external {
        uint256 pk = vm.envUint("KEY");
        address tl = vm.envAddress("TIMELOCK");

        vm.startBroadcast(pk);
        bool ok = PlanetTimelock(tl).execute();
        vm.stopBroadcast();

        console.log("executed, inner call ok:", ok);
        require(ok, "inner call failed - the proposal bounced");
    }
}
