// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PlanetBond} from "../src/PlanetBond.sol";

contract PlanetBondTest is Test {
    PlanetBond bond;
    address owner = address(0xA11CE);
    address alice = address(0xA1);
    address bob = address(0xB1);

    function setUp() public {
        bond = new PlanetBond(owner, 500); // 5%
        vm.prank(owner);
        bond.setOpen(true);
    }

    function test_subscribe_records_face_with_premium() public {
        vm.prank(alice);
        bond.subscribe(1_000_000);
        (uint64 principal, uint64 face,,) = bond.bondAt(alice);
        assertEq(principal, 1_000_000);
        assertEq(face, 1_050_000); // 5%
        assertEq(bond.totalIssued(), 1_050_000);
    }

    function test_subscribe_when_closed_reverts() public {
        vm.prank(owner);
        bond.setOpen(false);
        vm.prank(alice);
        vm.expectRevert(PlanetBond.SaleClosed.selector);
        bond.subscribe(1_000_000);
    }

    /// BD-2
    function test_premium_is_bounded() public {
        vm.prank(owner);
        vm.expectRevert(PlanetBond.BadPremium.selector);
        bond.setPremium(10_001);
    }

    /// BD-1: asking to redeem must NOT destroy the claim.
    function test_redeem_only_marks_a_request() public {
        vm.prank(alice);
        bond.subscribe(1_000_000);
        vm.prank(alice);
        bond.redeem();

        (, uint64 face, bool requested, bool redeemed) = bond.bondAt(alice);
        assertTrue(requested);
        assertFalse(redeemed, "asking must not settle the claim");
        assertEq(face, 1_050_000);
        assertEq(bond.totalIssued(), 1_050_000, "nothing released yet");
    }

    /// BD-1: only the operator settles. A holder cannot settle their own redemption.
    function test_holder_cannot_settle_their_own_redemption() public {
        vm.startPrank(alice);
        bond.subscribe(1_000_000);
        bond.redeem();
        vm.expectRevert(PlanetBond.NotOwner.selector);
        bond.settleRedeem(alice);
        vm.stopPrank();
    }

    function test_operator_settlement_releases_the_claim() public {
        vm.prank(alice);
        bond.subscribe(1_000_000);
        vm.prank(alice);
        bond.redeem();

        vm.prank(owner);
        bond.settleRedeem(alice);

        (,,, bool redeemed) = bond.bondAt(alice);
        assertTrue(redeemed);
        assertEq(bond.totalIssued(), 0);
    }

    function test_double_settlement_is_rejected() public {
        vm.prank(alice);
        bond.subscribe(1_000_000);
        vm.prank(owner);
        bond.settleRedeem(alice);
        vm.prank(owner);
        vm.expectRevert(PlanetBond.AlreadyRedeemed.selector);
        bond.settleRedeem(alice);
    }

    function test_redeem_with_no_bond_reverts() public {
        vm.prank(bob);
        vm.expectRevert(PlanetBond.NoBond.selector);
        bond.redeem();
    }

    function test_asking_twice_is_harmless() public {
        vm.startPrank(alice);
        bond.subscribe(1_000_000);
        bond.redeem();
        bond.redeem(); // idempotent
        vm.stopPrank();
        (, uint64 face,,) = bond.bondAt(alice);
        assertEq(face, 1_050_000);
    }

    function test_only_owner_can_open_the_sale() public {
        vm.prank(alice);
        vm.expectRevert(PlanetBond.NotOwner.selector);
        bond.setOpen(false);
    }
}
