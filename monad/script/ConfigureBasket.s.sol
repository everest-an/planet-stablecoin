// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PlanetCore} from "../src/PlanetCore.sol";

/**
 * Configures the 14-asset basket on an already-deployed PlanetCore and locks the base prices.
 *
 * Weights are the ppm values from relayer/assets.example.json: they sum to exactly 1_000_000 and no
 * single weight exceeds the contract's 15% per-asset cap. Base prices are the same reference prices
 * used on the TON deployment, in 1e6 fixed point.
 *
 * Run AFTER Deploy.s.sol. Re-running is safe for the basket (values are idempotent) but lockBasePrices
 * is one-way, so base prices can never be changed afterwards — that is the point.
 */
contract ConfigureBasket is Script {
    function run() external {
        uint256 pk = vm.envUint("KEY");
        address coreAddr = vm.envOr("CORE", address(0xcAdE768f59921e6eE09E57DE4cf974ffb3a5080D));
        PlanetCore core = PlanetCore(coreAddr);

        uint64[14] memory w = [
            uint64(140000), // WTI Crude
            110000, // Brent
            80000, // Natural Gas
            120000, // Gold
            70000, // Silver
            60000, // Copper
            90000, // Wheat
            70000, // Corn
            60000, // Soybean
            40000, // Coffee
            40000, // Lumber
            30000, // Lithium
            50000, // Water
            40000 // Carbon
        ];

        uint64[14] memory base = [
            uint64(88_180_000), // 88.18
            98_440_000, // 98.44
            3_100_000, // 3.10
            4_191_100_000, // 4191.10
            61_575_000, // 61.575
            6_641_000, // 6.641
            694_000_000, // 694.00
            501_750_000, // 501.75
            1_292_500_000, // 1292.50
            305_100_000, // 305.10
            66_280_000, // 66.28
            71_180_000, // 71.18
            69_475_000, // 69.475
            33_680_000 // 33.68
        ];

        console.log("core:", coreAddr);
        console.log("assets already configured:", core.assetCount());

        vm.startBroadcast(pk);
        for (uint256 i; i < 14; ++i) {
            core.setAsset(i, w[i], base[i], base[i]);
        }
        core.lockBasePrices();
        vm.stopBroadcast();

        console.log("assetCount:", core.assetCount());
        console.log("weightSum :", core.weightSum());
        console.log("baseLocked:", core.baseLocked());
        console.log("ppi       :", core.currentPpi());
    }
}
