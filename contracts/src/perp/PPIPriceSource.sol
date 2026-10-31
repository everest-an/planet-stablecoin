// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPerpPrice} from "./IPerpPrice.sol";

interface IPlanetCore {
    function currentPpi() external view returns (uint64);
    function lastOracleUpdate() external view returns (uint64);
    function assetCount() external view returns (uint256);
    function relayer() external view returns (address);
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
    uint64 public constant CAUTION_AGE = 30 minutes;

    constructor(address core_, uint256 usdPerIndex_) {
        require(core_ != address(0) && usdPerIndex_ > 0, "bad args");
        // The core has two write paths: updatePrice (one relayer key) and updatePriceSigned
        // (2-of-3). A perp that settles money must not read a price a single key can move, so a core
        // with an active relayer is rejected here. Disable the relayer before deploying this source.
        require(IPlanetCore(core_).relayer() == address(0), "core relayer must be disabled");
        core = IPlanetCore(core_);
        usdPerIndex = usdPerIndex_;
    }

    function _spot() internal view returns (uint256) {
        uint64 ppi = core.currentPpi();
        return uint256(ppi) * usdPerIndex * 1e12; // 1e6 * USD -> 1e18
    }

    function price() external view returns (uint256) {
        return _spot();
    }

    // --- TWAP: a single signed print must not liquidate anyone ---
    // The trigger has to hold at both the instantaneous price and a recent average. snapshots are
    // taken by the keeper workflow on its schedule; a wick has to survive long enough to be
    // snapshotted (and then counts at most 1/8 of the ring) before it can bite a liquidation.
    uint256[8] private _obsP;
    uint256[8] private _obsT;
    uint8 private _head;
    uint8 private _count;
    /// @dev Without a rate limit, one bad print followed by 8 rapid snapshots would fill the ring
    ///      with the wick and wash the TWAP gate out. One snapshot per 30 minutes means a wick
    ///      needs ~4 hours to dominate the ring - and only if it is still the on-chain price.
    uint256 private _lastSnap;
    uint256 public constant SNAPSHOT_MIN_INTERVAL = 30 minutes;

    function snapshot() external {
        if (block.timestamp - _lastSnap < SNAPSHOT_MIN_INTERVAL) return;
        _lastSnap = block.timestamp;
        _obsP[_head] = _spot();
        _obsT[_head] = block.timestamp;
        _head = uint8((_head + 1) % 8);
        if (_count < 8) _count++;
    }

    function twap() public view returns (uint256) {
        if (_count == 0) return _spot();
        uint256 total;
        uint256 wsum;
        for (uint8 i = 0; i < _count; ++i) {
            uint8 idx = uint8((_head + 8 - 1 - i) % 8);
            uint256 w = block.timestamp - _obsT[idx] + 60; // +60 guards zero weight on same-block snaps
            total += _obsP[idx] * w;
            wsum += w;
        }
        return total / wsum;
    }

    /// @dev trader-favorable side of {spot, twap} — see IPerpPrice.
    function triggerPrice(bool isLong) external view returns (uint256) {
        uint256 spot = _spot();
        uint256 t = twap();
        if (isLong) return spot > t ? spot : t;
        return spot < t ? spot : t;
    }

    function riskLevel() public view returns (uint8) {
        uint64 last = core.lastOracleUpdate();
        if (last == 0) return 2;
        // The signer publishes timestamps slightly ahead of the chain clock (now + 120). A plain
        // subtraction would underflow and revert for those two minutes, bricking open() and
        // liquidate() right after every push. Treat a future timestamp as age zero.
        if (last >= block.timestamp) return 0;
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
