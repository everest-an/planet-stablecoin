// PlanetBond.tolk — stabilization bond ledger (Phase 1, mock accounting).
//
// When PPI < 0.95 the protocol can open a bond sale to absorb selling pressure:
// users subscribe, the protocol records a face-value claim (principal + premium),
// funded later by the risk fund / fees. Kept as a SEPARATE contract because
// PlanetCore's storage refs (4/4) are full and this is a distinct concern.

const BPS_DENOM = 10000;

const ERR_NOT_OWNER = 101;
const ERR_NOT_OPEN = 200;
const ERR_NO_BOND = 201;
const ERR_ALREADY_REDEEMED = 202;
const ERR_ZERO_AMOUNT = 203;
const ERR_BAD_PREMIUM = 204;

struct BondRec {
    principal: int64    // USDC contributed (mock units)
    face: int64         // claim to be repaid (principal + premium)
    requested: bool     // the holder asked to redeem — asking never destroys the claim
    redeemed: bool      // the operator settled it (after paying)
}

struct BondStorage {
    owner: address
    core: address                                   // PlanetCore (reference)
    open: bool                                      // sale open?
    premiumBps: int64                               // face = principal * (1 + premiumBps/1e4)
    totalIssued: int64                              // sum of outstanding face values
    bonds: map<address, BondRec>
}

fun BondStorage.load() {
    return BondStorage.fromCell(contract.getData())
}

fun BondStorage.save(self) {
    contract.setData(self.toCell())
}

// ---------------- Messages ----------------

struct (0x20000010) SetOpen {
    queryId: int64
    open: bool
}

struct (0x20000011) SetPremium {
    queryId: int64
    premiumBps: int64
}

struct (0x20000012) Subscribe {
    queryId: int64
    amount: int64   // mock USDC units
}

struct (0x20000013) Redeem {
    queryId: int64
}

// BD-1: settlement is an OPERATOR action. The holder asking to redeem must never be able to
// mark their own claim dead before anyone has paid (that used to lose the claim permanently).
struct (0x20000014) SettleRedeem {
    queryId: int64
    holder: address
}

type BondMessage = SetOpen | SetPremium | Subscribe | Redeem | SettleRedeem

contract PlanetBond {
    storage: BondStorage
    incomingMessages: BondMessage
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy BondMessage.fromSlice(in.body);
    match (msg) {
        SetOpen => { handleSetOpen(in.senderAddress, msg); }
        SetPremium => { handleSetPremium(in.senderAddress, msg); }
        Subscribe => { handleSubscribe(in.senderAddress, msg); }
        Redeem => { handleRedeem(in.senderAddress, msg); }
        SettleRedeem => { handleSettleRedeem(in.senderAddress, msg); }
        else => { assert (in.body.isEmpty()) throw 0xFFFF; }
    }
}

// Ignore bounced messages (TON best practice).
fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();
}

fun handleSetOpen(sender: address, msg: SetOpen) {
    var storage = lazy BondStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.open = msg.open;
    storage.save();
}

fun handleSetPremium(sender: address, msg: SetPremium) {
    var storage = lazy BondStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    // BD-2: an unbounded premium could inflate every face value without limit.
    assert (msg.premiumBps >= 0 && msg.premiumBps <= BPS_DENOM) throw ERR_BAD_PREMIUM;
    storage.premiumBps = msg.premiumBps;
    storage.save();
}

fun handleSubscribe(sender: address, msg: Subscribe) {
    var storage = lazy BondStorage.load();
    assert (storage.open) throw ERR_NOT_OPEN;
    assert (msg.amount > 0) throw ERR_ZERO_AMOUNT;

    var principal: int64 = msg.amount;
    var face: int64 = 0;
    val lookup = storage.bonds.get(sender);
    if (lookup.isFound) {
        val prev = lookup.loadValue();
        principal = prev.principal + msg.amount;
        face = prev.face;
    }
    val newFace = ((msg.amount as int) * (BPS_DENOM as int + storage.premiumBps as int) / BPS_DENOM) as int64;
    storage.bonds.set(sender, BondRec {
        principal: principal,
        face: face + newFace,
        requested: false,
        redeemed: false,
    });
    storage.totalIssued += newFace;
    storage.save();
}

// The holder asks to redeem. This is a REQUEST only: it flips `requested` and nothing else, so
// a mis-click can never destroy a claim (BD-1). The operator settles it after paying.
fun handleRedeem(sender: address, msg: Redeem) {
    var storage = lazy BondStorage.load();
    val lookup = storage.bonds.get(sender);
    assert (lookup.isFound) throw ERR_NO_BOND;
    val b = lookup.loadValue();
    assert (!b.redeemed) throw ERR_ALREADY_REDEEMED;
    storage.bonds.set(sender, BondRec {
        principal: b.principal,
        face: b.face,
        requested: true,
        redeemed: false,
    });
    storage.save();
}

// Operator settles a redemption (after the payout has been made off-chain) and releases the
// face value from `totalIssued`.
fun handleSettleRedeem(sender: address, msg: SettleRedeem) {
    var storage = lazy BondStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    val lookup = storage.bonds.get(msg.holder);
    assert (lookup.isFound) throw ERR_NO_BOND;
    val b = lookup.loadValue();
    assert (!b.redeemed) throw ERR_ALREADY_REDEEMED;
    // BD-3: guard the subtraction (an int64 underflow would wrap to a huge positive number).
    assert (storage.totalIssued >= b.face) throw ERR_ZERO_AMOUNT;
    storage.bonds.set(msg.holder, BondRec {
        principal: b.principal,
        face: b.face,
        requested: true,
        redeemed: true,
    });
    storage.totalIssued -= b.face;
    storage.save();
}

// ---------------- Getters ----------------

get fun isOpen(): bool {
    val storage = lazy BondStorage.load();
    return storage.open;
}

get fun premiumBps(): int64 {
    val storage = lazy BondStorage.load();
    return storage.premiumBps;
}

get fun totalIssued(): int64 {
    val storage = lazy BondStorage.load();
    return storage.totalIssued;
}

// Throws if the address has no bond.
get fun bondAt(owner: address): BondRec {
    val storage = lazy BondStorage.load();
    return storage.bonds.mustGet(owner);
}
