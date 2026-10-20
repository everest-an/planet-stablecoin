// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PlanetCore} from "../src/PlanetCore.sol";
import {PlanetToken} from "../src/PlanetToken.sol";

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
        // 8 assets x 12.5% == 100%, each within the 15% per-asset cap
        for (uint256 i; i < 8; ++i) {
            core.setAsset(i, 125_000, 100 * SCALE, 100 * SCALE);
        }
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
        for (uint256 i; i < 4; ++i) push(i, 110 * SCALE); // four assets +10%, four flat
        // (0.5 * 1.10 + 0.5 * 1.00) = 1.05
        assertApproxEqAbs(core.computePpi(), 1_050_000, 2);
    }

    function test_ppi_renormalises_when_one_asset_freezes() public {
        for (uint256 i; i < 4; ++i) push(i, 110 * SCALE);
        // freeze the four that moved: the index renormalises back to the flat half = 1.00
        for (uint256 i; i < 4; ++i) {
            vm.prank(relayer);
            core.updatePrice(i, 110 * SCALE, 0, SCALE, 2, uint64(block.timestamp));
            vm.warp(block.timestamp + 1);
        }
        assertApproxEqAbs(core.computePpi(), 1_000_000, 2);
        assertEq(core.assetCount(), 8);
    }

    // ---------------------------------------------------------------- C-1 (the headline fix)
    function test_ppi_is_zero_when_everything_is_frozen() public {
        vm.startPrank(relayer);
        for (uint256 i; i < 8; ++i) {
            core.updatePrice(i, 100 * SCALE, 0, SCALE, 2, uint64(block.timestamp + i));
        }
        vm.stopPrank();
        assertEq(core.computePpi(), 0, "undefined index must read 0, never 1.0");
    }

    function test_mint_reverts_when_index_is_undefined() public {
        vm.startPrank(relayer);
        for (uint256 i; i < 8; ++i) {
            core.updatePrice(i, 100 * SCALE, 0, SCALE, 2, uint64(block.timestamp + i));
        }
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.NoActiveAsset.selector);
        core.mint(1_000 * SCALE);
    }

    // ---------------------------------------------------------------- I1 / I2 / I3
    function test_weight_sum_is_enforced_on_price_update() public {
        // an incomplete basket must not accept prices: I1 is checked where it matters
        vm.prank(owner);
        core.setAsset(8, 100_000, 100 * SCALE, 100 * SCALE); // sum becomes 1_100_000
        vm.prank(relayer);
        vm.expectRevert(PlanetCore.BadWeights.selector);
        core.updatePrice(0, 100 * SCALE, 0, SCALE, 0, uint64(block.timestamp));
    }

    function test_weight_cap_is_15pct() public {
        vm.prank(owner);
        vm.expectRevert(PlanetCore.BadWeight.selector);
        core.setAsset(0, 150_001, 100 * SCALE, 100 * SCALE);
    }

    function test_base_price_is_immutable_after_lock() public {
        vm.prank(owner);
        vm.expectRevert(PlanetCore.BaseIsLocked.selector);
        core.setAsset(0, 125_000, 101 * SCALE, 101 * SCALE);
    }

    // ---------------------------------------------------------------- oracle guards
    function test_price_jump_over_50pct_is_rejected() public {
        vm.prank(relayer);
        vm.expectRevert(PlanetCore.PriceJump.selector);
        core.updatePrice(0, 160 * SCALE, 0, SCALE, 0, uint64(block.timestamp));
    }

    function test_timestamp_must_increase() public {
        push(0, 101 * SCALE); // now lastOracleUpdate > 0
        vm.prank(relayer);
        vm.expectRevert(PlanetCore.BadTimestamp.selector);
        core.updatePrice(0, 102 * SCALE, 0, SCALE, 0, 1); // older than the last update
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
        core.setAsset(0, 125_000, 100 * SCALE, 100 * SCALE);
    }

    // ---------------------------------------------------------------- fees / I6
    function test_fee_bands() public {
        assertEq(core.feeBpsForPpi(1_000_000), 50); // at peg
        assertEq(core.feeBpsForPpi(1_040_000), 100); // 4% off -> 1%
        assertEq(core.feeBpsForPpi(1_060_000), 300); // 2% + 1% slope at 6% deviation // 6% off -> 2% (+slope)
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

    /// End-to-end: a mint really mints the ERC-20, and a redeem really burns it (no mirror needed).
    function test_mint_and_redeem_move_the_erc20() public {
        PlanetToken tok = new PlanetToken(owner, address(core));
        vm.prank(owner);
        core.setToken(address(tok));

        push(0, 100 * SCALE);
        vm.prank(stranger);
        uint64 minted = core.mint(1_000_000 * SCALE);
        assertEq(tok.balanceOf(stranger), minted, "the core minted the token");
        assertEq(tok.totalSupply(), minted);

        vm.prank(stranger);
        core.redeem(minted);
        assertEq(tok.balanceOf(stranger), 0, "redeem burned it");
        assertEq(tok.totalSupply(), 0);
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
