// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PlanetCore} from "../src/PlanetCore.sol";
import {PlanetToken} from "../src/PlanetToken.sol";
import {MockERC20} from "./MockERC20.sol";

/// Stateful fuzzing driver. It calls mint/redeem/push in random order with random values and swallows
/// reverts, because most sequences are legitimately invalid — the invariants are what must hold
/// after ANY sequence, not the calls themselves.
contract Handler is Test {
    PlanetCore public core;
    PlanetToken public tok;
    MockERC20 public usd;
    address public relayer;
    address[] public actors;

    constructor(PlanetCore core_, PlanetToken tok_, MockERC20 usd_, address relayer_) {
        core = core_;
        tok = tok_;
        usd = usd_;
        relayer = relayer_;
        actors.push(address(0xA1));
        actors.push(address(0xA2));
        actors.push(address(0xA3));
        for (uint256 i; i < actors.length; i++) {
            usd.mint(actors[i], 1e18);
            vm.prank(actors[i]);
            usd.approve(address(core), type(uint256).max);
        }
    }

    function mint(uint256 seed, uint64 amount) external {
        address a = actors[seed % actors.length];
        amount = uint64(bound(uint256(amount), 1, 1_000 * 1e6));
        vm.prank(a);
        try core.mint(amount) {} catch {}
    }

    function redeem(uint256 seed, uint64 amount) external {
        address a = actors[seed % actors.length];
        uint256 bal = tok.balanceOf(a);
        if (bal == 0) return;
        amount = uint64(bound(uint256(amount), 1, bal));
        vm.prank(a);
        try core.redeem(amount) {} catch {}
    }

    function push(uint256 seed, uint64 price) external {
        price = uint64(bound(uint256(price), 60 * 1e6, 160 * 1e6));
        uint256 idx = seed % core.assetCount();
        vm.prank(relayer);
        try core.updatePrice(idx, price, 0, 1e6, 0, uint64(block.timestamp) + 1) {} catch {}
        vm.warp(block.timestamp + 1);
    }
}

/// The four properties a reader of the whitepaper would assume hold after any history. Unit tests
/// prove specific paths; these prove the paths cannot combine into an inconsistent state.
contract PlanetCoreInvariants is Test {
    PlanetCore core;
    PlanetToken tok;
    MockERC20 usd;
    Handler handler;

    address owner = address(0xA11CE);
    address relayer = address(0xB0B);
    uint64 constant SCALE = 1e6;

    function setUp() public {
        vm.startPrank(owner);
        core = new PlanetCore(owner, relayer);
        tok = new PlanetToken(owner, address(core));
        usd = new MockERC20();
        core.setToken(address(tok));
        core.setDepositToken(address(usd));
        for (uint256 i; i < 8; ++i) core.setAsset(i, 125_000, 100 * SCALE, 100 * SCALE);
        core.lockBasePrices();
        vm.stopPrank();

        handler = new Handler(core, tok, usd, relayer);
        targetContract(address(handler));
    }

    /// The accounting counter and the token that is actually held must never disagree. This is the
    /// property that makes totalReserve meaningful instead of a number the contract tells itself.
    function invariant_reserveEqualsRealBalance() public view {
        assertEq(usd.balanceOf(address(core)), core.totalReserve(), "counter != real balance");
    }

    /// Two places record supply (core and ERC-20). They are only safe if they cannot drift.
    function invariant_supplyMirrorsToken() public view {
        assertEq(tok.totalSupply(), core.totalSupply(), "core and token supply disagree");
    }

    /// The stored index must always equal the one recomputed from the basket.
    function invariant_ppiMatchesRecomputation() public view {
        assertEq(core.currentPpi(), core.computePpi(), "stored index != recomputed index");
    }

    /// A defined index whenever anything exists to be priced against it.
    function invariant_indexDefinedWhileSupplyExists() public view {
        assertTrue(tok.totalSupply() == 0 || core.currentPpi() > 0, "supply exists with an undefined index");
    }


}
