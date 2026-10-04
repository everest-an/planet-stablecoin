// PlanetCore.tolk — Planet on TON (Phase 0 skeleton, Tolk language)
//
// Compiled with the Acton toolchain (see ton/README.md). CI: .github/workflows/ton-build.yml
//
// Fixed-point integers only (1e6). No floats.

import "jetton/messages"
import "oracle_state"
import "burn_mirror"
import "limits"
import "signed_price"

const FEE_BPS = 50;          // 0.5% = 50 bps (near peg)
const FEE_BPS_ELEVATED = 100; // 1.0% when |PPI-1| in (3%, 5%]
const FEE_BPS_HIGH = 200;    // 2.0% when |PPI-1| > 5%
const BPS_DENOM = 10000;
const PPI_SCALE = 1000000;   // 1.0 in 1e6 fixed point
const BAND_LOW = 30000;      // 3%  deviation (ppm)
const BAND_HIGH = 50000;     // 5%  deviation
const BAND_FREEZE = 150000;  // 15% deviation -> hard mint freeze
const SLOPE_BPS = 1000;      // fee slope (bps per 100% deviation) beyond BAND_HIGH
const REDEEM_PENALTY_PPI = 970000; // below this PPI, redeem fee is penalised
const REDEEM_PENALTY_BPS = 100;    // extra redeem fee (bps) below REDEEM_PENALTY_PPI
const BAND_RICH = 1030000;         // PPI above this = index rich -> reward minting
const RISK_SHARE_BPS = 1000;       // 10% of each fee -> risk fund
const MAX_PRICE_JUMP_PPM = 500000; // reject a single price update that jumps >50%

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
const ERR_NOT_CAM = 112;
const ERR_NO_SIGNER = 113;
const ERR_BAD_SIG = 114;
const ERR_RISK_FUND = 115;
const ERR_PRICE_JUMP = 116;
const ERR_BAD_SIG2 = 117;

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
    volatility: int64   // 1e6 (CAM), 0 = unset
    liquidity: int64    // 0..1e6 (CAM), 0 = unset
    riskState: int64    // 0 normal / 1 caution / 2 frozen (CAM)
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
    cams: map<int64, address>      // index -> CAM adapter (0 = unset)
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

struct (0x1000000D) SetCam {
    queryId: int64
    index: int64
    cam: address
}

struct (0x1000000C) CamUpdate {
    queryId: int64
    index: int64
    price: int64       // 1e6
    volatility: int64  // 1e6
    liquidity: int64   // 0..1e6
    riskState: int64   // 0/1/2
    timestamp: int64
}

struct (0x1000000F) SetArb {
    queryId: int64
    rebateBps: int64   // mint-fee rebate when PPI > BAND_RICH (0 = off)
}

struct (0x10000012) CoverDeficit {
    queryId: int64
    amount: int64      // move this much from the risk fund into the reserve
}

struct (0x10000014) SetOwner {
    queryId: int64
    newOwner: address  // e.g. migrate to a TON multisig wallet
}

type AllowedMessage = Mint | UpdatePrice | SetPaused | SetJettonMinter | SetOracle | BurnMirror | SetBasketAsset | OracleUpdateAssetPrice | LockBasePrices | SetLimits | SetCam | CamUpdate | SetArb | SetSigner | SignedPriceUpdate | CoverDeficit | SetSigner2 | SetOwner

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

// Oracle tamper resistance: reject a single price update that jumps too far from the
// current price, limiting the damage one compromised update can do.
fun priceJumpOk(oldPrice: int64, newPrice: int64): bool {
    if (oldPrice == 0) {
        return true;
    }
    val jump = (diffAbs(newPrice, oldPrice) as int) * PPI_SCALE / (oldPrice as int);
    return jump <= MAX_PRICE_JUMP_PPM as int;
}

// Band-based fee (stability): low friction near the peg, steepening beyond BAND_HIGH.
fun feeBpsForPpi(ppi: int64): int64 {
    val dev = diffAbs(ppi, PPI_SCALE);
    if (dev <= BAND_LOW) {
        return FEE_BPS;
    }
    if (dev <= BAND_HIGH) {
        return FEE_BPS_ELEVATED;
    }
    val extra = (dev as int - BAND_HIGH as int) * SLOPE_BPS / PPI_SCALE;
    return (FEE_BPS_HIGH as int + extra) as int64;
}

// Redeem fee is asymmetric: penalised when PPI is far below peg (discourages exit
// during a down-depeg), on top of the band/slope fee.
fun burnFeeBpsForPpi(ppi: int64): int64 {
    var f = feeBpsForPpi(ppi) as int;
    if (ppi < REDEEM_PENALTY_PPI) {
        f += REDEEM_PENALTY_BPS;
    }
    return f as int64;
}

fun feeAmountAtPpi(amount: int64, ppi: int64): int64 {
    return ((amount as int) * feeBpsForPpi(ppi) / BPS_DENOM) as int64;
}

// Minted = D * (1 - f(PPI)) / PPI   (band fee)
fun mintAmountAtPpi(deposit: int64, ppi: int64): int64 {
    val net = (deposit as int) * (BPS_DENOM - feeBpsForPpi(ppi)) / BPS_DENOM;
    return (net * PPI_SCALE / (ppi as int)) as int64;
}

// Received = B * PPI * (1 - f(PPI))   (band + asymmetric redeem fee)
fun burnAmountAtPpi(plt: int64, ppi: int64): int64 {
    val gross = (plt as int) * (ppi as int) / PPI_SCALE;
    return (gross * (BPS_DENOM - burnFeeBpsForPpi(ppi)) / BPS_DENOM) as int64;
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

// Risk-aware rebalance trigger (CAM inputs). frozen -> never; volatility/illiquidity
// widen the effective threshold; caution widens further.
fun shouldRebalanceRisk(
    weight: int64, positionValue: int64, totalReserve: int64,
    volatility: int64, liquidity: int64, riskState: int64,
): bool {
    if (riskState == 2) {
        return false;
    }
    val adrift = diffAbs(rebalanceDrift(weight, positionValue, totalReserve), 0);
    var thresh: int = REBALANCE_THRESHOLD as int;
    if (volatility > 0) {
        thresh = thresh * (PPI_SCALE + volatility as int) / PPI_SCALE;
    }
    if (liquidity > 0 && liquidity < PPI_SCALE) {
        thresh = thresh * PPI_SCALE / (liquidity as int);
    }
    if (riskState == 1) {
        thresh = thresh * 2;
    }
    val t: int64 = thresh as int64;
    return adrift > t;
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

// On-chain PPI over ACTIVE (non-frozen) assets, renormalised by their weights:
//   PPI = Σ_active w_i·(P_i/Pb_i) / Σ_active w_i
// Frozen assets (riskState == 2) are excluded so a bad feed cannot pollute the index;
// with nothing frozen this reduces to the plain weighted index.
fun computePpi(assets: map<int64, CoreAsset>, assetCount: int64): int64 {
    var num: int = 0;   // Σ_active w_i·(P_i/Pb_i)
    var den: int = 0;   // Σ_active w_i
    var i: int = 0;
    while (i < assetCount as int) {
        val a = assets.mustGet(i as int64);
        if (a.riskState != 2) {
            num += (a.weight as int) * (a.currentPrice as int) / (a.basePrice as int);
            den += a.weight as int;
        }
        i += 1;
    }
    if (den == 0) {
        return PPI_SCALE;   // all assets frozen: fall back to 1.0
    }
    return (num * PPI_SCALE / den) as int64;
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
        SetCam => { handleSetCam(in.senderAddress, msg); }
        CamUpdate => { handleCamUpdate(in.senderAddress, msg); }
        SetArb => { handleSetArb(in.senderAddress, msg); }
        SetSigner => { handleSetSigner(in.senderAddress, msg); }
        SignedPriceUpdate => { handleSignedPriceUpdate(msg); }
        CoverDeficit => { handleCoverDeficit(in.senderAddress, msg); }
        SetSigner2 => { handleSetSigner2(in.senderAddress, msg); }
        SetOwner => { handleSetOwner(in.senderAddress, msg); }
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
    // arbitrage incentive: rebate the mint fee when the index is rich (PPI > BAND_RICH)
    var rebate: int64 = 0;
    if (lim.arbRebateBps > 0 && storage.currentPpi > BAND_RICH) {
        rebate = lim.arbRebateBps;
    }
    var effBps: int64 = feeBpsForPpi(storage.currentPpi) - rebate;
    if (effBps < 0) {
        effBps = 0;
    }
    val fee = ((msg.amount as int) * effBps / BPS_DENOM) as int64;
    val (feeBurn, feeReserve, feeStaking) = feeSplit(fee);
    // divert part of the fee into the risk fund (from the reserve bucket)
    val riskShare = ((fee as int) * RISK_SHARE_BPS / BPS_DENOM) as int64;
    storage.feesToBurn += feeBurn;
    storage.feesToReserve += (feeReserve - riskShare);
    storage.feesToStaking += feeStaking;
    storage.limitsState = Limits {
        maxPerTx: lim.maxPerTx,
        arbRebateBps: lim.arbRebateBps,
        riskFund: lim.riskFund + riskShare,
    }.toCell();
    val net = (msg.amount as int) * (BPS_DENOM as int - effBps as int) / BPS_DENOM;
    val minted = (net * PPI_SCALE / (storage.currentPpi as int)) as int64;
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
        signerKey: os.signerKey,
        signerKey2: os.signerKey2,
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
        volatility: 0,
        liquidity: 0,
        riskState: 0,
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
    val lim = Limits.fromCell(storage.limitsState);
    storage.limitsState = Limits { maxPerTx: msg.maxPerTx, arbRebateBps: lim.arbRebateBps, riskFund: lim.riskFund }.toCell();
    storage.save();
}

// Owner sets the arbitrage mint-fee rebate (0 = off).
fun handleSetArb(sender: address, msg: SetArb) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    val lim = Limits.fromCell(storage.limitsState);
    storage.limitsState = Limits {
        maxPerTx: lim.maxPerTx,
        arbRebateBps: msg.rebateBps,
        riskFund: lim.riskFund,
    }.toCell();
    storage.save();
}

// Owner sets the oracle signer public key (0 = disable signed updates).
fun handleSetSigner(sender: address, msg: SetSigner) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    val os = OracleState.fromCell(storage.oracleState);
    storage.oracleState = OracleState {
        oracle: os.oracle,
        signerKey: msg.key,
        signerKey2: os.signerKey2,
        lastOracleUpdate: os.lastOracleUpdate,
    }.toCell();
    storage.save();
}

// Owner sets the optional SECOND signer key; while set, signed updates need both.
fun handleSetSigner2(sender: address, msg: SetSigner2) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    val os = OracleState.fromCell(storage.oracleState);
    storage.oracleState = OracleState {
        oracle: os.oracle,
        signerKey: os.signerKey,
        signerKey2: msg.key,
        lastOracleUpdate: os.lastOracleUpdate,
    }.toCell();
    storage.save();
}

// Owner transfers ownership (e.g. migrate `owner` to a TON multisig wallet).
fun handleSetOwner(sender: address, msg: SetOwner) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.owner = msg.newOwner;
    storage.save();
}

// Anyone may relay a signed price update; authenticity comes from the signature
// (verified against the registered signer key), not from the sender.
fun handleSignedPriceUpdate(msg: SignedPriceUpdate) {
    var storage = lazy Storage.load();
    val os = OracleState.fromCell(storage.oracleState);
    assert (os.signerKey != 0) throw ERR_NO_SIGNER;
    assert (isSignatureValid(msg.payload.hash(), msg.sig1.beginParse(), os.signerKey)) throw ERR_BAD_SIG;
    if (os.signerKey2 != 0) {
        assert (isSignatureValid(msg.payload.hash(), msg.sig2.beginParse(), os.signerKey2)) throw ERR_BAD_SIG2;
    }
    val p = PricePayload.fromCell(msg.payload);
    assert (p.timestamp > os.lastOracleUpdate) throw ERR_STALE_PRICE;
    assert (p.index < storage.assetCount) throw ERR_BAD_INDEX;
    assert (weightsSum(storage.assets, storage.assetCount) == WEIGHT_SCALE) throw ERR_BAD_WEIGHTS;
    val a = storage.assets.mustGet(p.index);
    assert (priceJumpOk(a.currentPrice, p.price)) throw ERR_PRICE_JUMP;
    storage.assets.set(p.index, CoreAsset {
        weight: a.weight,
        basePrice: a.basePrice,
        currentPrice: p.price,
        volatility: p.volatility,
        liquidity: p.liquidity,
        riskState: p.riskState,
    });
    storage.oracleState = OracleState {
        oracle: os.oracle,
        signerKey: os.signerKey,
        signerKey2: os.signerKey2,
        lastOracleUpdate: p.timestamp,
    }.toCell();
    storage.currentPpi = computePpi(storage.assets, storage.assetCount);
    storage.save();
}

// Owner uses the risk fund to top up the reserve (covers a deficit).
fun handleCoverDeficit(sender: address, msg: CoverDeficit) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    val lim = Limits.fromCell(storage.limitsState);
    assert (lim.riskFund >= msg.amount) throw ERR_RISK_FUND;
    storage.limitsState = Limits {
        maxPerTx: lim.maxPerTx,
        arbRebateBps: lim.arbRebateBps,
        riskFund: lim.riskFund - msg.amount,
    }.toCell();
    storage.totalReserve += msg.amount;
    storage.save();
}

// Owner registers the CAM adapter for a basket index.
fun handleSetCam(sender: address, msg: SetCam) {
    var storage = lazy Storage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.cams.set(msg.index, msg.cam);
    storage.save();
}

// A registered CAM pushes standardized data (price/volatility/liquidity/risk).
// Timestamp is monotonic; the basket must be complete. PPI is recomputed on-chain.
fun handleCamUpdate(sender: address, msg: CamUpdate) {
    var storage = lazy Storage.load();
    val os = OracleState.fromCell(storage.oracleState);
    assert (sender == storage.cams.mustGet(msg.index)) throw ERR_NOT_CAM;
    assert (msg.timestamp > os.lastOracleUpdate) throw ERR_STALE_PRICE;
    assert (msg.index < storage.assetCount) throw ERR_BAD_INDEX;
    assert (weightsSum(storage.assets, storage.assetCount) == WEIGHT_SCALE) throw ERR_BAD_WEIGHTS;
    val a = storage.assets.mustGet(msg.index);
    assert (priceJumpOk(a.currentPrice, msg.price)) throw ERR_PRICE_JUMP;
    storage.assets.set(msg.index, CoreAsset {
        weight: a.weight,
        basePrice: a.basePrice,
        currentPrice: msg.price,
        volatility: msg.volatility,
        liquidity: msg.liquidity,
        riskState: msg.riskState,
    });
    storage.oracleState = OracleState {
        oracle: os.oracle,
        signerKey: os.signerKey,
        signerKey2: os.signerKey2,
        lastOracleUpdate: msg.timestamp,
    }.toCell();
    storage.currentPpi = computePpi(storage.assets, storage.assetCount);
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
    assert (priceJumpOk(a.currentPrice, msg.price)) throw ERR_PRICE_JUMP;
    storage.assets.set(msg.index, CoreAsset {
        weight: a.weight,
        basePrice: a.basePrice,
        currentPrice: msg.price,
        volatility: a.volatility,
        liquidity: a.liquidity,
        riskState: a.riskState,
    });
    storage.oracleState = OracleState {
        oracle: os.oracle,
        signerKey: os.signerKey,
        signerKey2: os.signerKey2,
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

get fun owner(): address {
    val storage = lazy Storage.load();
    return storage.owner;
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

get fun camAt(index: int64): address {
    val storage = lazy Storage.load();
    return storage.cams.mustGet(index);
}

get fun maxPerTx(): int64 {
    val storage = lazy Storage.load();
    return Limits.fromCell(storage.limitsState).maxPerTx;
}

get fun arbRebateBps(): int64 {
    val storage = lazy Storage.load();
    return Limits.fromCell(storage.limitsState).arbRebateBps;
}

get fun signerKey(): uint256 {
    val storage = lazy Storage.load();
    return OracleState.fromCell(storage.oracleState).signerKey;
}

get fun signerKey2(): uint256 {
    val storage = lazy Storage.load();
    return OracleState.fromCell(storage.oracleState).signerKey2;
}

get fun riskFund(): int64 {
    val storage = lazy Storage.load();
    return Limits.fromCell(storage.limitsState).riskFund;
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
