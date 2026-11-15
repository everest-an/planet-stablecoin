// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceFeed} from "./CollateralRegistry.sol";

/// @title SignedFeedAdapter — the cross-chain price feed for one collateral asset.
/// @dev The index runs on Arbitrum; the lending market may run on another chain. This adapter closes
///      the gap without a message bridge: the same 2-of-3 signer set signs a payload bound to
///      (this adapter, this chain id, this asset id, price, quality, timestamp), and anyone submits it.
///      A signature for Arbitrum cannot be replayed here because the chain id is in the digest.
///
///      Safety rule: if the last update is older than MAX_AGE, price() reports quality 2 (frozen).
///      The registry maps that to a zero LTV, so a dead feed can never back a new loan.
contract SignedFeedAdapter is IPriceFeed {
    struct Payload {
        uint256 assetId;
        uint256 price1e18;
        uint8 quality;
        uint64 timestamp;
    }

    bytes32 public constant DOMAIN = keccak256("PLANET_FEED_V1");
    uint256 private constant SECP256K1N_HALF =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    address public owner;
    uint256 public immutable assetId;
    uint64 public maxAge = 6 hours;

    address[] public signers;
    uint8 public threshold;

    uint256 public price1e18;
    uint8 public storedQuality;
    uint64 public lastUpdate;

    event Submitted(uint256 price1e18, uint8 quality, uint64 timestamp);
    event SignersSet(uint256 count, uint8 threshold);
    event OwnerChanged(address indexed from, address indexed to);
    event MaxAgeSet(uint64 seconds_);

    error NotOwner();
    error BadInput();
    error BadSignature();
    error Stale();
    error WrongAsset();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, address[] memory signers_, uint8 threshold_, uint256 assetId_) {
        if (owner_ == address(0)) revert BadInput();
        owner = owner_;
        assetId = assetId_;
        _setSigners(signers_, threshold_);
    }

    // ---------------------------------------------------------------- admin

    function setOwner(address next) external onlyOwner {
        if (next == address(0)) revert BadInput();
        emit OwnerChanged(owner, next);
        owner = next;
    }

    function setSigners(address[] calldata signers_, uint8 threshold_) external onlyOwner {
        _setSigners(signers_, threshold_);
    }

    function setMaxAge(uint64 seconds_) external onlyOwner {
        if (seconds_ < 5 minutes || seconds_ > 7 days) revert BadInput();
        maxAge = seconds_;
        emit MaxAgeSet(seconds_);
    }

    function _setSigners(address[] memory signers_, uint8 threshold_) internal {
        if (threshold_ == 0 || threshold_ > signers_.length) revert BadInput();
        for (uint256 i; i < signers_.length; ++i) {
            if (signers_[i] == address(0)) revert BadInput();
            for (uint256 j; j < i; ++j) if (signers_[j] == signers_[i]) revert BadInput();
        }
        delete signers;
        for (uint256 i; i < signers_.length; ++i) signers.push(signers_[i]);
        threshold = threshold_;
        emit SignersSet(signers_.length, threshold_);
    }

    // ---------------------------------------------------------------- feed

    function digest(Payload calldata p) public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN, address(this), block.chainid, p.assetId, p.price1e18, p.quality, p.timestamp)
        );
    }

    /// @notice Submit a signed price. Anyone may relay; the signers are the authorisation.
    function submit(Payload calldata p, bytes calldata sigs) external {
        if (p.assetId != assetId) revert WrongAsset();
        if (p.timestamp <= lastUpdate) revert Stale();
        if (p.price1e18 == 0 || p.quality > 2) revert BadInput();
        if (!_verify(digest(p), sigs)) revert BadSignature();
        price1e18 = p.price1e18;
        storedQuality = p.quality;
        lastUpdate = p.timestamp;
        emit Submitted(p.price1e18, p.quality, p.timestamp);
    }

    /// @notice IPriceFeed: (price, quality). Stale data is reported as frozen, never as fresh.
    function price() external view returns (uint256, uint8) {
        if (lastUpdate == 0) return (0, 2);
        if (block.timestamp > uint256(lastUpdate) + uint256(maxAge)) return (price1e18, 2);
        return (price1e18, storedQuality);
    }

    function _verify(bytes32 d, bytes calldata sigs) internal view returns (bool) {
        uint256 n = sigs.length / 65;
        if (n < threshold) return false;
        uint256 used;
        uint256 matched;
        for (uint256 k; k < n; ++k) {
            (address rec, bool ok) = _recover(d, sigs, k * 65);
            if (!ok) continue;
            uint256 slot = _slot(rec);
            if (slot == type(uint256).max) continue;
            if ((used >> slot) & 1 == 1) continue;
            used |= (uint256(1) << slot);
            if (++matched >= threshold) return true;
        }
        return false;
    }

    function _recover(bytes32 d, bytes calldata sigs, uint256 offset) internal pure returns (address, bool) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(add(sigs.offset, offset))
            s := calldataload(add(add(sigs.offset, offset), 32))
            v := byte(0, calldataload(add(add(sigs.offset, offset), 64)))
        }
        if (v != 27 && v != 28) return (address(0), false);
        if (uint256(s) > SECP256K1N_HALF) return (address(0), false);
        address rec = ecrecover(d, v, r, s);
        if (rec == address(0)) return (address(0), false);
        return (rec, true);
    }

    function _slot(address who) internal view returns (uint256) {
        uint256 len = signers.length;
        for (uint256 i; i < len; ++i) if (signers[i] == who) return i;
        return type(uint256).max;
    }

    function signerCount() external view returns (uint256) {
        return signers.length;
    }
}
