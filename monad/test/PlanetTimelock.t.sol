// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PlanetTimelock} from "../src/PlanetTimelock.sol";

/// A tiny target so the timelock has something to call.
contract Target {
    uint256 public value;
    bool public shouldFail;

    function setValue(uint256 v) external {
        if (shouldFail) revert("nope");
        value = v;
    }

    function setFail(bool f) external {
        shouldFail = f;
    }
}

contract PlanetTimelockTest is Test {
    PlanetTimelock tl;
    Target target;
    address owner = address(0xA11CE);
    address other = address(0xBEEF);

    function setUp() public {
        vm.prank(owner);
        tl = new PlanetTimelock(owner, 60);
        target = new Target();
    }

    function test_propose_then_execute_after_delay() public {
        bytes memory body = abi.encodeCall(Target.setValue, (42));
        vm.prank(owner);
        tl.propose(address(target), body);
        assertTrue(tl.hasPending());

        vm.prank(owner);
        vm.expectRevert(PlanetTimelock.TooEarly.selector);
        tl.execute();

        vm.warp(block.timestamp + 61);
        vm.prank(owner);
        assertTrue(tl.execute());
        assertEq(target.value(), 42);
        assertFalse(tl.hasPending());
    }

    /// TL-1: a direct owner call cannot change ownership — only the timelock itself can.
    function test_owner_cannot_change_ownership_directly() public {
        vm.prank(owner);
        vm.expectRevert(PlanetTimelock.NotSelf.selector);
        tl.setOwner(other);
        assertEq(tl.owner(), owner);
    }

    /// TL-1 (positive path): propose setOwner against the timelock itself, wait, execute.
    function test_ownership_changes_only_through_propose_execute() public {
        bytes memory body = abi.encodeCall(PlanetTimelock.setOwner, (other));
        vm.prank(owner);
        tl.propose(address(tl), body);
        vm.warp(block.timestamp + 61);
        vm.prank(owner);
        assertTrue(tl.execute());
        assertEq(tl.owner(), other);
    }

    /// TL-2: a failed inner call is recorded, not swallowed.
    function test_failed_inner_call_is_recorded() public {
        target.setFail(true);
        bytes memory body = abi.encodeCall(Target.setValue, (7));
        vm.prank(owner);
        tl.propose(address(target), body);
        vm.warp(block.timestamp + 61);
        vm.prank(owner);
        assertFalse(tl.execute()); // the call failed
        assertTrue(tl.lastBounced());
        assertGt(tl.lastBounceAt(), 0);
        assertFalse(tl.hasPending()); // and it is cleared, so a retry needs a new proposal
    }

    /// TL-3: the delay can be raised but never lowered back to zero.
    function test_delay_can_be_raised_but_never_reset_to_zero() public {
        vm.prank(owner);
        tl.setDelay(3600);
        assertEq(tl.delay(), 3600);
        vm.prank(owner);
        vm.expectRevert(PlanetTimelock.BadDelay.selector);
        tl.setDelay(0);
    }

    function test_only_owner_can_propose() public {
        vm.prank(other);
        vm.expectRevert(PlanetTimelock.NotOwner.selector);
        tl.propose(address(target), abi.encodeCall(Target.setValue, (1)));
    }

    function test_second_propose_while_pending_is_rejected() public {
        vm.startPrank(owner);
        tl.propose(address(target), abi.encodeCall(Target.setValue, (1)));
        vm.expectRevert(PlanetTimelock.AlreadyPending.selector);
        tl.propose(address(target), abi.encodeCall(Target.setValue, (2)));
        vm.stopPrank();
    }

    function test_cancel_clears_the_pending_action() public {
        vm.startPrank(owner);
        tl.propose(address(target), abi.encodeCall(Target.setValue, (1)));
        tl.cancel();
        assertFalse(tl.hasPending());
        vm.expectRevert(PlanetTimelock.NoPending.selector);
        tl.execute();
        vm.stopPrank();
    }
}
