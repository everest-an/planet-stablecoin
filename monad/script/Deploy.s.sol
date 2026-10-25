// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PlanetCore} from "../src/PlanetCore.sol";
import {PlanetToken} from "../src/PlanetToken.sol";
import {PlanetTimelock} from "../src/PlanetTimelock.sol";
import {SignedPriceOracle} from "../src/SignedPriceOracle.sol";

/**
 * Deploys the minimum on-chain stack and wires it.
 *
 * Why a script and not `forge create`: constructor arguments passed through the CLI were being
 * re-split by the shell (the timelock kept receiving three values for two parameters). Passing them
 * from Solidity removes that class of failure entirely.
 *
 * Wiring order matters:
 *  1. Timelock(owner, delay)
 *  2. Token(owner, minter = deployer placeholder)   <- minter is repointed at the Core below
 *  3. Core(owner, relayer = deployer placeholder)
 *  4. token.setMinter(core)      so only the Core can mint/burn
 *  5. core.setToken(token)       so mint()/redeem() actually move the token
 *
 * Env:
 *   PRIVATE_KEY  required (the broadcast key; injected from the secret, never logged)
 *   OWNER        optional, defaults to the deployer address
 *   DELAY        optional, seconds; defaults to 60
 *   SIGNER_A/B/C optional signer addresses. If SIGNER_A is set, a SignedPriceOracle is deployed and
 *                wired into the core so updatePriceSigned works. THRESHOLD defaults to 1, which is
 *                correct while one operator holds every key — raise it with setSigners once the keys
 *                live with different people. No redeploy needed for that.
 */
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);
        uint64 delay = uint64(vm.envOr("DELAY", uint256(60)));

        console.log("deployer:", deployer);
        console.log("owner   :", owner);
        console.log("delay   :", delay);

        vm.startBroadcast(pk);

        PlanetTimelock timelock = new PlanetTimelock(owner, delay);
        PlanetToken token = new PlanetToken(owner, deployer);
        PlanetCore core = new PlanetCore(owner, deployer);

        token.setMinter(address(core));
        core.setToken(address(token));

        address signerA = vm.envOr("SIGNER_A", address(0));
        address oracleAddr = address(0);
        if (signerA != address(0)) {
            address[] memory set = _signerSet(vm.envOr("SIGNER_B", address(0)), vm.envOr("SIGNER_C", address(0)));
            set[0] = signerA;
            uint8 threshold = uint8(vm.envOr("THRESHOLD", uint256(1)));
            SignedPriceOracle oracle = new SignedPriceOracle(owner, set, threshold);
            core.setOracle(address(oracle));
            oracleAddr = address(oracle);
        }

        vm.stopBroadcast();

        console.log("PlanetTimelock:", address(timelock));
        console.log("PlanetToken   :", address(token));
        console.log("PlanetCore    :", address(core));
        if (oracleAddr != address(0)) console.log("PriceOracle   :", oracleAddr);
        console.log("assetCount    :", core.assetCount());
        console.log("ppi           :", core.currentPpi());
    }

    function _signerSet(address b, address c) private pure returns (address[] memory set) {
        uint256 n = 1 + (b == address(0) ? 0 : 1) + (c == address(0) ? 0 : 1);
        set = new address[](n);
        set[0] = address(1); // placeholder, overwritten by the caller
        uint256 k = 1;
        if (b != address(0)) set[k++] = b;
        if (c != address(0)) set[k] = c;
    }
}
