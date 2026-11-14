// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CollateralRegistry} from "./CollateralRegistry.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @title LendingPool — MVP: one borrow asset (USDC), tokenized-commodity collateral, data-quality LTV.
/// @dev Deliberately small: no oracles beyond the registry, no internal AMM, no governance module.
///      Not audited. Liquidation is "repay the debt, receive the collateral" — an external venue is
///      where the liquidator actually sells it.
contract LendingPool {
    IERC20 public immutable usdc;
    CollateralRegistry public immutable registry;
    address public owner;

    /// @dev simple per-second rate, 1e18 scale; bounded by MAX_RATE
    uint256 public ratePerSec;
    uint256 public constant MAX_RATE = 1e10; // ~31.5%/yr
    uint256 public constant BPS = 10_000;
    uint256 public constant INDEX = 1e18;
    uint16 public liquidationBonusBps = 500; // 5% of seized value for the liquidator

    uint256 public totalSupplyAssets;
    uint256 public totalShares;
    uint256 public totalDebt;
    uint256 public borrowIndex = 1e18;
    uint256 public lastAccrual;

    mapping(address => uint256) public supplyShares;
    mapping(address => uint256) public debtShares;
    mapping(address => mapping(address => uint256)) public collateral;

    event Deposit(address indexed who, uint256 amount, uint256 shares);
    event Withdraw(address indexed who, uint256 amount, uint256 shares);
    event CollateralDeposited(address indexed who, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed who, address indexed token, uint256 amount);
    event Borrowed(address indexed who, uint256 amount);
    event Repaid(address indexed who, uint256 amount);
    event Liquidated(address indexed who, address indexed by, uint256 debtRepaid);

    error NotOwner();
    error BadInput();
    error Unhealthy();
    error InsufficientCash();
    error TooMuchDebt();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address usdc_, address registry_, address owner_) {
        if (usdc_ == address(0) || registry_ == address(0) || owner_ == address(0)) revert BadInput();
        if (IERC20(usdc_).decimals() != 6) revert BadInput();
        usdc = IERC20(usdc_);
        registry = CollateralRegistry(registry_);
        owner = owner_;
        lastAccrual = block.timestamp;
    }

    // ---------------------------------------------------------------- admin

    function setOwner(address next) external onlyOwner {
        if (next == address(0)) revert BadInput();
        owner = next;
    }

    function setRate(uint256 ratePerSec_) external onlyOwner {
        if (ratePerSec_ > MAX_RATE) revert BadInput();
        _accrue();
        ratePerSec = ratePerSec_;
    }

    function setLiquidationBonus(uint16 bps) external onlyOwner {
        if (bps > 1_500) revert BadInput();
        liquidationBonusBps = bps;
    }

    // ---------------------------------------------------------------- supply side

    function deposit(uint256 amount) external returns (uint256 shares) {
        if (amount == 0) revert BadInput();
        _accrue();
        shares = totalShares == 0 || totalSupplyAssets == 0 ? amount : (amount * totalShares) / totalSupplyAssets;
        totalShares += shares;
        totalSupplyAssets += amount;
        supplyShares[msg.sender] += shares;
        require(usdc.transferFrom(msg.sender, address(this), amount), "pull");
        emit Deposit(msg.sender, amount, shares);
    }

    function withdraw(uint256 shares) external returns (uint256 amount) {
        if (shares == 0 || shares > supplyShares[msg.sender]) revert BadInput();
        _accrue();
        amount = (shares * totalSupplyAssets) / totalShares;
        if (amount == 0) revert BadInput();
        if (usdc.balanceOf(address(this)) < amount) revert InsufficientCash();
        supplyShares[msg.sender] -= shares;
        totalShares -= shares;
        totalSupplyAssets -= amount;
        require(usdc.transfer(msg.sender, amount), "push");
        emit Withdraw(msg.sender, amount, shares);
    }

    // ---------------------------------------------------------------- borrow side

    function depositCollateral(address token, uint256 amount) external {
        if (amount == 0) revert BadInput();
        collateral[msg.sender][token] += amount;
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "pull");
        emit CollateralDeposited(msg.sender, token, amount);
    }

    function withdrawCollateral(address token, uint256 amount) external {
        if (amount == 0 || amount > collateral[msg.sender][token]) revert BadInput();
        collateral[msg.sender][token] -= amount;
        if (!_healthy(msg.sender)) revert Unhealthy();
        require(IERC20(token).transfer(msg.sender, amount), "push");
        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    function borrow(uint256 amount) external {
        if (amount == 0) revert BadInput();
        _accrue();
        if (usdc.balanceOf(address(this)) < amount) revert InsufficientCash();
        uint256 debt = _debtOf(msg.sender);
        if (debt + amount > borrowLimit(msg.sender)) revert TooMuchDebt();
        debtShares[msg.sender] += (amount * INDEX) / borrowIndex;
        totalDebt += amount;
        require(usdc.transfer(msg.sender, amount), "push");
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external returns (uint256 paid) {
        _accrue();
        uint256 debt = _debtOf(msg.sender);
        paid = amount > debt ? debt : amount;
        if (paid == 0) revert BadInput();
        uint256 shares = (paid * INDEX) / borrowIndex;
        debtShares[msg.sender] = shares >= debtShares[msg.sender] ? 0 : debtShares[msg.sender] - shares;
        totalDebt -= paid;
        require(usdc.transferFrom(msg.sender, address(this), paid), "pull");
        emit Repaid(msg.sender, paid);
    }

    /// @notice Unhealthy position: the caller repays the debt and receives the collateral (seized
    ///         value = debt + bonus, capped at the collateral value). The liquidator sells elsewhere.
    function liquidate(address who) external {
        _accrue();
        if (_healthy(who)) revert Unhealthy();
        uint256 debt = _debtOf(who);
        if (debt == 0) revert BadInput();
        uint256 supply = collateralValue(who);
        require(supply >= debt, "bad debt");

        uint256 seizeValue = debt + (debt * liquidationBonusBps) / BPS;
        if (seizeValue > supply) seizeValue = supply;

        debtShares[who] = 0;
        totalDebt -= debt;
        require(usdc.transferFrom(msg.sender, address(this), debt), "pull");

        uint256 n = registry.count();
        for (uint256 i; i < n; ++i) {
            address token = registry.tokens(i);
            uint256 bal = collateral[who][token];
            if (bal == 0) continue;
            (uint256 value, ) = registry.valueOf(token, bal);
            uint256 take = (bal * seizeValue) / supply;
            if (take > bal) take = bal;
            collateral[who][token] = bal - take;
            require(IERC20(token).transfer(msg.sender, take), "push");

        }
        emit Liquidated(who, msg.sender, debt);
    }

    // ---------------------------------------------------------------- views

    function debtOf(address who) external view returns (uint256) {
        uint256 idx = borrowIndex;
        if (totalDebt > 0 && ratePerSec > 0 && block.timestamp > lastAccrual) {
            idx += (ratePerSec * (block.timestamp - lastAccrual) * idx) / INDEX;
        }
        return (debtShares[who] * idx) / INDEX;
    }

    function collateralValue(address who) public view returns (uint256 total) {
        uint256 n = registry.count();
        for (uint256 i; i < n; ++i) {
            address token = registry.tokens(i);
            uint256 bal = collateral[who][token];
            if (bal == 0) continue;
            (uint256 v, ) = registry.valueOf(token, bal);
            total += v;
        }
    }

    function borrowLimit(address who) public view returns (uint256 limit) {
        uint256 n = registry.count();
        for (uint256 i; i < n; ++i) {
            address token = registry.tokens(i);
            uint256 bal = collateral[who][token];
            if (bal == 0) continue;
            (uint256 v, ) = registry.valueOf(token, bal);
            (uint16 ltv, ) = registry.ltvOf(token);
            limit += (v * ltv) / BPS;
        }
    }

    function liquidationLimit(address who) public view returns (uint256 limit) {
        uint256 n = registry.count();
        for (uint256 i; i < n; ++i) {
            address token = registry.tokens(i);
            uint256 bal = collateral[who][token];
            if (bal == 0) continue;
            (uint256 v, ) = registry.valueOf(token, bal);
            limit += (v * registry.liqThresholdOf(token)) / BPS;
        }
    }

    function _healthy(address who) internal view returns (bool) {
        return _debtOf(who) <= liquidationLimit(who);
    }

    function _debtOf(address who) internal view returns (uint256) {
        return (debtShares[who] * borrowIndex) / INDEX;
    }

    function _accrue() internal {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return;
        lastAccrual = block.timestamp;
        if (totalDebt == 0 || ratePerSec == 0) return;
        uint256 interest = (totalDebt * ratePerSec * dt) / INDEX;
        totalDebt += interest;
        totalSupplyAssets += interest;
        borrowIndex += (ratePerSec * dt * borrowIndex) / INDEX;
    }
}
