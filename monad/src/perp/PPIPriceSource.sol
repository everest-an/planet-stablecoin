// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPerpPrice} from "./IPerpPrice.sol";

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

/// @notice Reads the PPI index as a perp price and derives a data-quality level from it.
/// @dev    riskLevel is the only reason this product differs from a generic perp: a venue that
///         prices data quality can tighten margin BEFORE a bad print is liquidated through.
///         0 = fresh and every asset normal; 1 = stale-but-usable or any asset in caution;
///         2 = past the core's 6h gate or any asset frozen (close-only).
contract PPIPriceSource is IPerpPrice {
    IPlanetCore public immutable core;
    /// @dev USD per 1.0 of PPI. PPI is a 1e6-fixed index near 1.0, so 1000 means "index 1.0 = $1000".
    uint256 public immutable usdPerIndex;

    uint64 public constant MAX_ORACLE_AGE = 6 hours;
    uint64 public constant CAUTION_AGE = 2 hours;

    constructor(address core_, uint256 usdPerIndex_) {
        require(core_ != address(0) && usdPerIndex_ > 0, "bad args");
        core = IPlanetCore(core_);
        usdPerIndex = usdPerIndex_;
    }

    function price() external view returns (uint256) {
        uint64 ppi = core.currentPpi();
        return uint256(ppi) * usdPerIndex * 1e12; // 1e6 * USD -> 1e18
    }

    function riskLevel() public view returns (uint8) {
        uint64 last = core.lastOracleUpdate();
        if (last == 0) return 2;
        uint64 age = uint64(block.timestamp) - last;
        if (age > MAX_ORACLE_AGE) return 2;

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
