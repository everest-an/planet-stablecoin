// PlanetCore.tolk — Planet on TON (Phase 0 skeleton, Tolk language)
//
// Compiled with the Acton toolchain (see ton/README.md). CI: .github/workflows/ton-build.yml
//
// Fixed-point integers only (1e6). No floats.

import "jetton/messages"
import "oracle_state"
import "burn_mirror"
import "limits"

const FEE_BPS = 50;          // 0.5% = 50 bps (near peg)
const FEE_BPS_ELEVATED = 100; // 1.0% when |PPI-1| in (3%, 5%]
const FEE_BPS_HIGH = 200;    // 2.0% when |PPI-1| > 5%
const BPS_DENOM = 10000;
const PPI_SCALE = 1000000;   // 1.0 in 1e6 fixed point
const BAND_LOW = 30000;      // 3%  deviation (ppm)
const BAND_HIGH = 50000;     // 5%  deviation
const BAND_FREEZE = 150000;  // 15% deviation -> hard mint freeze

const ERR_PAUSED = 100;
const ERR_NOT_OWNER = 101;
const ERR_SUPPLY = 102;
const ERR_NOT_ORACLE = 103;
const ERR_STALE_PRICE = 104;
const ERR_NOT_MINTER = 105;
const ERR_BAD_BASE = 106;
const ERR_BAD_WEIGHTS = 107;
const ERR_BASE_LOCKED = 108;
const ERR_BAD_INDEX = 109;
const ERR_DEVIATION = 110;
const ERR_LIMIT = 111;

// Fee split (white paper §8.4): 45% buyback-burn / 30% reserve / 25% PLTG staking.
const BURN_SHARE_BPS = 4500;
const RESERVE_SHARE_BPS = 3000;

// Basket weights (ppm, 1e6 = 100%) and rebalance threshold (0.5%).
const WEIGHT_SCALE = 1000000;
const REBALANCE_THRESHOLD = 5000;

// TON forwarded (through the minter) to the recipient's Jetton wallet so that the
// auto-deployed wallet has gas to credit the minted PLT. Matches tolk-bench's
// 0.05 TON mint forward used by the reference TEP-74 tests.
const MINT_FORWARD_TON = ton("0.05");

// ---------------- Storage ----------------

// A basket asset for on-chain PPI computation (distinct from PlanetBasket's `Asset`).
struct CoreAsset {
    weight: int64       // ppm, 1e6 = 100%
    basePrice: int64    // 1e6, immutable once baseLocked
    currentPrice: int64 // 1e6
}

// Oracle state (OracleState, see oracle_state.tolk) lives in a ref cell so the main
// storage stays within TON's 1023-bit cell limit. The asset map is also a ref.
struct Storage {
    owner: address
    jettonMinter: address   // PLT Jetton minter (0 = unset)
    totalReserve: int64
    totalSupply: int64
    currentPpi: int64
    feesToBurn: int64       // accrued 45% bucket
    feesToReserve: int64    // accrued 30% bucket
    feesToStaking: int64    // accrued 25% bucket
    paused: bool
    assets: map<int64, CoreAsset>  // index -> asset (the basket)
    assetCount: int64
    baseLocked: bool               // base prices immutable once true
    oracleState: cell       // ref: OracleState { oracle, lastOracleUpdate }
    limitsState: cell       // ref: Limits { maxPerTx }
}

fun Storage.load() {
    return Storage.fromCell(contract.getData())
}

fun Storage.save(self) {
    contract.setData(self.toCell())
}

// ---------------- Messages ----------------

struct (0x10000001) Mint {
    queryId: int64
    amount: int64    // USDC (6 decimals)
}

struct (0x10000003) UpdatePrice {
    queryId: int64
    price: int64     // 1e6 fixed point (Phase 0 placeholder; oracle TBD)
}

struct (0x10000004) SetPaused {
    queryId: int64
    paused: bool
}

struct (0x10000005) SetJettonMinter {
    queryId: int64
    minter: address
}

struct (0x10000006) SetOracle {
    queryId: int64
    oracle: address
}

struct (0x10000009) SetBasketAsset {
    queryId: int64
    index: int64
    weight: int64     // ppm
    basePrice: int64  // 1e6
}

struct (0x1000000A) OracleUpdateAssetPrice {
    queryId: int64
    index: int64
    price: int64      // 1e6
    timestamp: int64  // strictly newer than the last oracle push
}

struct (0x1000000B) LockBasePrices {
    queryId: int64
}

struct (0x1000000E) SetLimits {
    queryId: int64
    maxPerTx: int64   // 0 = unlimited
}

type AllowedMessage = Mint | UpdatePrice | SetPaused | SetJettonMinter | SetOracle | BurnMirror | SetBasketAsset | OracleUpdateAssetPrice | LockBasePrices | SetLimits

// ---------------- Contract ABI ----------------

contract PlanetCore {
    storage: Storage
    incomingMessages: AllowedMessage
}

// ---------------- Pure math ----------------

// Minted = D * (1 - f) / PPI
// Intermediates widen to `int` (257-bit TVM) so large deposits don't overflow int64.
fun mintAmount(deposit: int64, ppi: int64): int64 {
    val net = (deposit as int) * (BPS_DENOM - FEE_BPS) / BPS_DENOM;
    return (net * PPI_SCALE / (ppi as int)) as int64;
}

// Received = B * PPI * (1 - f)
fun burnAmount(plt: int64, ppi: int64): int64 {
    val gross = (plt as int) * (ppi as int) / PPI_SCALE;
    return (gross * (BPS_DENOM - FEE_BPS) / BPS_DENOM) as int64;
}

// fee = amount * 0.5%
fun feeAmount(amount: int64): int64 {
    return ((amount as int) * FEE_BPS / BPS_DENOM) as int64;
}

// Split a fee into (burn 45%, reserve 30%, staking 25%-remainder).
// Remainder to staking avoids dust from integer division.
fun feeSplit(fee: int64): (int64, int64, int64) {
    val f = fee as int;
    val burn = (f * BURN_SHARE_BPS / BPS_DENOM) as int64;
    val reserve = (f * RESERVE_SHARE_BPS / BPS_DENOM) as int64;
    val staking = fee - burn - reserve;
    return (burn, reserve, staking);
}

// |a - b|
fun diffAbs(a: int64, b: int64): int64 {
    val d = a - b;
    if (d >= 0) {
        return d;
    }
    return -d;
}

// Band-based fee (stability): low friction near the peg, penalising away from it.
fun feeBpsForPpi(ppi: int64): int64 {
    val dev = diffAbs(ppi, PPI_SCALE);
    if (dev <= BAND_LOW) {
        return FEE_BPS;
    }
    if (dev <= BAND_HIGH) {
        return FEE_BPS_ELEVATED;
    }
    return FEE_BPS_HIGH;
}

fun feeAmountAtPpi(amount: int64, ppi: int64): int64 {
    return ((amount as int) * feeBpsForPpi(ppi) / BPS_DENOM) as int64;
}

// Minted = D * (1 - f(PPI)) / PPI   (band fee)
fun mintAmountAtPpi(deposit: int64, ppi: int64): int64 {
    val net = (deposit as int) * (BPS_DENOM - feeBpsForPpi(ppi)) / BPS_DENOM;
    return (net * PPI_SCALE / (ppi as int)) as int64;
}

// Received = B * PPI * (1 - f(PPI))   (band fee)
fun burnAmountAtPpi(plt: int64, ppi: int64): int64 {
    val gross = (plt as int) * (ppi as int) / PPI_SCALE;
    return (gross * (BPS_DENOM - feeBpsForPpi(ppi)) / BPS_DENOM) as int64;
}

// RTRA (real-time rebalancing algorithm) drift: ΔA_i = (w_i − V_i/ΣV) × T
// Returned as ppm of total reserve; positive = underweight (buy), negative = overweight (sell).
fun rebalanceDrift(weight: int64, positionValue: int64, totalReserve: int64): int64 {
    if (totalReserve == 0) {
        return weight;
    }
    val actual = ((positionValue as int) * WEIGHT_SCALE / (totalReserve as int)) as int64;
    return weight - actual;
}

// Trigger a rebalance for asset i when |drift| > 0.5%.
fun shouldRebalance(weight: int64, positionValue: int64, totalReserve: int64): bool {
    val drift = rebalanceDrift(weight, positionValue, totalReserve);
    return drift > REBALANCE_THRESHOLD || drift < -REBALANCE_THRESHOLD;
}

// Sum of all basket weights (ppm). Must equal WEIGHT_SCALE for a valid basket.
fun weightsSum(assets: map<int64, CoreAsset>, assetCount: int64): int64 {
    var sum: int = 0;
    var i: int = 0;
    while (i < assetCount as int) {
        sum += assets.mustGet(i as int64).weight as int;
        i += 1;
    }
    return sum as int64;
}

// On-chain PPI = Σ w_i · currentPrice_i / basePrice_i   (all 1e6 fixed point).
fun computePpi(assets: map<int64, CoreAsset>, assetCount: int64): int64 {
    var sum: int = 0;
    var i: int = 0;
    while (i < assetCount as int) {
        val a = assets.mustGet(i as int64);
        sum += (a.weight as int) * (a.currentPrice as int) / (a.basePrice as int);
        i += 1;
    }
    return sum as int64;
}

// ---------------- Message handling ----------------

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessage.fromSlice(in.body);
    match (msg) {
        Mint => { handleMint(in.senderAddress, in.valueCoins, msg); }
        UpdatePrice => { handleUpdatePrice(in.senderAddress, msg); }
        SetPaused => { handleSetPaused(in.senderAddress, msg); }
        SetJettonMinter => { handleSetJettonMinter(in.senderAddress, msg); }
        SetOracle => { handleSetOracle(in.senderAddress, msg); }
        BurnMirror => { handleBurnMirror(in.senderAddress, msg); }
        SetBasketAsset => { handleSetBasketAsset(in.senderAddress, msg); }
        OracleUpdateAssetPrice => { handleOracleUpdateAssetPrice(in.senderAddress, msg); }
        LockBasePrices => { handleLockBasePrices(in.senderAddress, msg); }
        SetLimits => { handleSetLimits(in.senderAddress, msg); }
        else => { assert (in.body.isEmpty()) throw 0xFFFF; }
    }
}

fun handleMint(sender: address, msgValue: coins, msg: Mint) {
    var storage = lazy Storage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    // stability: reject mint when PPI is far off peg (hard band), and enforce per-tx cap
    assert (diffAbs(storage.currentPpi, PPI_SCALE) <= BAND_FREEZE) throw ERR_DEVIATION;
    val lim = Limits.fromCell(storage.limitsState);
    assert (lim.maxPerTx == 0 || msg.amount <= lim.maxPerTx) throw ERR_LIMIT;
    val fee = feeAmountAtPpi(msg.amount, storage.currentPpi);
    val (feeBurn, feeReserve, feeStaking) = feeSplit(fee);
    storage.feesToBurn += feeBurn;
    storage.feesToReserve += feeReserve;
    storage.feesToStaking += feeStaking;
    val minted = mintAmountAtPpi(msg.amount, storage.currentPpi);
    storage.totalReserve += msg.amount;
    storage.totalSupply += minted;
    storage.save();

    // Ask the PLT Jetton minter to mint to the sender (empty forward payload).
    val step = InternalTransferStep {
        queryId: msg.queryId as uint64,
        jettonAmount: minted as coins,
        transferInitiator: null,
        sendExcessesTo: null,
        forwardTonAmount: 0,
        forwardPayload: beginCell().endCell().beginParse(),
    };
    val mintMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: storage.jettonMinter,
        value: msgValue,
        body: MintNewJettons {
            queryId: msg.queryId as uint64,
            mintRecipient: sender,
            tonAmount: MINT_FORWARD_TON,
            internalTransferMsg: step.toCell(),
        },
    });
    mintMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

// Mirrored burn: the PLT Jetton minter already burned `jettonAmount` from supply
// (via a wallet's AskToBurn). Core reduces its own accounting by the same amount and
// by the USD actually paid out (net of fee), keeping core in sync with the minter.
fun handleBurnMirror(sender: address, msg: BurnMirror) {
    var storage = lazy Storage.load();
    assert (sender == storage.jettonMinter) throw ERR_NOT_MINTER;
    assert (storage.totalSupply >= msg.jettonAmount) throw ERR_SUPPLY;
    val received = burnAmountAtPpi(msg.jettonAmount, storage.currentPpi);
    storage.totalSupply -= msg.jettonAmount;
    storage.totalReserve -= received;
    storage.save();
}

fun handleUpdatePrice(sender: address, msg: UpdatePrice) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.currentPpi = msg.price;
    storage.save();
}

fun handleSetPaused(sender: address, msg: SetPaused) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.paused = msg.paused;
    storage.save();
}

fun handleSetJettonMinter(sender: address, msg: SetJettonMinter) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.jettonMinter = msg.minter;
    storage.save();
}

// Owner designates the price oracle (e.g. the deployed RedStone adapter).
fun handleSetOracle(sender: address, msg: SetOracle) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    val os = OracleState.fromCell(storage.oracleState);
    storage.oracleState = OracleState {
        oracle: msg.oracle,
        lastOracleUpdate: os.lastOracleUpdate,
    }.toCell();
    storage.save();
}

// Owner configures one basket asset. The basket is frozen once base prices are locked.
fun handleSetBasketAsset(sender: address, msg: SetBasketAsset) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    assert (!storage.baseLocked) throw ERR_BASE_LOCKED;
    assert (msg.basePrice > 0) throw ERR_BAD_BASE;
    val asset: CoreAsset = {
        weight: msg.weight,
        basePrice: msg.basePrice,
        currentPrice: msg.basePrice,
    };
    storage.assets.set(msg.index, asset);
    if (msg.index >= storage.assetCount) {
        storage.assetCount = msg.index + 1;
    }
    storage.save();
}

// Owner freezes the basket (base prices become immutable).
fun handleLockBasePrices(sender: address, msg: LockBasePrices) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.baseLocked = true;
    storage.save();
}

// Owner sets the per-tx mint cap (0 = unlimited).
fun handleSetLimits(sender: address, msg: SetLimits) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.limitsState = Limits { maxPerTx: msg.maxPerTx }.toCell();
    storage.save();
}

// Only the registered oracle may push an asset price, only forward in time, and only
// when the basket is complete (weights sum to 100%). PPI is recomputed on-chain.
fun handleOracleUpdateAssetPrice(sender: address, msg: OracleUpdateAssetPrice) {
    var storage = lazy Storage.load();
    val os = OracleState.fromCell(storage.oracleState);
    assert (sender == os.oracle) throw ERR_NOT_ORACLE;
    assert (msg.timestamp > os.lastOracleUpdate) throw ERR_STALE_PRICE;
    assert (msg.index < storage.assetCount) throw ERR_BAD_INDEX;
    assert (weightsSum(storage.assets, storage.assetCount) == WEIGHT_SCALE) throw ERR_BAD_WEIGHTS;
    val a = storage.assets.mustGet(msg.index);
    storage.assets.set(msg.index, CoreAsset {
        weight: a.weight,
        basePrice: a.basePrice,
        currentPrice: msg.price,
    });
    storage.oracleState = OracleState {
        oracle: os.oracle,
        lastOracleUpdate: msg.timestamp,
    }.toCell();
    storage.currentPpi = computePpi(storage.assets, storage.assetCount);
    storage.save();
}

// ---------------- Getters ----------------

get fun reserve(): int64 {
    val storage = lazy Storage.load();
    return storage.totalReserve;
}

get fun supply(): int64 {
    val storage = lazy Storage.load();
    return storage.totalSupply;
}

get fun ppi(): int64 {
    val storage = lazy Storage.load();
    return storage.currentPpi;
}

get fun jettonMinter(): address {
    val storage = lazy Storage.load();
    return storage.jettonMinter;
}

get fun oracle(): address {
    val storage = lazy Storage.load();
    return OracleState.fromCell(storage.oracleState).oracle;
}

get fun lastOracleUpdate(): int64 {
    val storage = lazy Storage.load();
    return OracleState.fromCell(storage.oracleState).lastOracleUpdate;
}

get fun assetCount(): int64 {
    val storage = lazy Storage.load();
    return storage.assetCount;
}

// Throws if the index is not set.
get fun assetAt(index: int64): CoreAsset {
    val storage = lazy Storage.load();
    return storage.assets.mustGet(index);
}

get fun maxPerTx(): int64 {
    val storage = lazy Storage.load();
    return Limits.fromCell(storage.limitsState).maxPerTx;
}

get fun feesBurn(): int64 {
    val storage = lazy Storage.load();
    return storage.feesToBurn;
}

get fun feesReserve(): int64 {
    val storage = lazy Storage.load();
    return storage.feesToReserve;
}

get fun feesStaking(): int64 {
    val storage = lazy Storage.load();
    return storage.feesToStaking;
}
