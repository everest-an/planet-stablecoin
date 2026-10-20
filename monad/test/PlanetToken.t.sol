// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PlanetToken} from "../src/PlanetToken.sol";

contract PlanetTokenTest is Test {
    PlanetToken token;
    address owner = address(0xA11CE);
    address core = address(0xC0DE); // stands in for PlanetCore
    address alice = address(0xA1);
    address bob = address(0xB1);

    function setUp() public {
        token = new PlanetToken(owner, core);
    }

    function test_metadata() public view {
        assertEq(token.name(), "Planet");
        assertEq(token.symbol(), "PLT");
        assertEq(token.decimals(), 6);
        assertEq(token.totalSupply(), 0);
    }

    function test_only_minter_can_mint() public {
        vm.prank(alice);
        vm.expectRevert(PlanetToken.NotMinter.selector);
        token.mint(alice, 1e6);

        vm.prank(core);
        token.mint(alice, 1e6);
        assertEq(token.totalSupply(), 1e6);
        assertEq(token.balanceOf(alice), 1e6);
    }

    function test_burn_reduces_supply_and_balance() public {
        vm.startPrank(core);
        token.mint(alice, 10e6);
        token.burn(alice, 4e6);
        vm.stopPrank();
        assertEq(token.totalSupply(), 6e6);
        assertEq(token.balanceOf(alice), 6e6);
    }

    function test_burn_more_than_balance_reverts() public {
        vm.startPrank(core);
        token.mint(alice, 1e6);
        vm.expectRevert(PlanetToken.InsufficientBalance.selector);
        token.burn(alice, 2e6);
        vm.stopPrank();
    }

    function test_transfer_moves_balance() public {
        vm.prank(core);
        token.mint(alice, 5e6);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 2e6));
        assertEq(token.balanceOf(alice), 3e6);
        assertEq(token.balanceOf(bob), 2e6);
    }

    function test_transfer_beyond_balance_reverts() public {
        vm.prank(core);
        token.mint(alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(PlanetToken.InsufficientBalance.selector);
        token.transfer(bob, 2e6);
    }

    function test_approve_and_transfer_from() public {
        vm.prank(core);
        token.mint(alice, 10e6);
        vm.prank(alice);
        token.approve(bob, 4e6);
        assertEq(token.allowance(alice, bob), 4e6);

        vm.prank(bob);
        token.transferFrom(alice, bob, 3e6);
        assertEq(token.balanceOf(bob), 3e6);
        assertEq(token.allowance(alice, bob), 1e6); // 4e6 - 3e6
    }

    function test_transfer_from_over_allowance_reverts() public {
        vm.prank(core);
        token.mint(alice, 10e6);
        vm.prank(alice);
        token.approve(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(PlanetToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 2e6);
    }

    function test_zero_address_rejected() public {
        vm.prank(core);
        vm.expectRevert(PlanetToken.ZeroAddress.selector);
        token.mint(address(0), 1e6);
    }

    function test_owner_can_change_minter() public {
        address next = address(0xD00D);
        vm.prank(owner);
        token.setMinter(next);
        assertEq(token.minter(), next);

        vm.prank(core); // the old minter is now powerless
        vm.expectRevert(PlanetToken.NotMinter.selector);
        token.mint(alice, 1e6);
    }

    function test_only_owner_can_change_minter() public {
        vm.prank(alice);
        vm.expectRevert(PlanetToken.NotOwner.selector);
        token.setMinter(alice);
    }
}
