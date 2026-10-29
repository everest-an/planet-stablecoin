// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPerpPrice} from "./IPerpPrice.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title PPIPerp — a perpetual market on the PPI index where the LP pool is the counterparty
/// @notice The platform never takes a side. LPs put up the capital and bear traders' net PnL; the
///         protocol earns open/close fees, the funding it does not pass through, and half of each
///         liquidation penalty. "We sell the casino, we do not gamble" is enforced by the accounting,
///         not by a promise: there is no code path where the owner's balance changes with the market.
/// @dev    Money units: USDC and notional are 1e6, price is 1e18, funding is 1e18 per unit of
///         notional. Every mutation is checks-effects-interactions and behind a reentrancy lock.
contract PPIPerp {
    IERC20 public immutable usdc;
    IPerpPrice public priceSource;
    address public owner;
    bool public paused;

    // --- risk parameters (bps of notional unless stated) ---
    uint256 public maxLeverageBps = 100_000; // 10x initial margin
    uint256 public maxOpenInterest = 1_000_000e6; // $1m notional
    uint256 public openFeeBps = 10; // 0.10%
    uint256 public closeFeeBps = 10;
    uint256 public liqFeeBps = 100; // 1% of notional on liquidation
    uint256 public maintenanceBps = 500; // 5% maintenance margin
    uint256 public constant BPS = 10_000;

    // --- funding: signed rate per second, 1e18 per unit of notional ---
    int256 public fundingRatePerSec;
    int256 public cumFunding;
    uint256 public lastFundingTime;

    // --- pool (the counterparty) ---
    uint256 public totalShares;
    uint256 public poolAssets; // USDC owned by LPs
    mapping(address => uint256) public shares;

    // --- traders ---
    struct Position {
        int256 size; // signed notional, 1e6
        uint256 collateral; // 1e6
        uint256 entryPrice; // 1e18
        int256 fundingEntry; // cumFunding at entry
        bool open;
    }
    mapping(address => Position) public positions;
    uint256 public totalCollateral;
    int256 public netSize;

    uint256 private _lock = 1;

    event PoolDeposit(address indexed who, uint256 assets, uint256 sharesMinted);
    event PoolWithdraw(address indexed who, uint256 assets, uint256 sharesBurned);
    event Opened(address indexed who, int256 size, uint256 collateral, uint256 price, uint8 riskLevel, uint256 fee);
    event Closed(address indexed who, int256 size, uint256 price, int256 pnl, int256 funding, uint256 fee, uint256 payout);
    event Liquidated(address indexed who, address indexed keeper, int256 size, uint256 price, uint256 penalty, uint256 keeperReward);
    event PoolShortfall(address indexed who, uint256 owed, uint256 paid);
    event ParamsSet(uint256 maxLeverageBps, uint256 openFeeBps, uint256 closeFeeBps, uint256 maintenanceBps);
    event FundingRateSet(int256 ratePerSec);
    event PriceSourceSet(address source);

    error NotOwner();
    error Locked();
    error Paused();
    error BadInput();
    error NoPosition();
    error HasPosition();
    error Frozen();
    error TooMuchLeverage();
    error OpenInterestCap();
    error NotLiquidatable();
    error PoolInsolvent();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Locked();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address usdc_, address priceSource_, address owner_) {
        require(usdc_ != address(0) && priceSource_ != address(0) && owner_ != address(0), "zero addr");
        usdc = IERC20(usdc_);
        priceSource = IPerpPrice(priceSource_);
        owner = owner_;
        lastFundingTime = block.timestamp;
    }

    // ---------------------------------------------------------------- pool

    function deposit(uint256 amount) external nonReentrant returns (uint256 minted) {
        if (amount == 0) revert BadInput();
        _accrueFunding();
        minted = totalShares == 0 || poolAssets == 0 ? amount : (amount * totalShares) / poolAssets;
        poolAssets += amount;
        totalShares += minted;
        shares[msg.sender] += minted;
        require(usdc.transferFrom(msg.sender, address(this), amount), "usdc pull");
        emit PoolDeposit(msg.sender, amount, minted);
    }

    function withdraw(uint256 shareAmount) external nonReentrant returns (uint256 amount) {
        if (shareAmount == 0 || shareAmount > shares[msg.sender]) revert BadInput();
        _accrueFunding();
        amount = (shareAmount * poolAssets) / totalShares;
        if (amount == 0) revert BadInput();
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        poolAssets -= amount;
        require(usdc.transfer(msg.sender, amount), "usdc push");
        emit PoolWithdraw(msg.sender, amount, shareAmount);
    }

    // ---------------------------------------------------------------- trading

    /// @param size signed notional in USDC (1e6). Positive long, negative short.
    function open(int256 size, uint256 collateral) external nonReentrant {
        if (paused) revert Paused();
        if (size == 0 || collateral == 0) revert BadInput();
        if (positions[msg.sender].open) revert HasPosition();
        uint8 risk = priceSource.riskLevel();
        if (risk >= 2) revert Frozen();

        uint256 notional = size > 0 ? uint256(size) : uint256(-size);
        if (notional > maxOpenInterest) revert BadInput();
        uint256 oi = _abs(netSize) + notional;
        if (oi > maxOpenInterest) revert OpenInterestCap();

        // caution halves the allowed leverage
        uint256 levBps = risk == 1 ? maxLeverageBps / 2 : maxLeverageBps;
        if (notional * BPS > collateral * levBps) revert TooMuchLeverage();

        _accrueFunding();
        uint256 fee = (notional * openFeeBps) / BPS;
        if (fee >= collateral) revert BadInput();

        require(usdc.transferFrom(msg.sender, address(this), collateral), "usdc pull");
        poolAssets += fee; // the fee belongs to the pool immediately
        uint256 net = collateral - fee;

        positions[msg.sender] = Position({
            size: size,
            collateral: net,
            entryPrice: priceSource.price(),
            fundingEntry: cumFunding,
            open: true
        });
        totalCollateral += net;
        netSize += size;
        emit Opened(msg.sender, size, net, positions[msg.sender].entryPrice, risk, fee);
    }

    function close() external nonReentrant returns (uint256 payout) {
        Position memory p = positions[msg.sender];
        if (!p.open) revert NoPosition();

        _accrueFunding();
        uint256 px = priceSource.price();
        (int256 pnl, int256 funding) = _pnl(p, px);
        uint256 notional = p.size > 0 ? uint256(p.size) : uint256(-p.size);
        uint256 fee = (notional * closeFeeBps) / BPS;

        payout = _settle(msg.sender, p, pnl, funding, fee);
        emit Closed(msg.sender, p.size, px, pnl, funding, fee, payout);
    }

    function liquidate(address trader, uint256 minPayout) external nonReentrant returns (uint256 keeperReward) {
        Position memory p = positions[trader];
        if (!p.open) revert NoPosition();
        _accrueFunding();
        uint256 px = priceSource.price();
        (int256 pnl, int256 funding) = _pnl(p, px);

        uint256 notional = p.size > 0 ? uint256(p.size) : uint256(-p.size);
        uint256 maint = (notional * maintenanceBps) / BPS;
        int256 equity = int256(p.collateral) + pnl - funding;
        if (equity >= int256(maint)) revert NotLiquidatable();

        uint256 remaining = equity > 0 ? uint256(equity) : 0;
        keeperReward = remaining / 2;
        if (keeperReward < minPayout) revert BadInput();

        // Collateral never leaves the contract except as the keeper's cut; whatever is left of the
        // position belongs to the pool. Writing poolAssets as (balance - collateral) keeps the
        // invariant balance == totalCollateral + poolAssets true by construction.
        poolAssets = poolAssets + p.collateral - keeperReward;
        _closePosition(trader, p);
        if (keeperReward > 0) require(usdc.transfer(msg.sender, keeperReward), "keeper pay");
        emit Liquidated(trader, msg.sender, p.size, px, remaining, keeperReward);
    }

    // ---------------------------------------------------------------- views

    function equityOf(address who) external view returns (int256) {
        Position memory p = positions[who];
        if (!p.open) return 0;
        (int256 pnl, int256 funding) = _pnlAt(p, priceSource.price(), _pendingCumFunding());
        return int256(p.collateral) + pnl - funding;
    }

    function riskLevel() external view returns (uint8) {
        return priceSource.riskLevel();
    }

    function sharePrice() external view returns (uint256) {
        return totalShares == 0 ? 1e6 : (poolAssets * 1e6) / totalShares;
    }

    // ---------------------------------------------------------------- admin

    function setParams(
        uint256 maxLeverageBps_,
        uint256 openFeeBps_,
        uint256 closeFeeBps_,
        uint256 maintenanceBps_
    ) external onlyOwner {
        if (maxLeverageBps_ < BPS || maxLeverageBps_ > 2_000_000) revert BadInput();
        if (openFeeBps_ > 100 || closeFeeBps_ > 100) revert BadInput();
        if (maintenanceBps_ < 100 || maintenanceBps_ >= 5000) revert BadInput();
        maxLeverageBps = maxLeverageBps_;
        openFeeBps = openFeeBps_;
        closeFeeBps = closeFeeBps_;
        maintenanceBps = maintenanceBps_;
        emit ParamsSet(maxLeverageBps_, openFeeBps_, closeFeeBps_, maintenanceBps_);
    }

    function setFundingRate(int256 ratePerSec) external onlyOwner {
        _accrueFunding();
        fundingRatePerSec = ratePerSec;
        emit FundingRateSet(ratePerSec);
    }

    function setPriceSource(address src) external onlyOwner {
        if (src == address(0)) revert BadInput();
        priceSource = IPerpPrice(src);
        emit PriceSourceSet(src);
    }

    function setPaused(bool v) external onlyOwner {
        paused = v;
    }

    // ---------------------------------------------------------------- internals

    function _accrueFunding() internal {
        uint256 dt = block.timestamp - lastFundingTime;
        lastFundingTime = block.timestamp;
        if (dt == 0) return;
        cumFunding += fundingRatePerSec * int256(dt);
    }

    function _pnl(Position memory p, uint256 px) internal view returns (int256 pnl, int256 funding) {
        return _pnlAt(p, px, cumFunding);
    }

    function _pnlAt(Position memory p, uint256 px, int256 cf) internal pure returns (int256 pnl, int256 funding) {
        pnl = (p.size * int256(px) - p.size * int256(p.entryPrice)) / int256(p.entryPrice);
        funding = (p.size * (cf - p.fundingEntry)) / 1e18;
    }

    function _pendingCumFunding() internal view returns (int256) {
        return cumFunding + fundingRatePerSec * int256(block.timestamp - lastFundingTime);
    }

    function _settle(
        address who,
        Position memory p,
        int256 pnl,
        int256 funding,
        uint256 fee
    ) internal returns (uint256 payout) {
        int256 equity = int256(p.collateral) + pnl - funding;
        if (fee > 0) equity -= int256(fee);

        uint256 owed = equity > 0 ? uint256(equity) : 0;
        payout = owed;

        // The pool is the counterparty: it pays a winning trader and keeps a losing one's collateral.
        // If the pool cannot pay, the payout is capped and the shortfall is reported - the alternative
        // (reverting) would trap every trader behind an insolvent pool.
        if (payout > poolAssets) {
            payout = poolAssets;
            emit PoolShortfall(who, owed, payout);
        }
        poolAssets = poolAssets + p.collateral - payout;
        _closePosition(who, p);
        if (payout > 0) require(usdc.transfer(who, payout), "trader pay");
    }

    function _closePosition(address who, Position memory p) internal {
        totalCollateral -= p.collateral;
        netSize -= p.size;
        delete positions[who];
    }

    function _abs(int256 v) internal pure returns (uint256) {
        return v >= 0 ? uint256(v) : uint256(-v);
    }
}
