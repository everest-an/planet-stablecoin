// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PlanetToken} from "./PlanetToken.sol";
import {SignedPriceOracle} from "./SignedPriceOracle.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

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
        // Appended, so the generated getter keeps weight..riskState at indices 0..5.
        // Per-asset staleness: a single global timestamp let one fresh asset make the whole index
        // look current while thirteen inputs were days old.
        uint64 lastUpdate;
    }

    // ---------------------------------------------------------------- storage
    address public owner;
    address public relayer;              // authorised price signer for step 1
    /// @notice M-of-N verifier for step 2. May stay unset: updatePriceSigned then reverts NoOracle.
    SignedPriceOracle public oracle;
    /// @notice The collateral a mint pulls and a redeem pays out. Unset means mint() reverts — the
    ///         core will not mint against a number it does not actually receive.
    IERC20 public depositToken;
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
    /// @notice The PLT token. Optional so the economics can be exercised without it; set it in production.
    PlanetToken public token;

    Asset[] public assets;

    // ---------------------------------------------------------------- events
    event OwnerChanged(address indexed from, address indexed to);
    event RelayerChanged(address indexed relayer);
    event PausedSet(bool paused);
    event BaseLocked();
    event AssetSet(uint256 indexed index, uint64 weight, uint64 basePrice, uint64 currentPrice);
    event PriceUpdated(uint256 indexed index, uint64 price, uint64 ppi, uint64 timestamp);
    event PriceForced(uint256 indexed index, uint64 price, uint64 ppi);
    event RiskStateSet(uint256 indexed index, uint8 state, uint64 ppi);
    event OracleChanged(address indexed oracle);
    event DepositTokenChanged(address indexed token);
    event Minted(address indexed to, uint64 deposit, uint64 fee, uint64 minted, uint64 ppi);
    event Redeemed(address indexed from, uint64 burned, uint64 feeBps, uint64 payout, uint64 ppi);
    event RedeemedProRata(address indexed from, uint64 burned, uint64 payout, uint64 reserve);
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
    error BadRiskState();
    error NoOracle();
    error BadSignature();
    error NoDepositToken();
    error NoToken();
    error TransferFailed();
    error AmountTooLarge();
    error Reentrancy();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer();
        _;
    }

    /// @dev mint pulls the collateral with an external call before touching state, which is a
    ///      reentrancy surface for any deposit token that has transfer hooks. USDC does not, but the
    ///      core accepts whatever token the owner wires, so it must not depend on that.
    uint256 private _entered;
    modifier nonReentrant() {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
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

    /// @notice Wire the token. Once set, mint() mints it and redeem() burns it, synchronously.
    function setToken(address next) external onlyOwner {
        token = PlanetToken(next);
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
        if (baseLocked && index < assets.length && basePrice != assets[index].basePrice) revert BaseIsLocked();

        if (index == assets.length) {
            assets.push(Asset(weight, basePrice, currentPrice == 0 ? basePrice : currentPrice, 0, SCALE, RISK_NORMAL, 0));
        } else {
            if (index > assets.length) revert BadIndex();
            Asset storage a = assets[index];
            uint64 keepBase = a.basePrice; // base is never changed by an update
            a.weight = weight;
            a.basePrice = keepBase;
            if (currentPrice != 0) a.currentPrice = currentPrice;
        }
        // NOTE: the weight sum is enforced on every PRICE UPDATE (I1), not here. Requiring it per
        // setAsset call would make it impossible to build a basket incrementally.
        emit AssetSet(index, weight, assets[index].basePrice, assets[index].currentPrice);
    }

    function lockBasePrices() external onlyOwner {
        baseLocked = true;
        emit BaseLocked();
    }

    /// @notice Step 1: one authorised relayer pushes a price.
    function updatePrice(uint256 index, uint64 price, uint64 volatility, uint64 liquidity, uint8 riskState, uint64 timestamp)
        external
        onlyRelayer
    {
        _applyPrice(index, price, volatility, liquidity, riskState, timestamp, false);
    }

    /// @notice Step 2: an M-of-N signed payload, verified by the separately deployed oracle.
    /// @dev    Deliberately not `onlyRelayer`: authenticity comes from the signatures, so anyone may
    ///         relay. The oracle bounds the payload to (its own address, chainid) in its digest, so a
    ///         signature cannot be replayed onto another oracle or another chain.
    function updatePriceSigned(SignedPriceOracle.PricePayload calldata p, bytes calldata sigs) external {
        if (address(oracle) == address(0)) revert NoOracle();
        if (!oracle.verify(p, sigs)) revert BadSignature();
        _applyPrice(p.index, p.price, p.volatility, p.liquidity, p.riskState, p.timestamp, false);
    }

    function setOracle(address next) external onlyOwner {
        oracle = SignedPriceOracle(next);
        emit OracleChanged(next);
    }

    /// @notice Wire the collateral. One-way in practice: changing it after a mint would leave the
    ///         previous token stranded in the contract.
    function setDepositToken(address next) external onlyOwner {
        depositToken = IERC20(next);
        emit DepositTokenChanged(next);
    }

    /// @notice Emergency path around the 50% jump guard, owner-only (put the owner behind the timelock).
    /// @dev    Without this, a genuine >50% move can never be recorded: the push reverts forever, the
    ///         oldest input passes MAX_ORACLE_AGE, and minting stops permanently with no way back.
    ///         A forced price is recorded as at least CAUTION so the index visibly flags it.
    function forcePrice(uint256 index, uint64 price, uint64 volatility, uint64 liquidity, uint8 riskState, uint64 timestamp)
        external
        onlyOwner
    {
        _applyPrice(index, price, volatility, liquidity, riskState, timestamp, true);
    }

    /// @notice Freeze (2) or un-freeze (0/1) an asset without a price. Frozen assets are skipped by
    ///         the index AND by the staleness check, so the owner can retire a dead feed instead of
    ///         letting it block minting forever.
    function setRiskState(uint256 index, uint8 state) external onlyOwner {
        if (index >= assets.length) revert BadIndex();
        if (state > RISK_FROZEN) revert BadRiskState();
        assets[index].riskState = state;
        currentPpi = computePpi();
        emit RiskStateSet(index, state, currentPpi);
    }

    function _applyPrice(
        uint256 index,
        uint64 price,
        uint64 volatility,
        uint64 liquidity,
        uint8 riskState,
        uint64 timestamp,
        bool skipJump
    ) internal {
        if (paused) revert IsPaused();
        if (index >= assets.length) revert BadIndex();
        if (riskState > RISK_FROZEN) revert BadRiskState();
        if (timestamp <= lastOracleUpdate) revert BadTimestamp();
        if (weightSum() != SCALE) revert BadWeights();

        Asset storage a = assets[index];
        if (!skipJump && !priceJumpOk(a.currentPrice, price)) revert PriceJump();

        a.currentPrice = price;
        a.volatility = volatility;
        a.liquidity = liquidity;
        a.riskState = skipJump && riskState == RISK_NORMAL ? RISK_CAUTION : riskState;
        a.lastUpdate = timestamp;

        lastOracleUpdate = timestamp;
        currentPpi = computePpi();
        if (skipJump) emit PriceForced(index, price, currentPpi);
        emit PriceUpdated(index, price, currentPpi, timestamp);
    }

    /// @notice The timestamp of the STALEST price among active (non-frozen) assets; 0 when none.
    ///         This, not lastOracleUpdate, is what mint() gates on: an index is only as fresh as
    ///         its worst input.
    function oldestActiveUpdate() public view returns (uint64 oldest) {
        uint256 n = assets.length;
        bool seen;
        for (uint256 i; i < n; ++i) {
            Asset storage a = assets[i];
            if (a.riskState == RISK_FROZEN) continue;
            if (!seen || a.lastUpdate < oldest) {
                oldest = a.lastUpdate;
                seen = true;
            }
        }
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
    function mint(uint64 deposit) external nonReentrant returns (uint64 minted) {
        if (paused) revert IsPaused();
        if (deposit == 0) revert ZeroAmount();
        uint64 ppi = currentPpi;
        if (ppi == 0) revert NoActiveAsset(); // C-1: never mint against an undefined index
        uint64 oldest = oldestActiveUpdate();
        if (oldest == 0 || block.timestamp > uint256(oldest) + MAX_ORACLE_AGE) {
            revert StaleOracle();
        }

        uint64 feeBps = feeBpsForPpi(ppi);
        uint256 fee = uint256(deposit) * feeBps / uint256(BPS_DENOM);
        uint256 net = uint256(deposit) - fee;
        uint256 minted256 = net * uint256(SCALE) / uint256(ppi);
        if (minted256 == 0) revert ZeroAmount();
        // An explicit uint64 downcast TRUNCATES in 0.8 instead of reverting, so a large enough
        // deposit would silently mint a wrapped amount.
        if (minted256 > type(uint64).max) revert AmountTooLarge();
        minted = uint64(minted256);

        // Pull the collateral BEFORE any state change. Every check above has already run, so this
        // cannot leave the contract holding a deposit it refused to mint against.
        if (address(token) == address(0)) revert NoToken();
        if (address(depositToken) == address(0)) revert NoDepositToken();
        if (!depositToken.transferFrom(msg.sender, address(this), uint256(deposit))) revert TransferFailed();

        totalSupply += minted;
        token.mint(msg.sender, minted); // EVM: synchronous, no mirror
        totalReserve += deposit;
        _routeFees(fee);
        emit Minted(msg.sender, deposit, uint64(fee), minted, ppi);
    }

    // ---------------------------------------------------------------- redeem
    function redeem(uint64 burnAmount) external nonReentrant returns (uint64 payout) {
        if (paused) revert IsPaused();
        if (burnAmount == 0) revert ZeroAmount();
        uint64 ppi = currentPpi;
        if (ppi == 0) revert NoActiveAsset();
        // Without a token, redeem would pay the reserve out without burning anything.
        if (address(token) == address(0)) revert NoToken();
        // Redeeming on a stale index is an arbitrage against the reserve: if the real index fell,
        // the stale (higher) PPI pays out more than the basket is worth. Minting was gated and
        // redemption was not.
        uint64 oldest = oldestActiveUpdate();
        if (oldest == 0 || block.timestamp > uint256(oldest) + MAX_ORACLE_AGE) revert StaleOracle();

        // Validate supply BEFORE any division: the pro-rata branch divides by totalSupply, and an
        // empty supply panicked there before the underflow check could run.
        if (totalSupply < burnAmount) revert Underflow();

        uint64 feeBps = feeBpsForPpi(ppi);
        uint64 burnFee = feeBps > MAX_BURN_FEE_BPS ? MAX_BURN_FEE_BPS : feeBps; // I9 / payout >= 0
        uint256 gross = uint256(burnAmount) * uint256(ppi) / uint256(SCALE);
        uint256 fee = gross * burnFee / uint256(BPS_DENOM);
        uint256 payout256 = gross - fee;

        // A claim on a basket is only honest if the reserve MOVES WITH the basket. This build holds
        // a dollar asset, so when the index outruns the reserve the promise cannot be met. Reverting
        // would pay whoever redeemed first in full and leave the rest with a dead transaction - a
        // bank run encoded in the fee schedule. Instead everyone shares the shortfall pro-rata, and
        // no protocol fee is taken on a distressed redemption.
        bool distressed;
        if (payout256 > uint256(totalReserve)) {
            payout256 = uint256(burnAmount) * uint256(totalReserve) / uint256(totalSupply);
            fee = 0;
            distressed = true;
        }
        if (payout256 == 0) revert ZeroAmount();
        if (payout256 > type(uint64).max) revert AmountTooLarge();
        payout = uint64(payout256);

        totalSupply -= burnAmount;
        token.burn(msg.sender, burnAmount);

        // The payout leaves the reserve; the fee does not (it stays in the contract and _routeFees
        // labels it). Without this decrement totalReserve only ever grows and overstates the backing.
        if (address(depositToken) == address(0)) revert NoDepositToken();
        if (totalReserve < payout) revert Underflow();
        totalReserve -= payout;
        if (!depositToken.transfer(msg.sender, uint256(payout))) revert TransferFailed();

        _routeFees(fee);
        if (distressed) emit RedeemedProRata(msg.sender, burnAmount, payout, totalReserve);
        emit Redeemed(msg.sender, burnAmount, burnFee, payout, ppi);
    }

    function _routeFees(uint256 fee) internal {
        uint64 burn = uint64(fee * uint256(BURN_SHARE_BPS) / uint256(BPS_DENOM));
        uint64 stake = uint64(fee * uint256(STAKE_SHARE_BPS) / uint256(BPS_DENOM));
        uint64 risk = uint64(fee * uint256(RISK_SHARE_BPS) / uint256(BPS_DENOM));
        // The 10% risk carve-out comes out of the reserve bucket: net 30 / 40 / 20 / 10.
        uint64 reserve = uint64(fee * uint256(RESERVE_SHARE_BPS) / uint256(BPS_DENOM)) - risk;

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
