// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * SignedPriceOracle (Monad / EVM port) — the M-of-N replacement for the TON ed25519 signer set.
 *
 * DESIGN CHOICE: this contract is STATELESS. It verifies; it does not store. Replay protection
 * already lives where it belongs — the Core's strictly-increasing `lastOracleUpdate` — so giving
 * the oracle its own nonce would be a second source of truth and a second way to get it wrong.
 *
 * What it keeps from the TON version:
 *   - a signer SET with a threshold, and **distinct** signers enforced (a signer who signs twice
 *     counts once) — implemented with a used-signer bitmap, exactly like `handleSignedPriceUpdateN`.
 *   - **domain separation**: the digest binds a domain tag, this contract's address, the chain id
 *     and every field of the payload, so a signature cannot be replayed onto another deployment,
 *     another chain, or reinterpreted under a different message shape.
 *
 * EVM-specific hazards this handles explicitly:
 *   - `ecrecover` returns address(0) on a bad signature instead of reverting -> rejected.
 *   - ECDSA signature malleability (EIP-2): `s` above the curve half-order is rejected, otherwise
 *     one valid signature would have two valid encodings.
 *   - duplicate signatures from the same signer are counted once (bitmap), so M-of-N cannot be
 *     satisfied by one key signing M times.
 *
 * Not audited. Testnet only.
 */
contract SignedPriceOracle {
    struct PricePayload {
        uint256 index;
        uint64 price;
        uint64 volatility;
        uint64 liquidity;
        uint8 riskState;
        uint64 timestamp;
    }

    bytes32 public constant DOMAIN = keccak256("PLANET_PRICE_V1");

    // secp256k1n / 2 — signatures with s above this are malleable and rejected (EIP-2).
    uint256 private constant SECP256K1N_HALF =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    address public owner;
    /// @notice The core that will consume these payloads. Bound into the digest, so a signature
    ///         for one core cannot be replayed onto another that trusts the same oracle.
    address public consumer;
    address[] public signers;
    uint8 public threshold;

    event SignersSet(uint256 count, uint8 threshold);
    event ConsumerSet(address indexed consumer);

    error NotOwner();
    error BadThreshold();
    error DuplicateSigner();
    error ZeroSigner();
    error NotEnoughSignatures();
    error BadSignature();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, address[] memory signers_, uint8 threshold_) {
        if (owner_ == address(0)) revert NotOwner();
        owner = owner_;
        _setSigners(signers_, threshold_);
    }

    /// @notice Replace the whole signer set and the threshold. Owner action; wire it behind the
    ///         timelock in production (the TON version rotated signers through the timelock too).
    function setSigners(address[] calldata signers_, uint8 threshold_) external onlyOwner {
        _setSigners(signers_, threshold_);
    }

    function setConsumer(address next) external onlyOwner {
        consumer = next;
        emit ConsumerSet(next);
    }

    function _setSigners(address[] memory signers_, uint8 threshold_) internal {
        if (threshold_ == 0 || threshold_ > signers_.length) revert BadThreshold();
        for (uint256 i; i < signers_.length; ++i) {
            if (signers_[i] == address(0)) revert ZeroSigner();
            for (uint256 j; j < i; ++j) {
                if (signers_[j] == signers_[i]) revert DuplicateSigner();
            }
        }
        delete signers;
        for (uint256 i; i < signers_.length; ++i) {
            signers.push(signers_[i]);
        }
        threshold = threshold_;
        emit SignersSet(signers_.length, threshold_);
    }

    /// @notice The exact bytes every signer must sign.
    function digest(PricePayload calldata p) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN,
                address(this),
                block.chainid,
                consumer,
                p.index,
                p.price,
                p.volatility,
                p.liquidity,
                p.riskState,
                p.timestamp
            )
        );
    }

    /// @notice True iff at least `threshold` DISTINCT registered signers signed this payload.
    /// @dev    Stateless: callers pass `sigs` as 65-byte r||s||v concatenated.
    function verify(PricePayload calldata p, bytes calldata sigs) external view returns (bool) {
        uint256 n = sigs.length / 65;
        if (n < threshold) return false;

        bytes32 d = digest(p);
        uint256 usedMask;
        uint256 matched;

        for (uint256 k; k < n; ++k) {
            (address recovered, bool ok) = _recover(d, sigs, k * 65);
            if (!ok) continue;

            uint256 slot = _signerSlot(recovered);
            if (slot == type(uint256).max) continue; // not a registered signer
            if ((usedMask >> slot) & 1 == 1) continue; // already counted: one key, one vote

            usedMask |= (uint256(1) << slot);
            ++matched;
            if (matched >= threshold) return true;
        }
        return false;
    }

    /// @dev Reverts-style helper for consumers that prefer a hard failure.
    function requireVerified(PricePayload calldata p, bytes calldata sigs) external view {
        if (!this.verify(p, sigs)) revert NotEnoughSignatures();
    }

    function _recover(bytes32 d, bytes calldata sigs, uint256 offset)
        internal
        pure
        returns (address, bool)
    {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(add(sigs.offset, offset))
            s := calldataload(add(add(sigs.offset, offset), 32))
            v := byte(0, calldataload(add(add(sigs.offset, offset), 64)))
        }
        if (v != 27 && v != 28) return (address(0), false);
        if (uint256(s) > SECP256K1N_HALF) return (address(0), false); // EIP-2 malleability
        address rec = ecrecover(d, v, r, s);
        if (rec == address(0)) return (address(0), false); // ecrecover fails silently
        return (rec, true);
    }

    function _signerSlot(address who) internal view returns (uint256) {
        uint256 len = signers.length;
        for (uint256 i; i < len; ++i) {
            if (signers[i] == who) return i;
        }
        return type(uint256).max;
    }

    function signerCount() external view returns (uint256) {
        return signers.length;
    }
}
