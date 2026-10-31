// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * PlanetTimelockV2 — the self-owned variant (audit finding F1).
 *
 * Difference from V1: execute() is PUBLIC. Anyone can execute a due proposal. That is safe because
 * state is cleared before the external call, and the proposal body was fixed by the owner when they
 * proposed it - the executor only chooses timing, never content. Making execute public is what
 * allows the timelock to own ITSELF: once ownership is transferred to address(this), every change
 * (propose, setDelay, setGracePeriod, setOwner) must pass through propose -> delay -> execute.
 * The reaction window becomes real: even the key holder must wait out the delay they set.
 *
 * Everything else is unchanged from V1 (TL-1..TL-3 preserved).
 */
contract PlanetTimelockV2 {
    address public owner;
    uint64 public delay;
    uint64 public gracePeriod = 3 days;

    bool public hasPending;
    address public dest;
    bytes public body;
    uint64 public eta;

    bool public lastBounced;
    uint64 public lastBounceAt;

    event Proposed(address indexed dest, bytes body, uint64 eta);
    event Executed(address indexed dest, uint64 at);
    event Bounced(address indexed dest, uint64 at);
    event Cancelled();
    event DelaySet(uint64 delay);
    event OwnerChanged(address indexed from, address indexed to);

    error NotOwner();
    error NotSelf();
    error AlreadyPending();
    error NoPending();
    error TooEarly();
    error DelayTooSmall();
    error BadDelay();
    error TooLate();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, uint64 delay_) {
        if (owner_ == address(0)) revert NotOwner();
        owner = owner_;
        delay = delay_;
    }

    function propose(address dest_, bytes calldata body_) external onlyOwner {
        if (hasPending) revert AlreadyPending();
        if (dest_ == address(0)) revert BadDelay();
        hasPending = true;
        dest = dest_;
        body = body_;
        eta = uint64(block.timestamp) + delay;
        emit Proposed(dest_, body_, eta);
    }

    /// @dev PUBLIC in V2: the executor picks only timing, never content. State clears first.
    function execute() external returns (bool ok) {
        if (!hasPending) revert NoPending();
        if (block.timestamp < eta) revert TooEarly();
        if (block.timestamp > uint256(eta) + uint256(gracePeriod)) revert TooLate();

        address dest_ = dest;
        bytes memory body_ = body;

        hasPending = false;
        dest = address(0);
        body = "";
        eta = 0;

        (ok,) = dest_.call(body_);
        if (ok) {
            emit Executed(dest_, uint64(block.timestamp));
        } else {
            lastBounced = true;
            lastBounceAt = uint64(block.timestamp);
            emit Bounced(dest_, uint64(block.timestamp));
        }
    }

    function cancel() external onlyOwner {
        if (!hasPending) revert NoPending();
        hasPending = false;
        dest = address(0);
        body = "";
        eta = 0;
        emit Cancelled();
    }

    function setDelay(uint64 next) external onlyOwner {
        if (delay > 0 && next == 0) revert BadDelay();
        delay = next;
        emit DelaySet(next);
    }

    function setGracePeriod(uint64 next) external onlyOwner {
        gracePeriod = next;
    }

    function setOwner(address next) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (next == address(0)) revert NotOwner();
        emit OwnerChanged(owner, next);
        owner = next;
    }

    function lastExecutionFailed() external view returns (bool) {
        return lastBounced;
    }
}
