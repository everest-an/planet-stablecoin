// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * PlanetTimelock (Monad / EVM port) — step 2.
 *
 * The governance spine: every privileged action on the core must be proposed, wait out `delay`,
 * then execute. Ported from the TON version together with the three fixes the contract review
 * produced, so the EVM side does not have to rediscover them:
 *
 *   TL-1  setOwner() may ONLY be called by the timelock itself (i.e. through propose → delay →
 *         execute). A direct owner call is rejected, so a stolen owner key cannot hand over
 *         ownership without the delay window.
 *   TL-2  a failed inner call is RECORDED (lastBounced / lastBounceAt) instead of failing
 *         silently. The TON fix used a bouncing message; on EVM the equivalent is to check the
 *         call result and store it.
 *   TL-3  the delay can never be lowered back to 0 once it is non-zero (0 -> N is allowed so
 *         that demo/test timelocks can start at 0). Otherwise the owner could silently disarm
 *         the reaction window right before proposing something.
 *
 * EVM-specific discipline: state is cleared BEFORE the external call (checks-effects-
 * interactions). The TON version's "state before send" rule becomes this on the EVM, and the
 * reentrancy tests below exist because of it.
 *
 * Not audited. Testnet only.
 */
contract PlanetTimelock {
    address public owner;
    uint64 public delay;
    /// @notice How long after eta a proposal may still be executed. Without this a proposal
    ///         could sit for a year and be executed when nobody is watching.
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
        delay = delay_; // 0 is allowed at deployment (0 -> N later)
    }

    /// @notice Queue one call. Only one pending action at a time, by design.
    function propose(address dest_, bytes calldata body_) external onlyOwner {
        if (hasPending) revert AlreadyPending();
        if (dest_ == address(0)) revert BadDelay();
        hasPending = true;
        dest = dest_;
        body = body_;
        eta = uint64(block.timestamp) + delay;
        emit Proposed(dest_, body_, eta);
    }

    /// @notice Execute after the delay. Clears state BEFORE calling out (no reentrancy surface).
    function execute() external onlyOwner returns (bool ok) {
        if (!hasPending) revert NoPending();
        if (block.timestamp < eta) revert TooEarly();
        if (block.timestamp > uint256(eta) + uint256(gracePeriod)) revert TooLate();

        address dest_ = dest;
        bytes memory body_ = body;

        // effects first
        hasPending = false;
        dest = address(0);
        body = "";
        eta = 0;

        // then the interaction
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

    /// @notice TL-3: N -> 0 is rejected. 0 -> N is allowed.
    function setDelay(uint64 next) external onlyOwner {
        if (delay > 0 && next == 0) revert BadDelay();
        delay = next;
        emit DelaySet(next);
    }

    function setGracePeriod(uint64 next) external onlyOwner {
        gracePeriod = next;
    }

    /// @notice TL-1: ownership can only change through the timelock itself.
    ///         A direct owner call lands here with msg.sender == owner, and is rejected.
    function setOwner(address next) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (next == address(0)) revert NotOwner();
        emit OwnerChanged(owner, next);
        owner = next;
    }

    /// @notice Convenience for callers that need to know whether the last execution landed.
    function lastExecutionFailed() external view returns (bool) {
        return lastBounced;
    }
}
