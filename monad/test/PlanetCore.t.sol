// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PlanetCore} from "../src/PlanetCore.sol";

/// These tests mirror the TON suite's economics cases one-for-one, so the migration can be judged
/// on behaviour rather than on vibes. Each test name states the invariant it defends.
contract PlanetCoreTest is Test {
    PlanetCore core;
    address owner = address(0xA11CE);
    address relayer = address(0xB0B);
    address stranger = address(0xCAFE);

    uint64 constant SCALE = 1e6;

    function setUp() public {
        vm.prank(owner);
        core = new PlanetCore(owner, relayer);
        // A, B, C: weights 50/30/20, bases 100 / 50 / 80
        vm.startPrank(owner);
        core.setAsset(0, 500_000, 100 * SCALE, 100 * SCALE);
        core.setAsset(1, 300_000, 50 * SCALE, 50 * SCALE);
        core.setAsset(2, 200_000, 80 * SCALE, 80 * SCALE);
        core.lockBasePrices();
        vm.stopPrank();
    }

    function push(uint256 i, uint64 price) internal {
        vm.prank(relayer);
        core.updatePrice(i, price, 0, SCALE, 0, uint64(block.timestamp));
        vm.warp(block.timestamp + 1); // keep timestamps strictly increasing
    }

    // ---------------------------------------------------------------- I4
    function test_ppi_is_weighted_mean() public {
        push(0, 110 * SCALE); // +10%
        push(1, 47.5e6); //  -5%
        push(2, 84 * SCALE); // +5%
        // 0.5*1.10 + 0.3*0.95 + 0.2*1.05 = 1.045
        assertApproxEqAbs(core.computePpi(), 1_045_000, 2);
    }

    function test_ppi_renormalises_when_one_asset_freezes() public {
        push(0, 110 * SCALE);
        push(1, 47.5e6);
        push(2, 84 * SCALE);
        // freeze B -> renormalise over A and C only
        vm.prank(relayer);
        core.updatePrice(1, 47.5e6, 0, SCALE, 2, uint64(block.timestamp));
        // (0.5*1.10 + 0.2*1.05) / 0.7 = 1.0857...
        assertApproxEqAbs(core.computePpi(), 1_085_714, 3);
        assertEq(core.assetCount(), 3);
    }

    // ---------------------------------------------------------------- C-1 (the headline fix)
    function test_ppi_is_zero_when_everything_is_frozen() public {
        vm.startPrank(relayer);
        core.updatePrice(0, 100 * SCALE, 0, SCALE, 2, uint64(block.timestamp));
        core.updatePrice(1, 50 * SCALE, 0, SCALE, 2, uint64(block.timestamp) + 1);
        core.updatePrice(2, 80 * SCALE, 0, SCALE, 2, uint64(block.timestamp) + 2);
        vm.stopPrank();
        assertEq(core.computePpi(), 0, "undefined index must read 0, never 1.0");
    }

    function test_mint_reverts_when_index_is_undefined() public {
        vm.startPrank(relayer);
        core.updatePrice(0, 100 * SCALE, 0, SCALE, 2, uint64(block.timestamp));
        core.updatePrice(1, 50 * SCALE, 0, SCALE, 2, uint64(block.timestamp) + 1);
        core.updatePrice(2, 80 * SCALE, 0, SCALE, 2, uint64(block.timestamp) + 2);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.NoActiveAsset.selector);
        core.mint(1_000 * SCALE);
    }

    // ---------------------------------------------------------------- I1 / I2 / I3
    function test_weight_sum_must_be_exactly_100pct() public {
        vm.prank(owner);
        vm.expectRevert(PlanetCore.BadWeights.selector);
        core.setAsset(0, 400_000, 100 * SCALE, 100 * SCALE); // sum would be 90%
    }

    function test_weight_cap_is_15pct() public {
        vm.prank(owner);
        vm.expectRevert(PlanetCore.BadWeight.selector);
        core.setAsset(0, 150_001, 100 * SCALE, 100 * SCALE);
    }

    function test_base_price_is_immutable_after_lock() public {
        vm.prank(owner);
        vm.expectRevert(PlanetCore.BaseIsLocked.selector);
        core.setAsset(0, 500_000, 101 * SCALE, 101 * SCALE);
    }

    // ---------------------------------------------------------------- oracle guards
    function test_price_jump_over_50pct_is_rejected() public {
        vm.prank(relayer);
        vm.expectRevert(PlanetCore.PriceJump.selector);
        core.updatePrice(0, 160 * SCALE, 0, SCALE, 0, uint64(block.timestamp));
    }

    function test_timestamp_must_increase() public {
        push(0, 101 * SCALE);
        vm.prank(relayer);
        vm.expectRevert(PlanetCore.BadTimestamp.selector);
        core.updatePrice(0, 102 * SCALE, 0, SCALE, 0, uint64(block.timestamp) - 5);
    }

    function test_mint_requires_fresh_oracle() public {
        push(0, 100 * SCALE);
        vm.warp(block.timestamp + 7 hours); // past MAX_ORACLE_AGE
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.StaleOracle.selector);
        core.mint(1_000 * SCALE);
    }

    function test_only_relayer_can_push_prices() public {
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.NotRelayer.selector);
        core.updatePrice(0, 101 * SCALE, 0, SCALE, 0, uint64(block.timestamp));
    }

    function test_only_owner_can_change_basket() public {
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.NotOwner.selector);
        core.setAsset(0, 500_000, 100 * SCALE, 100 * SCALE);
    }

    // ---------------------------------------------------------------- fees / I6
    function test_fee_bands() public {
        assertEq(core.feeBpsForPpi(1_000_000), 50); // at peg
        assertEq(core.feeBpsForPpi(1_040_000), 100); // 4% off -> 1%
        assertEq(core.feeBpsForPpi(1_060_000), 200); // 6% off -> 2% (+slope)
        vm.expectRevert(PlanetCore.BandReject.selector);
        core.feeBpsForPpi(1_160_000); // >15% -> refuse
    }

    function test_mint_splits_fee_30_50_20_10() public {
        push(0, 100 * SCALE);
        uint64 deposit = 1_000_000 * SCALE; // 1M units
        vm.prank(stranger);
        uint64 minted = core.mint(deposit);

        uint64 fee = uint64(uint256(deposit) * 50 / 10_000); // 0.5%
        assertEq(core.feesToBurn(), fee * 30 / 100);
        assertEq(core.feesToStaking(), fee * 20 / 100);
        assertEq(core.riskFund(), fee * 10 / 100);
        assertEq(minted, uint64((uint256(deposit) - fee) * SCALE / 1_000_000));
        assertEq(core.totalSupply(), minted);
    }

    function test_redeem_cannot_underflow_supply() public {
        push(0, 100 * SCALE);
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.Underflow.selector);
        core.redeem(1); // nothing was ever minted
    }

    function test_paused_blocks_mint() public {
        push(0, 100 * SCALE);
        vm.prank(owner);
        core.setPaused(true);
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.IsPaused.selector);
        core.mint(1_000 * SCALE);
    }

    function test_cover_deficit_moves_risk_fund_into_reserve() public {
        push(0, 100 * SCALE);
        vm.prank(stranger);
        core.mint(1_000_000 * SCALE);
        uint64 rf = core.riskFund();
        assertGt(rf, 0);
        vm.prank(owner);
        core.coverDeficit(rf);
        assertEq(core.riskFund(), 0);
    }
}
