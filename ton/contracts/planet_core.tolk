// PlanetCore.tolk — Planet on TON (Phase 0 skeleton, Tolk language)
//
// Compiled with the Acton toolchain (see ton/README.md). CI: .github/workflows/ton-build.yml
//
// Fixed-point integers only (1e6). No floats.

import "jetton/messages"
import "oracle_state"

const FEE_BPS = 50;          // 0.5% = 50 bps
const BPS_DENOM = 10000;
const PPI_SCALE = 1000000;   // 1.0 in 1e6 fixed point

const ERR_PAUSED = 100;
const ERR_NOT_OWNER = 101;
const ERR_SUPPLY = 102;
const ERR_NOT_ORACLE = 103;
const ERR_STALE_PRICE = 104;

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

// Oracle state (OracleState, see oracle_state.tolk) lives in a ref cell so the
// main storage stays within TON's 1023-bit cell limit (~919 bits used already).

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
    oracleState: cell       // ref: OracleState { oracle, lastOracleUpdate }
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

struct (0x10000002) Burn {
    queryId: int64
    amount: int64    // PLT (6 decimals)
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

struct (0x10000007) OracleUpdatePrice {
    queryId: int64
    price: int64     // 1e6 fixed point
    timestamp: int64 // must be strictly newer than the last oracle push
}

type AllowedMessage = Mint | Burn | UpdatePrice | SetPaused | SetJettonMinter | SetOracle | OracleUpdatePrice

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

// ---------------- Message handling ----------------

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessage.fromSlice(in.body);
    match (msg) {
        Mint => { handleMint(in.senderAddress, in.valueCoins, msg); }
        Burn => { handleBurn(msg); }
        UpdatePrice => { handleUpdatePrice(in.senderAddress, msg); }
        SetPaused => { handleSetPaused(in.senderAddress, msg); }
        SetJettonMinter => { handleSetJettonMinter(in.senderAddress, msg); }
        SetOracle => { handleSetOracle(in.senderAddress, msg); }
        OracleUpdatePrice => { handleOracleUpdatePrice(in.senderAddress, msg); }
        else => { assert (in.body.isEmpty()) throw 0xFFFF; }
    }
}

fun handleMint(sender: address, msgValue: coins, msg: Mint) {
    var storage = lazy Storage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    val fee = feeAmount(msg.amount);
    val (feeBurn, feeReserve, feeStaking) = feeSplit(fee);
    storage.feesToBurn += feeBurn;
    storage.feesToReserve += feeReserve;
    storage.feesToStaking += feeStaking;
    val minted = mintAmount(msg.amount, storage.currentPpi);
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

fun handleBurn(msg: Burn) {
    var storage = lazy Storage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    assert (storage.totalSupply >= msg.amount) throw ERR_SUPPLY;
    val received = burnAmount(msg.amount, storage.currentPpi);
    storage.totalSupply -= msg.amount;
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

// Only the registered oracle may push a price, and only forward in time
// (strictly increasing timestamp) to block replay of an old signed payload.
fun handleOracleUpdatePrice(sender: address, msg: OracleUpdatePrice) {
    var storage = lazy Storage.load();
    val os = OracleState.fromCell(storage.oracleState);
    assert (sender == os.oracle) throw ERR_NOT_ORACLE;
    assert (msg.timestamp > os.lastOracleUpdate) throw ERR_STALE_PRICE;
    storage.oracleState = OracleState {
        oracle: os.oracle,
        lastOracleUpdate: msg.timestamp,
    }.toCell();
    storage.currentPpi = msg.price;
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
