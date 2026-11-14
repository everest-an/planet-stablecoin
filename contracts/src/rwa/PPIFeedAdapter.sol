// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceFeed} from "./CollateralRegistry.sol";

interface IPlanetCore {
    function currentPpi() external view returns (uint64);
    function lastOracleUpdate() external view returns (uint64);
    function assetCount() external view returns (uint256);
    function assets(uint256 i)
        external
        view
        returns (
            uint64 weight,
            uint64 basePrice,
            uint64 currentPrice,
            uint64 volatility,
            uint64 liquidity,
            uint8 riskState,
            uint64 lastUpdate
        );
}

/// @title PPIFeedAdapter — the PPI index as a collateral price feed.
/// @dev This is the bridge between the index and the lending market: the same number the index
///      publishes becomes the collateral price, and its data-quality verdict becomes the LTV signal.
///      0 normal / 1 caution / 2 frozen, exactly as the perp used.
contract PPIFeedAdapter is IPriceFeed {
    IPlanetCore public immutable core;
    /// @dev USD per 1.0 of PPI; PPI is 1e6-fixed near 1.0, so 1000 means "index 1.0 = $1000".
    uint256 public immutable usdPerIndex;

    uint64 public constant MAX_AGE = 6 hours;
    uint64 public constant CAUTION_AGE = 30 minutes;

    constructor(address core_, uint256 usdPerIndex_) {
        require(core_ != address(0) && usdPerIndex_ > 0, "bad args");
        core = IPlanetCore(core_);
        usdPerIndex = usdPerIndex_;
    }

    function price() external view returns (uint256, uint8) {
        uint64 ppi = core.currentPpi();
        require(ppi > 0, "no active asset");
        return (uint256(ppi) * usdPerIndex * 1e12, riskLevel());
    }

    function riskLevel() public view returns (uint8) {
        uint64 last = core.lastOracleUpdate();
        if (last == 0) return 2;
        if (last >= block.timestamp) return 0;
        uint64 age = uint64(block.timestamp) - last;
        if (age > MAX_AGE) return 2;
        uint8 worst = age > CAUTION_AGE ? uint8(1) : uint8(0);
        uint256 n = core.assetCount();
        for (uint256 i; i < n; ++i) {
            (,,,,, uint8 st,) = core.assets(i);
            if (st >= 2) return 2;
            if (st == 1) worst = 1;
        }
        return worst;
    }
}
