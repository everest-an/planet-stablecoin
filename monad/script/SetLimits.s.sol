// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PlanetCore} from "../src/PlanetCore.sol";
import {PlanetTimelock} from "../src/PlanetTimelock.sol";

/**
 * Proposes new limits on the core THROUGH the timelock. This is the first real administrative action
 * on the live deployment, and the point of doing it this way is to exercise the governance path we
 * built: propose -> wait delay -> execute, with the owner key unable to act directly.
 *
 * Why cap at all: a reserve that pays index returns out of a dollar balance is a subsidy, and a
 * subsidy without a ceiling is an open-ended liability. The cap is small on purpose and is raised by
 * governance as the reserve grows.
 *
 * Env: KEY, CORE, TIMELOCK, MINT_CAP, MAX_MINT_PER_TX, FROZEN_WEIGHT_CAP
 */
contract SetLimits is Script {
    function run() external {
        uint256 pk = vm.envUint("KEY");
        address coreAddr = vm.envAddress("CORE");
        address tl = vm.envAddress("TIMELOCK");

        uint64 cap = uint64(vm.envOr("MINT_CAP", uint256(100_000 * 1e6)));
        uint64 perTx = uint64(vm.envOr("MAX_MINT_PER_TX", uint256(10_000 * 1e6)));
        uint64 frozen = uint64(vm.envOr("FROZEN_WEIGHT_CAP", uint256(400_000)));

        bytes memory body = abi.encodeCall(PlanetCore.setLimits, (cap, perTx, frozen));

        vm.startBroadcast(pk);
        PlanetTimelock(tl).propose(coreAddr, body);
        vm.stopBroadcast();

        console.log("proposed setLimits on core:");
        console.log("  core         ", coreAddr);
        console.log("  mintCap      ", cap);
        console.log("  maxMintPerTx ", perTx);
        console.log("  frozenWeight ", frozen);
        console.log("eta            ", PlanetTimelock(tl).eta());
    }
}
