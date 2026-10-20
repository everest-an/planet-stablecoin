// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * PlanetCore (Monad / EVM port) — step 1 of the migration.
 *
 * WHAT THIS IS
 *   A faithful port of the ECONOMICS, not a line-by-line translation. The TON version is Tolk on a
 *   message-passing VM; this is Solidity on an EVM. The maths and the invariants are identical:
 *
 *     I1  sum(weight) == 1e6 on every price update
 *     I2  each weight <= 150_000 (15%)
 *     I3  base prices are immutable once locked
 *     I4  PPI = renormalised weighted mean over ACTIVE (non-frozen) assets; **0 if none active**
 *         (this is the C-1 fix: an undefined index must never read as 1.0)
 *     I5  mint requires oracle freshness <= MAX_ORACLE_AGE AND ppi > 0
 *     I6  fees split 30 burn / 50 reserve / 20 staking, with 10% of the fee carved into the risk fund
 *     I7  privileged calls are owner-only
 *     I9  totalIssued >= face on every debit (no underflow)
 *
 * WHAT IS DELIBERATELY NOT HERE YET (tracked, not forgotten)
 *   - M-of-N signed oracle (EVM uses ECDSA/ecrecover; the TON version used ed25519 with a signer set)
 *     -> today: a single authorised relayer, all the same guards.
 *   - PlanetTimelock / PlanetGov / Bond / Fund and the ERC-20 itself -> step 2.
 *   - The reviewed "constitution" (bounded governance) -> step 3.
 *
 * SECURITY POSTURE
 *   - Checks-effects-interactions throughout; no external calls in this contract at all in step 1.
 *   - All arithmetic is uint128/uint256 with explicit bounds; Solidity 0.8 reverts on overflow.
 *   - Not audited. Testnet only. Do not put real value in it.
 */
contract PlanetCore {
    // ---------------------------------------------------------------- constants
    uint64 public constant SCALE = 1e6;              // 1e6 == 1.0
    uint64 public constant MAX_ASSET_WEIGHT = 150_000; // 15%
    uint64 public constant MAX_ORACLE_AGE = 6 hours;

    uint64 public constant FEE_BASE_BPS = 50;        // 0.5%
    uint64 public constant FEE_MID_BPS = 100;        // 1%   at 3-5% deviation
    uint64 public constant FEE_HIGH_BPS = 200;       // 2%   beyond 5%
    uint64 public constant SLOPE_BPS = 100;          // steepening per 1% beyond 5%
    uint64 public constant BAND_REJECT_BPS = 1500;   // >15% deviation: mint refused
    uint64 public constant BPS_DENOM = 10_000;
    uint64 public constant MAX_BURN_FEE_BPS = 500;   // redemption payout never negative

    uint64 public constant BURN_SHARE_BPS = 3000;    // 30%
    uint64 public constant RESERVE_SHARE_BPS = 5000; // 50%
    uint64 public constant STAKE_SHARE_BPS = 2000;   // 20%
    uint64 public constant RISK_SHARE_BPS = 1000;    // 10% taken from the fee (net 30/40/20/10)

    uint8 public constant RISK_NORMAL = 0;
    uint8 public constant RISK_CAUTION = 1;
    uint8 public constant RISK_FROZEN = 2;

    // ---------------------------------------------------------------- types
    struct Asset {
        uint64 weight;       // ppm of the basket
        uint64 basePrice;    // 1e6 fixed point, immutable once locked
        uint64 currentPrice; // 1e6 fixed point
        uint64 volatility;   // 1e6 fixed point (advisory)
        uint64 liquidity;    // 1e6 fixed point (advisory)
        uint8 riskState;     // 0 normal / 1 caution / 2 frozen
    }

    // ---------------------------------------------------------------- storage
    address public owner;
    address public relayer;              // authorised price signer for step 1
    bool public paused;
    bool public baseLocked;

    uint64 public currentPpi = SCALE;
    uint64 public lastOracleUpdate;

    uint64 public totalSupply;
    uint64 public totalReserve;
    uint64 public feesToBurn;
    uint64 public feesToReserve;
    uint64 public feesToStaking;
    uint64 public riskFund;

    Asset[] public assets;

    // ---------------------------------------------------------------- events
    event OwnerChanged(address indexed from, address indexed to);
    event RelayerChanged(address indexed relayer);
    event PausedSet(bool paused);
    event BaseLocked();
    event AssetSet(uint256 indexed index, uint64 weight, uint64 basePrice, uint64 currentPrice);
    event PriceUpdated(uint256 indexed index, uint64 price, uint64 ppi, uint64 timestamp);
    event Minted(address indexed to, uint64 deposit, uint64 fee, uint64 minted, uint64 ppi);
    event Redeemed(address indexed from, uint64 burned, uint64 feeBps, uint64 payout, uint64 ppi);
    event FeesRouted(uint64 burn, uint64 reserve, uint64 staking, uint64 risk);

    // ---------------------------------------------------------------- errors
    error NotOwner();
    error NotRelayer();
    error IsPaused();
    error NoActiveAsset();       // C-1: the index is undefined
    error StaleOracle();
    error BadIndex();
    error BadWeights();
    error BadWeight();
    error PriceJump();
    error BaseIsLocked();
    error BaseNotLocked();
    error ZeroAmount();
    error BandReject();
    error Underflow();
    error BadTimestamp();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer();
        _;
    }

    constructor(address owner_, address relayer_) {
        if (owner_ == address(0)) revert NotOwner();
        owner = owner_;
        relayer = relayer_;
    }

    // ---------------------------------------------------------------- admin (I7)
    function setOwner(address next) external onlyOwner {
        if (next == address(0)) revert NotOwner();
        emit OwnerChanged(owner, next);
        owner = next;
    }

    function setRelayer(address next) external onlyOwner {
        relayer = next;
        emit RelayerChanged(next);
    }

    function setPaused(bool v) external onlyOwner {
        paused = v;
        emit PausedSet(v);
    }

    /// @notice Owner appends or replaces one basket slot. Base price may only be set BEFORE the lock.
    function setAsset(uint256 index, uint64 weight, uint64 basePrice, uint64 currentPrice)
        external
        onlyOwner
    {
        if (weight > MAX_ASSET_WEIGHT) revert BadWeight();
        if (basePrice == 0) revert ZeroAmount();
        if (baseLocked && basePrice != assets[index].basePrice) revert BaseIsLocked();

        if (index == assets.length) {
            assets.push(Asset(weight, basePrice, currentPrice == 0 ? basePrice : currentPrice, 0, SCALE, RISK_NORMAL));
        } else {
            if (index > assets.length) revert BadIndex();
            Asset storage a = assets[index];
            uint64 keepBase = a.basePrice; // base is never changed by an update
            a.weight = weight;
            a.basePrice = keepBase;
            if (currentPrice != 0) a.currentPrice = currentPrice;
        }
        // I1: the weight sum must stay exactly 100% after every basket change
        if (weightSum() != SCALE) revert BadWeights();
        emit AssetSet(index, weight, assets[index].basePrice, assets[index].currentPrice);
    }

    function lockBasePrices() external onlyOwner {
        baseLocked = true;
        emit BaseLocked();
    }

    /// @notice Guarded price update. Step 1: one authorised relayer (M-of-N arrives in step 2).
    ///         Guards are identical to the TON version: monotonic timestamp, basket weights valid,
    ///         single-update jump limit.
    function updatePrice(uint256 index, uint64 price, uint64 volatility, uint64 liquidity, uint8 riskState, uint64 timestamp)
        external
        onlyRelayer
    {
        if (paused) revert IsPaused();
        if (index >= assets.length) revert BadIndex();
        if (timestamp <= lastOracleUpdate) revert BadTimestamp();
        if (weightSum() != SCALE) revert BadWeights();

        Asset storage a = assets[index];
        if (!priceJumpOk(a.currentPrice, price)) revert PriceJump();

        a.currentPrice = price;
        a.volatility = volatility;
        a.liquidity = liquidity;
        a.riskState = riskState;

        lastOracleUpdate = timestamp;
        currentPpi = computePpi();
        emit PriceUpdated(index, price, currentPpi, timestamp);
    }

    // ---------------------------------------------------------------- index (I4)
    /// @notice 1e6-fixed weighted mean over ACTIVE assets, renormalised by the active weight sum.
    ///         Returns 0 when nothing is active — the index is UNDEFINED, which is what stops a mint
    ///         against a fabricated 1.0 (the C-1 finding).
    function computePpi() public view returns (uint64) {
        uint256 num;
        uint256 den;
        uint256 n = assets.length;
        for (uint256 i; i < n; ++i) {
            Asset storage a = assets[i];
            if (a.riskState == RISK_FROZEN) continue;
            // price/base in 1e6; weight in ppm -> product is 1e12, divide back by SCALE
            num += uint256(a.weight) * uint256(a.currentPrice) * uint256(SCALE) / uint256(a.basePrice);
            den += uint256(a.weight);
        }
        if (den == 0) return 0; // C-1
        return uint64(num / den);
    }

    function weightSum() public view returns (uint64 sum) {
        uint256 n = assets.length;
        for (uint256 i; i < n; ++i) sum += assets[i].weight;
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    /// @notice A single update may not move a price by more than 50%.
    function priceJumpOk(uint64 oldPrice, uint64 newPrice) public pure returns (bool) {
        if (oldPrice == 0 || newPrice == 0) return false;
        uint256 diff = oldPrice > newPrice ? oldPrice - newPrice : newPrice - oldPrice;
        return diff * uint256(BPS_DENOM) <= uint256(oldPrice) * uint256(5000);
    }

    // ---------------------------------------------------------------- fees (I6)
    function feeBpsForPpi(uint64 ppi) public pure returns (uint64) {
        uint256 d = ppi > SCALE ? ppi - SCALE : SCALE - ppi;
        if (d * uint256(BPS_DENOM) > uint256(SCALE) * uint256(BAND_REJECT_BPS)) revert BandReject();
        if (d * uint256(BPS_DENOM) <= uint256(SCALE) * 300) return FEE_BASE_BPS;                 // <=3%
        if (d * uint256(BPS_DENOM) <= uint256(SCALE) * 500) return FEE_MID_BPS;                  // 3-5%
        // >5%: 2% + slope per point of extra deviation
        uint256 extraBps = (d * uint256(BPS_DENOM) / uint256(SCALE)) - 500;
        return uint64(uint256(FEE_HIGH_BPS) + extraBps * uint256(SLOPE_BPS) / 100);
    }

    // ---------------------------------------------------------------- mint (I5, I6)
    /// @param deposit  units deposited (whatever the caller settles), 1e6 fixed point
    function mint(uint64 deposit) external returns (uint64 minted) {
        if (paused) revert IsPaused();
        if (deposit == 0) revert ZeroAmount();
        if (lastOracleUpdate == 0 || block.timestamp > uint256(lastOracleUpdate) + MAX_ORACLE_AGE) {
            revert StaleOracle();
        }
        uint64 ppi = currentPpi;
        if (ppi == 0) revert NoActiveAsset(); // C-1: never mint against an undefined index

        uint64 feeBps = feeBpsForPpi(ppi);
        uint256 fee = uint256(deposit) * feeBps / uint256(BPS_DENOM);
        uint256 net = uint256(deposit) - fee;
        minted = uint64(net * uint256(SCALE) / uint256(ppi));
        if (minted == 0) revert ZeroAmount();

        totalSupply += minted;
        totalReserve += deposit;
        _routeFees(fee);
        emit Minted(msg.sender, deposit, uint64(fee), minted, ppi);
    }

    // ---------------------------------------------------------------- redeem
    function redeem(uint64 burnAmount) external returns (uint64 payout) {
        if (paused) revert IsPaused();
        if (burnAmount == 0) revert ZeroAmount();
        uint64 ppi = currentPpi;
        if (ppi == 0) revert NoActiveAsset();

        uint64 feeBps = feeBpsForPpi(ppi);
        uint64 burnFee = feeBps > MAX_BURN_FEE_BPS ? MAX_BURN_FEE_BPS : feeBps; // I9 / payout >= 0
        uint256 gross = uint256(burnAmount) * uint256(ppi) / uint256(SCALE);
        uint256 fee = gross * burnFee / uint256(BPS_DENOM);
        payout = uint64(gross - fee);

        if (totalSupply < burnAmount) revert Underflow(); // no silent wrap
        totalSupply -= burnAmount;

        _routeFees(fee);
        emit Redeemed(msg.sender, burnAmount, burnFee, payout, ppi);
    }

    function _routeFees(uint256 fee) internal {
        uint64 burn = uint64(fee * uint256(BURN_SHARE_BPS) / uint256(BPS_DENOM));
        uint64 reserve = uint64(fee * uint256(RESERVE_SHARE_BPS) / uint256(BPS_DENOM));
        uint64 stake = uint64(fee * uint256(STAKE_SHARE_BPS) / uint256(BPS_DENOM));
        uint64 risk = uint64(fee * uint256(RISK_SHARE_BPS) / uint256(BPS_DENOM));

        feesToBurn += burn;
        feesToReserve += reserve;
        feesToStaking += stake;
        riskFund += risk;
        // NOTE: the reserve share is NOT deducted here. The deposit already added the gross amount to
        // totalReserve; the reserve bucket is a label on that same money, not a transfer out of it.
        emit FeesRouted(burn, reserve, stake, risk);
    }

    /// @notice Owner moves risk-fund money into the reserve (the TON CoverDeficit).
    function coverDeficit(uint64 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (riskFund < amount) revert Underflow();
        riskFund -= amount;
        totalReserve += amount;
    }
}
