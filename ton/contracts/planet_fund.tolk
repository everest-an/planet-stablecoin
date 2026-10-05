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

// ---------------- Storage ----------------

struct Order {
    user: address
    usd: int64
    ts: int64
    done: bool
}

struct FundStorage {
    owner: address
    jettonMinter: address
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
    orders: map<int64, Order>
}

fun FundStorage.load() {
    return FundStorage.fromCell(contract.getData())
}

fun FundStorage.save(self) {
    contract.setData(self.toCell())
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

type FundMessage = Subscribe | ConfirmMint | CancelOrder | AttestNav | SetFees | SetCustodian |
    SetCustodianThreshold | SetPaused | SetKyc | Allow | SetJettonMinter | SetOwner

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
    storage.orders.set(msg.queryId, Order { user: sender, usd: msg.usd, ts: blockchain.now() as int64, done: false });
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

    val lk = storage.orders.get(msg.orderId);
    assert (lk.isFound) throw ERR_NO_ORDER;
    val order = lk.loadValue();
    assert (!order.done) throw ERR_ORDER_DONE;

    // NAV jump guard (only when a previous NAV exists).
    if (storage.navPerShare > 0 && navJumpOk(storage.navPerShare, msg.navPerShare) == false) {
        throw ERR_NAV_JUMP;
    }

    val shares = (order.usd as int) * NAV_SCALE / (msg.navPerShare as int) * (BPS_DENOM - storage.mintFeeBps as int) / BPS_DENOM;
    storage.orders.set(msg.orderId, Order { user: order.user, usd: order.usd, ts: order.ts, done: true });
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
    val lk = storage.orders.get(msg.orderId);
    assert (lk.isFound) throw ERR_NO_ORDER;
    val order = lk.loadValue();
    assert (!order.done) throw ERR_ORDER_DONE;
    assert (sender == order.user || sender == storage.owner) throw ERR_NOT_OWNER;
    storage.orders.set(msg.orderId, Order { user: order.user, usd: order.usd, ts: order.ts, done: true });
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

// ---------------- Pure math ----------------

// NAV jump guard: reject a single attestation that moves NAV by more than the cap.
fun navJumpOk(oldNav: int64, newNav: int64): bool {
    if (oldNav == 0) {
        return true;
    }
    val diff = oldNav - newNav;
    val adiff = diff >= 0 ? diff : -diff;
    val jump = (adiff as int) * BPS_DENOM / (oldNav as int);
    return jump <= MAX_NAV_JUMP_BPS as int;
}

// ---------------- Getters ----------------

get fun owner(): address { return lazy FundStorage.load().owner; }
get fun navPerShare(): int64 { return lazy FundStorage.load().navPerShare; }
get fun lastNavUpdate(): int64 { return lazy FundStorage.load().lastNavUpdate; }
get fun mgmtFeeBps(): int64 { return lazy FundStorage.load().mgmtFeeBps; }
get fun mintFeeBps(): int64 { return lazy FundStorage.load().mintFeeBps; }
get fun redeemFeeBps(): int64 { return lazy FundStorage.load().redeemFeeBps; }
get fun isPaused(): bool { return lazy FundStorage.load().paused; }
get fun kycRequired(): bool { return lazy FundStorage.load().kycRequired; }
get fun custodianCount(): int64 { return lazy FundStorage.load().custodianCount; }
get fun custodianThreshold(): int64 { return lazy FundStorage.load().custodianThreshold; }
get fun custodianAt(index: int64): uint256 { return lazy FundStorage.load().custodians.mustGet(index); }
get fun jettonMinter(): address { return lazy FundStorage.load().jettonMinter; }

get fun orderAt(id: int64): Order {
    return lazy FundStorage.load().orders.mustGet(id);
}
