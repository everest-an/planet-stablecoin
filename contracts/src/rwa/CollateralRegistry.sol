// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice What the pool needs from a price source: a USD price (1e18 per unit of the token) and a
///         data-quality level (0 normal, 1 caution, 2 frozen). The quality is what makes this registry
///         different from a plain LTV table: a degraded feed lowers the borrow limit before it hurts anyone.
interface IPriceFeed {
    function price() external view returns (uint256 price1e18, uint8 quality);
}

/// @title CollateralRegistry — the whitelist and the per-asset risk parameters.
/// @dev Governance-owned (behind the timelock in production). The pool reads from here; nobody else
///      writes except the owner. Assets are only enabled explicitly, so a random ERC-20 cannot be pledged.
contract CollateralRegistry {
    struct Asset {
        bool enabled;
        IPriceFeed feed;
        uint16 ltvBps; // normal-state loan-to-value
        uint16 cautionLtvBps; // loan-to-value while the feed is in caution
        uint16 liqThresholdBps; // liquidation threshold, above ltv
    }

    address public owner;
    mapping(address => Asset) public assets;
    address[] public tokens;

    event OwnerChanged(address indexed from, address indexed to);
    event AssetSet(address indexed token, address feed, uint16 ltvBps, uint16 cautionLtvBps, uint16 liqThresholdBps);
    event AssetDisabled(address indexed token);

    error NotOwner();
    error BadAsset();
    error NotEnabled();
    error BadPrice();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert BadAsset();
        owner = owner_;
    }

    function setOwner(address next) external onlyOwner {
        if (next == address(0)) revert BadAsset();
        emit OwnerChanged(owner, next);
        owner = next;
    }

    /// @notice Add or update one collateral asset. LTV must stay below the liquidation threshold,
    ///         and both must stay under 100% so a position is never born liquidatable.
    function setAsset(address token, address feed, uint16 ltvBps, uint16 cautionLtvBps, uint16 liqThresholdBps)
        external
        onlyOwner
    {
        if (token == address(0) || feed == address(0)) revert BadAsset();
        if (ltvBps == 0 || ltvBps > 9_000) revert BadAsset();
        if (cautionLtvBps > ltvBps) revert BadAsset();
        if (liqThresholdBps <= ltvBps || liqThresholdBps > 9_500) revert BadAsset();
        if (!assets[token].enabled) tokens.push(token);
        assets[token] = Asset(true, IPriceFeed(feed), ltvBps, cautionLtvBps, liqThresholdBps);
        emit AssetSet(token, feed, ltvBps, cautionLtvBps, liqThresholdBps);
    }

    function disable(address token) external onlyOwner {
        assets[token].enabled = false;
        emit AssetDisabled(token);
    }

    /// @notice Value of `amount` of `token` in USD (1e18) plus the quality level of its feed.
    function valueOf(address token, uint256 amount) public view returns (uint256 value, uint8 quality) {
        Asset memory a = assets[token];
        if (!a.enabled) revert NotEnabled();
        (uint256 p, uint8 q) = a.feed.price();
        if (p == 0) revert BadPrice();
        value = (amount * p) / 1e18;
        quality = q;
    }

    /// @notice Effective LTV: normal → ltvBps, caution → cautionLtvBps, frozen → 0 (no new borrowing).
    function ltvOf(address token) public view returns (uint16 ltv, uint8 quality) {
        Asset memory a = assets[token];
        if (!a.enabled) revert NotEnabled();
        (uint256 p, uint8 q) = a.feed.price();
        if (p == 0) revert BadPrice();
        quality = q;
        if (q >= 2) return (0, q);
        ltv = q == 1 ? a.cautionLtvBps : a.ltvBps;
    }

    function liqThresholdOf(address token) external view returns (uint16) {
        return assets[token].liqThresholdBps;
    }

    function count() external view returns (uint256) {
        return tokens.length;
    }
}
