// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PlanetCore} from "../src/PlanetCore.sol";
import {PlanetToken} from "../src/PlanetToken.sol";
import {SignedPriceOracle} from "../src/SignedPriceOracle.sol";
import {MockERC20, ReentrantToken} from "./MockERC20.sol";

/// These tests mirror the TON suite's economics cases one-for-one, so the migration can be judged
/// on behaviour rather than on vibes. Each test name states the invariant it defends.
contract PlanetCoreTest is Test {
    PlanetCore core;
    MockERC20 usd;
    PlanetToken plt;
    address owner = address(0xA11CE);
    address relayer = address(0xB0B);
    address stranger = address(0xCAFE);

    uint64 constant SCALE = 1e6;

    function setUp() public {
        vm.startPrank(owner);
        core = new PlanetCore(owner, relayer);
        usd = new MockERC20();
        plt = new PlanetToken(owner, address(core));
        core.setToken(address(plt));
        core.setDepositToken(address(usd));
        // 8 assets x 12.5% == 100%, each within the 15% per-asset cap
        for (uint256 i; i < 8; ++i) {
            core.setAsset(i, 125_000, 100 * SCALE, 100 * SCALE);
        }
        core.lockBasePrices();
        vm.stopPrank();

        usd.mint(stranger, 10_000_000 * SCALE);
        vm.prank(stranger);
        usd.approve(address(core), type(uint256).max);
    }

    function push(uint256 i, uint64 price) internal {
        vm.prank(relayer);
        core.updatePrice(i, price, 0, SCALE, 0, uint64(block.timestamp));
        vm.warp(block.timestamp + 1); // keep timestamps strictly increasing
    }

    // mint() now gates on the STALEST asset, so an economics test has to have pushed the whole
    // basket — otherwise it is testing against an oracle that was never fully initialised.
    function pushAll(uint64 price) internal {
        for (uint256 i; i < 8; ++i) push(i, price);
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
        pushAll(100 * SCALE);
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

    function test_mint_splits_fee_30_40_20_10() public {
        pushAll(100 * SCALE);
        uint64 deposit = 1_000_000 * SCALE; // 1M units
        vm.prank(stranger);
        uint64 minted = core.mint(deposit);

        uint64 fee = uint64(uint256(deposit) * 50 / 10_000); // 0.5%
        assertEq(core.feesToBurn(), fee * 30 / 100);
        assertEq(core.feesToReserve(), fee * 40 / 100);
        assertEq(core.feesToStaking(), fee * 20 / 100);
        assertEq(core.riskFund(), fee * 10 / 100);
        assertEq(core.feesToBurn() + core.feesToReserve() + core.feesToStaking() + core.riskFund(), fee);
        assertEq(minted, uint64((uint256(deposit) - fee) * SCALE / 1_000_000));
        assertEq(core.totalSupply(), minted);
    }

    function test_redeem_cannot_underflow_supply() public {
        pushAll(100 * SCALE);
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.Underflow.selector);
        core.redeem(1); // nothing was ever minted
    }

    function test_paused_blocks_mint() public {
        pushAll(100 * SCALE);
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

        pushAll(100 * SCALE);
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
        pushAll(100 * SCALE);
        vm.prank(stranger);
        core.mint(1_000_000 * SCALE);
        uint64 rf = core.riskFund();
        assertGt(rf, 0);
        vm.prank(owner);
        core.coverDeficit(rf);
        assertEq(core.riskFund(), 0);
    }

    // ---------------------------------------------------------------- per-asset staleness
    /// The regression this exists for: one fresh asset used to make the whole index look current,
    /// so minting stayed open against thirteen inputs that were a week old.
    function test_one_fresh_asset_cannot_mask_the_rest() public {
        pushAll(100 * SCALE);
        vm.warp(block.timestamp + 7 hours);
        push(0, 101 * SCALE); // only ONE asset refreshed

        assertEq(core.lastOracleUpdate(), uint64(block.timestamp - 1), "the fresh push is recorded");
        assertGt(block.timestamp - core.oldestActiveUpdate(), 6 hours, "the oldest input is still stale");

        vm.prank(stranger);
        vm.expectRevert(PlanetCore.StaleOracle.selector);
        core.mint(1_000 * SCALE);
    }

    function test_mint_opens_once_every_active_asset_is_fresh() public {
        pushAll(100 * SCALE);
        vm.prank(stranger);
        core.mint(1_000 * SCALE);
    }

    // ---------------------------------------------------------------- jump-guard escape hatch
    function test_force_price_bypasses_the_jump_guard_and_flags_caution() public {
        pushAll(100 * SCALE);

        vm.prank(relayer);
        vm.expectRevert(PlanetCore.PriceJump.selector);
        core.updatePrice(0, 160 * SCALE, 0, SCALE, 0, uint64(block.timestamp));

        vm.prank(owner);
        core.forcePrice(0, 160 * SCALE, 0, SCALE, 0, uint64(block.timestamp));
        (uint64 cur, uint8 risk) = _priceAndRisk(0);
        assertEq(cur, 160 * SCALE);
        assertEq(risk, 1, "a forced price must not look normal");
    }

    function test_only_owner_can_force_a_price() public {
        pushAll(100 * SCALE);
        vm.prank(relayer);
        vm.expectRevert(PlanetCore.NotOwner.selector);
        core.forcePrice(0, 160 * SCALE, 0, SCALE, 0, uint64(block.timestamp));
    }

    // ---------------------------------------------------------------- freezing a dead feed
    /// Without an owner-side freeze, an asset whose feed dies blocks minting forever: its price
    /// cannot be pushed, so it drags oldestActiveUpdate past MAX_ORACLE_AGE with no way out.
    function test_owner_can_freeze_a_dead_feed_so_mint_resumes() public {
        pushAll(100 * SCALE);
        vm.warp(block.timestamp + 10 hours);

        vm.prank(stranger);
        vm.expectRevert(PlanetCore.StaleOracle.selector);
        core.mint(1_000 * SCALE);

        for (uint256 i = 1; i < 8; ++i) push(i, 100 * SCALE); // refresh the seven live feeds
        vm.prank(owner);
        core.setRiskState(0, 2); // asset 0's feed is dead: retire it

        vm.prank(stranger);
        core.mint(1_000 * SCALE);
    }

    function test_only_owner_can_set_risk_state() public {
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.NotOwner.selector);
        core.setRiskState(0, 2);
    }

    // ---------------------------------------------------------------- M-of-N signed path
    function test_signed_update_needs_the_threshold_and_distinct_signers() public {
        uint256 pk1 = 0xA11CE1;
        uint256 pk2 = 0xB0B2;
        uint256 pk3 = 0xCAFE3;
        address[] memory signers = new address[](3);
        signers[0] = vm.addr(pk1);
        signers[1] = vm.addr(pk2);
        signers[2] = vm.addr(pk3);

        SignedPriceOracle o = new SignedPriceOracle(owner, signers, 2);
        vm.prank(owner);
        core.setOracle(address(o));

        SignedPriceOracle.PricePayload memory p = SignedPriceOracle.PricePayload({
            index: 0,
            price: 101 * SCALE,
            volatility: 0,
            liquidity: SCALE,
            riskState: 0,
            timestamp: uint64(block.timestamp + 10)
        });
        bytes32 d = o.digest(p);

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pk1, d);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pk2, d);

        vm.expectRevert(PlanetCore.BadSignature.selector);
        core.updatePriceSigned(p, abi.encodePacked(r1, s1, v1));

        // the same key twice is one signer, not two
        vm.expectRevert(PlanetCore.BadSignature.selector);
        core.updatePriceSigned(p, abi.encodePacked(r1, s1, v1, r1, s1, v1));

        core.updatePriceSigned(p, abi.encodePacked(r1, s1, v1, r2, s2, v2));
        (uint64 cur, ) = _priceAndRisk(0);
        assertEq(cur, 101 * SCALE);
    }

    function test_signed_update_reverts_without_an_oracle() public {
        SignedPriceOracle.PricePayload memory p = SignedPriceOracle.PricePayload({
            index: 0,
            price: 101 * SCALE,
            volatility: 0,
            liquidity: SCALE,
            riskState: 0,
            timestamp: uint64(block.timestamp + 10)
        });
        vm.expectRevert(PlanetCore.NoOracle.selector);
        core.updatePriceSigned(p, "");
    }

    // ---------------------------------------------------------------- collateral
    /// The whole point of wiring a deposit token: a mint that does not receive anything must not
    /// proceed. Before this, mint() minted against a number the caller simply typed.
    function test_mint_reverts_without_deposit_token() public {
        pushAll(100 * SCALE);
        vm.prank(owner);
        core.setDepositToken(address(0));
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.NoDepositToken.selector);
        core.mint(1_000 * SCALE);
    }

    function test_mint_reverts_without_token() public {
        pushAll(100 * SCALE);
        vm.prank(owner);
        core.setToken(address(0));
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.NoToken.selector);
        core.mint(1_000 * SCALE);
    }

    function test_redeem_reverts_without_token() public {
        pushAll(100 * SCALE);
        vm.prank(stranger);
        uint64 minted = core.mint(1_000 * SCALE);
        vm.prank(owner);
        core.setToken(address(0));
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.NoToken.selector);
        core.redeem(minted);
    }

    function test_mint_pulls_the_collateral() public {
        pushAll(100 * SCALE);
        uint64 deposit = 1_000 * SCALE;
        uint256 before = usd.balanceOf(stranger);
        vm.prank(stranger);
        core.mint(deposit);
        assertEq(usd.balanceOf(stranger), before - deposit, "the deposit left the caller");
        assertEq(usd.balanceOf(address(core)), deposit, "the core holds it");
        assertEq(core.totalReserve(), deposit);
    }

    /// totalReserve used to only ever grow: redeem paid the caller without decrementing it, so the
    /// reported backing drifted further from reality with every redemption.
    function test_redeem_pays_out_and_reduces_the_reserve() public {
        pushAll(100 * SCALE);
        uint64 deposit = 1_000 * SCALE;
        vm.prank(stranger);
        uint64 minted = core.mint(deposit);
        uint256 before = usd.balanceOf(stranger);

        vm.prank(stranger);
        uint64 payout = core.redeem(minted);

        assertEq(usd.balanceOf(stranger), before + payout, "the payout reached the caller");
        assertEq(core.totalReserve(), deposit - payout, "the reserve dropped by the payout only");
        assertEq(core.totalSupply(), 0);
        assertLt(uint256(payout), uint256(deposit), "the fee stayed behind");
    }

    // ---------------------------------------------------------------- basket claim vs dollar reserve
    /// The reserve holds a dollar asset; a claim on a basket needs the reserve to MOVE with it.
    /// When the index outruns the reserve the promise cannot be met, so everyone shares the
    /// shortfall instead of the first redeemer taking everything and the rest reverting.
    function test_redeem_is_pro_rata_when_the_index_outruns_the_reserve() public {
        pushAll(100 * SCALE);
        vm.prank(stranger);
        uint64 minted = core.mint(1_000 * SCALE);
        uint256 reserveAfterMint = core.totalReserve();

        // +14%, deliberately inside the 15% BandReject: beyond it redemption reverts before the
        // pro-rata branch is ever reached (see the security review, F-7).
        for (uint256 i; i < 8; ++i) push(i, 114 * SCALE);
        assertEq(core.currentPpi(), 1_140_000);

        uint256 before = usd.balanceOf(stranger);
        vm.prank(stranger);
        uint64 payout = core.redeem(minted);

        assertEq(core.totalReserve(), 0, "the reserve is emptied, not reverted");
        assertEq(usd.balanceOf(stranger), before + payout, "the collateral moved");
        assertEq(uint256(payout), reserveAfterMint, "the last holder takes the remaining reserve");
        assertLt(uint256(payout), (uint256(minted) * 1_140_000) / 1_000_000, "less than the index promised");
    }

    // ---------------------------------------------------------------- security regressions
    /// Redeeming on a stale index pays out at an index the market has left behind. Minting was
    /// gated against that and redemption was not, which is an arbitrage against the reserve.
    function test_redeem_requires_fresh_prices() public {
        pushAll(100 * SCALE);
        vm.prank(stranger);
        uint64 minted = core.mint(1_000 * SCALE);
        vm.warp(block.timestamp + 7 hours);
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.StaleOracle.selector);
        core.redeem(minted);
    }

    function test_mint_is_reentrancy_guarded() public {
        ReentrantToken evil = new ReentrantToken();
        vm.prank(owner);
        core.setDepositToken(address(evil));
        evil.setCore(address(core));
        evil.mintTo(stranger, 1e18);
        pushAll(100 * SCALE);
        evil.arm();
        vm.prank(stranger);
        vm.expectRevert(PlanetCore.Reentrancy.selector);
        core.mint(1_000 * SCALE);
    }

    function _priceAndRisk(uint256 i) internal view returns (uint64 currentPrice, uint8 riskState) {
        (uint64 w, uint64 base, uint64 cur, uint64 vol, uint64 liq, uint8 risk, uint64 stamp) = core.assets(i);
        currentPrice = cur;
        riskState = risk;
        w;
        base;
        vol;
        liq;
        stamp;
    }
}
