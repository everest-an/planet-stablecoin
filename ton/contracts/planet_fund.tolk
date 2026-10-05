// PlanetFund.tolk — tokenized ETF fund (Phase 2 skeleton).
//
// The REAL product: a user subscribes with USD -> the operator buys a real ETF basket
// and custodies it -> a custodian key set (M-of-N) confirms the purchase -> the fund
// mints PLT shares at NAV (net of the subscription fee). Redemption is the mirror.
//
// Invariants (fixing the Phase-1 findings):
//  - NEVER mint on a user's Subscribe alone (fixes EC1: no unbacked minting). Shares are
//    minted ONLY on a custodian-confirmed ConfirmMint.
//  - NAV is custodian-attested, monotonic in time, jump-guarded and floored.
//  - Owner actions (fees/custodian/KYC/pause) are owner-gated; ownership can migrate to a
//    multisig + timelock (reuse PlanetTimelock).
//
// See docs/fund-contract-design.md, docs/positioning-v2.md.

import "jetton/messages"

const FUND_DOMAIN = 0x46554E44; // "FUND" — domain tag for custodian signatures

const NAV_SCALE = 1000000;      // 1e6 = 1.0 NAV per share
const BPS_DENOM = 10000;
const MIN_NAV = 1000;           // 0.001 floor
const MAX_NAV_JUMP_BPS = 2000;  // reject an attestation that moves NAV > 20%
const MINT_FORWARD_TON = ton("0.05");

const ERR_NOT_OWNER = 201;
const ERR_PAUSED = 202;
const ERR_NO_ORDER = 203;
const ERR_ORDER_DONE = 204;
const ERR_BAD_CUSTODIAN_SIG = 205;
const ERR_NO_CUSTODIAN = 206;
const ERR_BAD_NAV = 207;
const ERR_NAV_JUMP = 208;
const ERR_STALE = 209;
const ERR_KYC = 210;
const ERR_BAD_AMOUNT = 211;
const ERR_BAD_THRESHOLD = 212;
const ERR_NOT_FUND_WALLET = 213; // share notification not from the fund's own jetton wallet
const ERR_NOT_FUNDED = 214;      // redeem must be funded with shares before payout

// ---------------- Storage ----------------

struct Order {
    user: address
    usd: int64
    ts: int64
    done: bool
}

// A redemption request: the subscriber's shares are (off-chain, by the operator) moved
// into the fund; the custodian confirms the ETF sale, then the fund records the payout.
struct Redeem {
    user: address
    shares: int64
    payout: int64
    ts: int64
    done: bool
    funded: bool   // set once the shares have been received into the fund's wallet (TEP-74)
}

// Both order maps live inside ONE cell so FundStorage stays within TON's 4-ref limit
// (freeing a ref for `fundWallet`).
struct OrdersStore {
    mints: map<int64, Order>
    redeems: map<int64, Redeem>
}

struct FundStorage {
    owner: address
    jettonMinter: address
    fundWallet: cell       // address of the fund's OWN PLT jetton wallet (parsed on share receipt)
    navPerShare: int64
    lastNavUpdate: int64
    mgmtFeeBps: int64      // annual management fee (accrued inside the attested NAV)
    mintFeeBps: int64      // subscription spread (charged on-chain)
    redeemFeeBps: int64    // redemption spread (charged on-chain)
    paused: bool
    kycRequired: bool
    allowed: map<address, bool>
    custodianCount: int64
    custodianThreshold: int64
    custodians: map<int64, uint256>
    ordersStore: cell      // OrdersStore{mints, redeems}
}

fun FundStorage.load() {
    return FundStorage.fromCell(contract.getData())
}

fun FundStorage.save(self) {
    contract.setData(self.toCell())
}

// The fund's own PLT jetton wallet address lives in its own cell so FundStorage stays
// within TON's 4-ref limit; wrapped in a struct so it round-trips via fromCell/toCell.
struct FundWalletRef {
    addr: address
}

fun loadFundWallet(st: FundStorage): address {
    return FundWalletRef.fromCell(st.fundWallet).addr;
}

// ---------------- Messages ----------------

struct (0x30000001) Subscribe {
    queryId: int64
    usd: int64        // USDC (6 decimals) the user is subscribing
}

// Custodian-confirmed mint. `sigs` = uint8 count + count refs (one 512-bit sig each),
// each over confirmHash(orderId, navPerShare, timestamp).
struct (0x30000002) ConfirmMint {
    queryId: int64
    orderId: int64
    navPerShare: int64
    timestamp: int64
    sigs: cell
}

struct (0x30000003) CancelOrder {
    queryId: int64
    orderId: int64
}

struct (0x30000004) AttestNav {
    queryId: int64
    navPerShare: int64
    timestamp: int64
    sigs: cell
}

struct (0x30000005) SetFees {
    queryId: int64
    mgmtBps: int64
    mintBps: int64
    redeemBps: int64
}

struct (0x30000006) SetCustodian {
    queryId: int64
    index: int64
    key: uint256
}

struct (0x30000007) SetCustodianThreshold {
    queryId: int64
    m: int64
}

struct (0x30000008) SetPaused {
    queryId: int64
    paused: bool
}

struct (0x30000009) SetKyc {
    queryId: int64
    required: bool
}

struct (0x3000000A) Allow {
    queryId: int64
    addr: address
    ok: bool
}

struct (0x3000000B) SetJettonMinter {
    queryId: int64
    minter: address
}

struct (0x10000014) SetOwner {
    queryId: int64
    newOwner: address
}

// Redemption: the subscriber asks to exit; the custodian confirms the ETF sale.
struct (0x3000000C) RequestRedeem {
    queryId: int64
    shares: int64
}

struct (0x3000000D) ConfirmRedeem {
    queryId: int64
    orderId: int64
    navPerShare: int64
    timestamp: int64
    sigs: cell
}

struct (0x3000000E) CancelRedeem {
    queryId: int64
    orderId: int64
}

struct (0x30000010) SetFundWallet {
    queryId: int64
    wallet: address
}

type FundMessage = Subscribe | ConfirmMint | CancelOrder | AttestNav | SetFees | SetCustodian |
    SetCustodianThreshold | SetPaused | SetKyc | Allow | SetJettonMinter | SetOwner |
    RequestRedeem | ConfirmRedeem | CancelRedeem | SetFundWallet | TransferNotificationForRecipient

contract PlanetFund {
    storage: FundStorage
    incomingMessages: FundMessage
}

// ---------------- Signature helpers ----------------

// Domain-separated confirmation hash: prevents cross-deployment replay.
fun confirmHash(orderId: int64, navPerShare: int64, timestamp: int64): uint256 {
    return beginCell()
        .storeUint(FUND_DOMAIN, 32)
        .storeAddress(contract.getAddress())
        .storeInt(orderId, 64)
        .storeInt(navPerShare, 64)
        .storeInt(timestamp, 64)
        .endCell()
        .hash();
}

// Walk the count+refs signature list; require >= threshold DISTINCT valid custodians.
fun verifyCustodians(os: FundStorage, hash: uint256, sigs: cell): bool {
    if (os.custodianCount == 0) {
        return false;
    }
    var sp = sigs.beginParse();
    val n = sp.loadUint(8);
    var usedMask: int = 0;
    var matched: int = 0;
    var k: int = 0;
    while (k < n) {
        val sig = sp.loadRef().beginParse();
        var j: int = 0;
        var found: bool = false;
        while (j < os.custodianCount as int && !found) {
            val lk = os.custodians.get(j as int64);
            if (((usedMask >> j) & 1) == 0 && lk.isFound && isSignatureValid(hash, sig, lk.loadValue())) {
                usedMask = usedMask | (1 << j);
                matched += 1;
                found = true;
            }
            j += 1;
        }
        k += 1;
    }
    return matched >= os.custodianThreshold as int;
}

// ---------------- Handling ----------------

fun onInternalMessage(in: InMessage) {
    val msg = lazy FundMessage.fromSlice(in.body);
    match (msg) {
        Subscribe => { handleSubscribe(in.senderAddress, msg); }
        ConfirmMint => { handleConfirmMint(in.valueCoins, msg); }
        CancelOrder => { handleCancelOrder(in.senderAddress, msg); }
        AttestNav => { handleAttestNav(msg); }
        SetFees => { handleSetFees(in.senderAddress, msg); }
        SetCustodian => { handleSetCustodian(in.senderAddress, msg); }
        SetCustodianThreshold => { handleSetCustodianThreshold(in.senderAddress, msg); }
        SetPaused => { handleSetPaused(in.senderAddress, msg); }
        SetKyc => { handleSetKyc(in.senderAddress, msg); }
        Allow => { handleAllow(in.senderAddress, msg); }
        SetJettonMinter => { handleSetJettonMinter(in.senderAddress, msg); }
        SetOwner => { handleSetOwner(in.senderAddress, msg); }
        RequestRedeem => { handleRequestRedeem(in.senderAddress, msg); }
        ConfirmRedeem => { handleConfirmRedeem(in.valueCoins, msg); }
        CancelRedeem => { handleCancelRedeem(in.senderAddress, msg); }
        SetFundWallet => { handleSetFundWallet(in.senderAddress, msg); }
        TransferNotificationForRecipient => { handleShareReceived(in.senderAddress, msg); }
        else => { assert (in.body.isEmpty()) throw 0xFFFF; }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();
}

// User registers a subscription. NO minting here — shares are minted only on ConfirmMint.
fun handleSubscribe(sender: address, msg: Subscribe) {
    var storage = lazy FundStorage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    assert (msg.usd > 0) throw ERR_BAD_AMOUNT;
    if (storage.kycRequired) {
        val lk = storage.allowed.get(sender);
        assert (lk.isFound && lk.loadValue()) throw ERR_KYC;
    }
    var osSub = OrdersStore.fromCell(storage.ordersStore);
    var orders = osSub.mints;
    orders.set(msg.queryId, Order { user: sender, usd: msg.usd, ts: blockchain.now() as int64, done: false });
    storage.ordersStore = OrdersStore { mints: orders, redeems: osSub.redeems }.toCell();
    storage.save();
}

// Custodian (M-of-N) confirms the ETF purchase -> mint shares at NAV net of the mint fee.
fun handleConfirmMint(msgValue: coins, msg: ConfirmMint) {
    var storage = lazy FundStorage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    assert (storage.custodianCount > 0) throw ERR_NO_CUSTODIAN;
    assert (verifyCustodians(storage, confirmHash(msg.orderId, msg.navPerShare, msg.timestamp), msg.sigs)) throw ERR_BAD_CUSTODIAN_SIG;
    assert (msg.timestamp > storage.lastNavUpdate) throw ERR_STALE;
    assert (msg.navPerShare >= MIN_NAV) throw ERR_BAD_NAV;

    val lk = OrdersStore.fromCell(storage.ordersStore).mints.get(msg.orderId);
    assert (lk.isFound) throw ERR_NO_ORDER;
    val order = lk.loadValue();
    assert (!order.done) throw ERR_ORDER_DONE;

    // NAV jump guard (only when a previous NAV exists).
    if (storage.navPerShare > 0 && navJumpOk(storage.navPerShare, msg.navPerShare) == false) {
        throw ERR_NAV_JUMP;
    }

    val shares = (order.usd as int) * NAV_SCALE / (msg.navPerShare as int) * (BPS_DENOM - storage.mintFeeBps as int) / BPS_DENOM;
    var osMint = OrdersStore.fromCell(storage.ordersStore);
    var mints = osMint.mints;
    mints.set(msg.orderId, Order { user: order.user, usd: order.usd, ts: order.ts, done: true });
    storage.ordersStore = OrdersStore { mints: mints, redeems: osMint.redeems }.toCell();
    storage.navPerShare = msg.navPerShare;
    storage.lastNavUpdate = msg.timestamp;
    storage.save();

    // Mint PLT shares to the user via the jetton minter (admin must be this fund).
    val step = InternalTransferStep {
        queryId: msg.queryId as uint64,
        jettonAmount: shares as coins,
        transferInitiator: null,
        sendExcessesTo: null,
        forwardTonAmount: 0,
        forwardPayload: beginCell().endCell().beginParse(),
    };
    val m = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: storage.jettonMinter,
        value: msgValue,
        body: MintNewJettons {
            queryId: msg.queryId as uint64,
            mintRecipient: order.user,
            tonAmount: MINT_FORWARD_TON,
            internalTransferMsg: step.toCell(),
        },
    });
    m.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

// NAV attestation by the custodian set (M-of-N): monotonic, floored, jump-guarded.
fun handleAttestNav(msg: AttestNav) {
    var storage = lazy FundStorage.load();
    assert (storage.custodianCount > 0) throw ERR_NO_CUSTODIAN;
    assert (verifyCustodians(storage, confirmHash(0, msg.navPerShare, msg.timestamp), msg.sigs)) throw ERR_BAD_CUSTODIAN_SIG;
    assert (msg.timestamp > storage.lastNavUpdate) throw ERR_STALE;
    assert (msg.navPerShare >= MIN_NAV) throw ERR_BAD_NAV;
    if (storage.navPerShare > 0 && navJumpOk(storage.navPerShare, msg.navPerShare) == false) {
        throw ERR_NAV_JUMP;
    }
    storage.navPerShare = msg.navPerShare;
    storage.lastNavUpdate = msg.timestamp;
    storage.save();
}

// The subscriber (or owner) can cancel an unconfirmed order.
fun handleCancelOrder(sender: address, msg: CancelOrder) {
    var storage = lazy FundStorage.load();
    val lk = OrdersStore.fromCell(storage.ordersStore).mints.get(msg.orderId);
    assert (lk.isFound) throw ERR_NO_ORDER;
    val order = lk.loadValue();
    assert (!order.done) throw ERR_ORDER_DONE;
    assert (sender == order.user || sender == storage.owner) throw ERR_NOT_OWNER;
    var osCancel = OrdersStore.fromCell(storage.ordersStore);
    var mints2 = osCancel.mints;
    mints2.set(msg.orderId, Order { user: order.user, usd: order.usd, ts: order.ts, done: true });
    storage.ordersStore = OrdersStore { mints: mints2, redeems: osCancel.redeems }.toCell();
    storage.save();
}

fun handleSetFees(sender: address, msg: SetFees) {
    var storage = lazy FundStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    assert (msg.mintBps <= BPS_DENOM && msg.redeemBps <= BPS_DENOM) throw ERR_BAD_AMOUNT;
    storage.mgmtFeeBps = msg.mgmtBps;
    storage.mintFeeBps = msg.mintBps;
    storage.redeemFeeBps = msg.redeemBps;
    storage.save();
}

fun handleSetCustodian(sender: address, msg: SetCustodian) {
    var storage = lazy FundStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.custodians.set(msg.index, msg.key);
    if (msg.index >= storage.custodianCount) {
        storage.custodianCount = msg.index + 1;
    }
    storage.save();
}

fun handleSetCustodianThreshold(sender: address, msg: SetCustodianThreshold) {
    var storage = lazy FundStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    assert (msg.m >= 1 && msg.m <= storage.custodianCount) throw ERR_BAD_THRESHOLD;
    storage.custodianThreshold = msg.m;
    storage.save();
}

fun handleSetPaused(sender: address, msg: SetPaused) {
    var storage = lazy FundStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.paused = msg.paused;
    storage.save();
}

fun handleSetKyc(sender: address, msg: SetKyc) {
    var storage = lazy FundStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.kycRequired = msg.required;
    storage.save();
}

fun handleAllow(sender: address, msg: Allow) {
    var storage = lazy FundStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.allowed.set(msg.addr, msg.ok);
    storage.save();
}

fun handleSetJettonMinter(sender: address, msg: SetJettonMinter) {
    var storage = lazy FundStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.jettonMinter = msg.minter;
    storage.save();
}

fun handleSetOwner(sender: address, msg: SetOwner) {
    var storage = lazy FundStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    val (wc, h) = msg.newOwner.getWorkchainAndHash();
    assert (!(wc == 0 && h == 0)) throw ERR_NOT_OWNER;
    storage.owner = msg.newOwner;
    storage.save();
}

// ---------------- Redemption ----------------

// The subscriber registers a redemption request. The operator moves the shares into
// the fund; the custodian confirms the ETF sale, and the fund records the payout.
fun handleRequestRedeem(sender: address, msg: RequestRedeem) {
    var storage = lazy FundStorage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    assert (msg.shares > 0) throw ERR_BAD_AMOUNT;
    if (storage.kycRequired) {
        val lk = storage.allowed.get(sender);
        assert (lk.isFound && lk.loadValue()) throw ERR_KYC;
    }
    var osReq = OrdersStore.fromCell(storage.ordersStore);
    var redeemsReq = osReq.redeems;
    redeemsReq.set(msg.queryId, Redeem { user: sender, shares: msg.shares, payout: 0, ts: blockchain.now() as int64, done: false, funded: false });
    storage.ordersStore = OrdersStore { mints: osReq.mints, redeems: redeemsReq }.toCell();
    storage.save();
}

fun handleConfirmRedeem(msgValue: coins, msg: ConfirmRedeem) {
    var storage = lazy FundStorage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    assert (storage.custodianCount > 0) throw ERR_NO_CUSTODIAN;
    assert (verifyCustodians(storage, confirmHash(msg.orderId, msg.navPerShare, msg.timestamp), msg.sigs)) throw ERR_BAD_CUSTODIAN_SIG;
    assert (msg.timestamp > storage.lastNavUpdate) throw ERR_STALE;
    assert (msg.navPerShare >= MIN_NAV) throw ERR_BAD_NAV;

    val lk = OrdersStore.fromCell(storage.ordersStore).redeems.get(msg.orderId);
    assert (lk.isFound) throw ERR_NO_ORDER;
    val r = lk.loadValue();
    assert (!r.done) throw ERR_ORDER_DONE;
    assert (r.funded) throw ERR_NOT_FUNDED;

    if (storage.navPerShare > 0 && navJumpOk(storage.navPerShare, msg.navPerShare) == false) {
        throw ERR_NAV_JUMP;
    }

    val payout = ((r.shares as int) * (msg.navPerShare as int) / NAV_SCALE) * (BPS_DENOM - storage.redeemFeeBps as int) / BPS_DENOM;
    var osConf = OrdersStore.fromCell(storage.ordersStore);
    var redeemsConf = osConf.redeems;
    redeemsConf.set(msg.orderId, Redeem { user: r.user, shares: r.shares, payout: payout as int64, ts: r.ts, done: true, funded: true });
    storage.ordersStore = OrdersStore { mints: osConf.mints, redeems: redeemsConf }.toCell();
    storage.navPerShare = msg.navPerShare;
    storage.lastNavUpdate = msg.timestamp;
    storage.save();

    // Pay the subscriber (carries the attached value; real payout rails handled off-chain).
    val pay = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: r.user,
        body: beginCell().storeUint(0x3000000F, 32).storeInt(payout as int64, 64).endCell(),
    });
    pay.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

fun handleCancelRedeem(sender: address, msg: CancelRedeem) {
    var storage = lazy FundStorage.load();
    val lk = OrdersStore.fromCell(storage.ordersStore).redeems.get(msg.orderId);
    assert (lk.isFound) throw ERR_NO_ORDER;
    val r = lk.loadValue();
    assert (!r.done) throw ERR_ORDER_DONE;
    assert (sender == r.user || sender == storage.owner) throw ERR_NOT_OWNER;
    var osCR = OrdersStore.fromCell(storage.ordersStore);
    var redeemsCR = osCR.redeems;
    redeemsCR.set(msg.orderId, Redeem { user: r.user, shares: r.shares, payout: r.payout, ts: r.ts, done: true, funded: r.funded });
    storage.ordersStore = OrdersStore { mints: osCR.mints, redeems: redeemsCR }.toCell();
    storage.save();
}

// ---------------- TEP-74 share receipt (trustless redemption) ----------------

// The fund's own PLT jetton wallet reports received shares. The subscriber transfers PLT into
// the fund with queryId == their redeem orderId; we mark that redeem funded and burn the shares,
// so a payout can only happen after the shares have actually left the subscriber.
fun handleShareReceived(sender: address, msg: TransferNotificationForRecipient) {
    var storage = lazy FundStorage.load();
    val fw = loadFundWallet(storage);
    assert (sender == fw) throw ERR_NOT_FUND_WALLET;

    val orderId = msg.queryId as int64;
    val osIn = OrdersStore.fromCell(storage.ordersStore);
    val lk = osIn.redeems.get(orderId);
    assert (lk.isFound) throw ERR_NO_ORDER;
    val r = lk.loadValue();
    assert (!r.done) throw ERR_ORDER_DONE;
    assert ((msg.jettonAmount as int) >= (r.shares as int)) throw ERR_BAD_AMOUNT;

    var redeemsIn = osIn.redeems;
    redeemsIn.set(orderId, Redeem { user: r.user, shares: r.shares, payout: r.payout, ts: r.ts, done: false, funded: true });
    storage.ordersStore = OrdersStore { mints: osIn.mints, redeems: redeemsIn }.toCell();
    storage.save();

    // Burn the received shares (carry the attached value along to the wallet).
    val burn = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: fw,
        body: AskToBurn {
            queryId: msg.queryId,
            jettonAmount: msg.jettonAmount,
            sendExcessesTo: null,
            customPayload: null,
        },
    });
    burn.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

fun handleSetFundWallet(sender: address, msg: SetFundWallet) {
    var storage = lazy FundStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.fundWallet = FundWalletRef { addr: msg.wallet }.toCell();
    storage.save();
}

// ---------------- Pure math ----------------

// NAV jump guard: reject a single attestation that moves NAV by more than the cap.
fun navJumpOk(oldNav: int64, newNav: int64): bool {
    if (oldNav == 0) {
        return true;
    }
    val diff = oldNav - newNav;
    var adiff = diff;
    if (diff < 0) {
        adiff = -diff;
    }
    val jump = (adiff as int) * BPS_DENOM / (oldNav as int);
    return jump <= MAX_NAV_JUMP_BPS as int;
}

// ---------------- Getters ----------------

get fun owner(): address {
    val storage = lazy FundStorage.load();
    return storage.owner;
}

get fun navPerShare(): int64 {
    val storage = lazy FundStorage.load();
    return storage.navPerShare;
}

get fun lastNavUpdate(): int64 {
    val storage = lazy FundStorage.load();
    return storage.lastNavUpdate;
}

get fun mgmtFeeBps(): int64 {
    val storage = lazy FundStorage.load();
    return storage.mgmtFeeBps;
}

get fun mintFeeBps(): int64 {
    val storage = lazy FundStorage.load();
    return storage.mintFeeBps;
}

get fun redeemFeeBps(): int64 {
    val storage = lazy FundStorage.load();
    return storage.redeemFeeBps;
}

get fun isPaused(): bool {
    val storage = lazy FundStorage.load();
    return storage.paused;
}

get fun kycRequired(): bool {
    val storage = lazy FundStorage.load();
    return storage.kycRequired;
}

get fun custodianCount(): int64 {
    val storage = lazy FundStorage.load();
    return storage.custodianCount;
}

get fun custodianThreshold(): int64 {
    val storage = lazy FundStorage.load();
    return storage.custodianThreshold;
}

get fun custodianAt(index: int64): uint256 {
    val storage = lazy FundStorage.load();
    return storage.custodians.mustGet(index);
}

get fun jettonMinter(): address {
    val storage = lazy FundStorage.load();
    return storage.jettonMinter;
}

get fun orderAt(id: int64): Order {
    val storage = lazy FundStorage.load();
    return OrdersStore.fromCell(storage.ordersStore).mints.mustGet(id);
}

get fun redeemAt(id: int64): Redeem {
    val storage = lazy FundStorage.load();
    return OrdersStore.fromCell(storage.ordersStore).redeems.mustGet(id);
}

get fun fundWallet(): address {
    val storage = lazy FundStorage.load();
    return loadFundWallet(storage);
}
