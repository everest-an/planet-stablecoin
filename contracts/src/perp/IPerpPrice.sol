// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice What a perpetual market needs from its price source: a price and a data-quality level.
/// @dev    Splitting this out is what lets the market be tested with a settable price while the
///         production deployment reads the PPI index. Without this seam the PnL path can only be
///         tested by waiting for a real market move.
interface IPerpPrice {
    /// @return price USD per unit of underlying, 1e18 fixed point
    function price() external view returns (uint256);

    /// @return level 0 = normal, 1 = caution, 2 = frozen (no new risk)
    function riskLevel() external view returns (uint8);

    /// @return the recent average price (snapshot ring buffer); falls back to spot when empty
    function twap() external view returns (uint256);

    /// @return the trader-favorable side of {spot, twap}: a forced liquidation must be justified
    /// even at this price. longs: max(spot, twap); shorts: min(spot, twap).
    function triggerPrice(bool isLong) external view returns (uint256);
}
