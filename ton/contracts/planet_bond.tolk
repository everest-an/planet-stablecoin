// PlanetBond.tolk — stabilization bond ledger (Phase 1, mock accounting).
//
// When PPI < 0.95 the protocol opens a bond sale automatically (PlanetCore pushes
// `SetOpen` on the PPI crossing); users subscribe, the protocol records a face-value
// claim (principal + premium), funded later by the risk fund / fees. Kept as a SEPARATE
// contract because PlanetCore's storage refs (4/4) are full and this is a distinct concern.

import "bond_messages"

const BOND_BPS_DENOM = 10000;

const BOND_ERR_NOT_OWNER = 101;
const BOND_ERR_NOT_OPEN = 200;
const BOND_ERR_NO_BOND = 201;
const BOND_ERR_ALREADY_REDEEMED = 202;
const BOND_ERR_ZERO_AMOUNT = 203;
const BOND_ERR_BAD_PREMIUM = 204;

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
// SetOpen / SetPremium / Subscribe / Redeem / SettleRedeem / PayBond live in
// `bond_messages.tolk` so PlanetCore can import the same structs. `PayBond` is
// outbound only and deliberately not part of this contract's inbound union.

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

// The sale can be opened/closed by the owner (manual override) OR by the PlanetCore
// address this bond was deployed with (automatic PPI trigger, see PlanetCore.bondSync).
fun handleSetOpen(sender: address, msg: SetOpen) {
    var storage = lazy BondStorage.load();
    assert (sender == storage.owner || sender == storage.core) throw BOND_ERR_NOT_OWNER;
    storage.open = msg.open;
    storage.save();
}

fun handleSetPremium(sender: address, msg: SetPremium) {
    var storage = lazy BondStorage.load();
    assert (sender == storage.owner) throw BOND_ERR_NOT_OWNER;
    // BD-2: an unbounded premium could inflate every face value without limit.
    assert (msg.premiumBps >= 0 && msg.premiumBps <= BOND_BPS_DENOM) throw BOND_ERR_BAD_PREMIUM;
    storage.premiumBps = msg.premiumBps;
    storage.save();
}

fun handleSubscribe(sender: address, msg: Subscribe) {
    var storage = lazy BondStorage.load();
    assert (storage.open) throw BOND_ERR_NOT_OPEN;
    assert (msg.amount > 0) throw BOND_ERR_ZERO_AMOUNT;

    var principal: int64 = msg.amount;
    var face: int64 = 0;
    val lookup = storage.bonds.get(sender);
    if (lookup.isFound) {
        val prev = lookup.loadValue();
        principal = prev.principal + msg.amount;
        face = prev.face;
    }
    val newFace = ((msg.amount as int) * (BOND_BPS_DENOM as int + storage.premiumBps as int) / BOND_BPS_DENOM) as int64;
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
    assert (lookup.isFound) throw BOND_ERR_NO_BOND;
    val b = lookup.loadValue();
    assert (!b.redeemed) throw BOND_ERR_ALREADY_REDEEMED;
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
    assert (sender == storage.owner) throw BOND_ERR_NOT_OWNER;
    val lookup = storage.bonds.get(msg.holder);
    assert (lookup.isFound) throw BOND_ERR_NO_BOND;
    val b = lookup.loadValue();
    assert (!b.redeemed) throw BOND_ERR_ALREADY_REDEEMED;
    // BD-3: guard the subtraction (an int64 underflow would wrap to a huge positive number).
    assert (storage.totalIssued >= b.face) throw BOND_ERR_ZERO_AMOUNT;
    storage.bonds.set(msg.holder, BondRec {
        principal: b.principal,
        face: b.face,
        requested: true,
        redeemed: true,
    });
    storage.totalIssued -= b.face;
    storage.save();

    // Risk-fund settlement linkage: tell PlanetCore how much face value was settled so
    // it can draw it from the risk fund (capped at the available balance). Best-effort:
    // the operator has already paid the holder off-chain, and Core never throws on a
    // shortfall — a bounce must never undo a completed settlement.
    if (!isZeroAddress(storage.core)) {
        val m = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            dest: storage.core,
            value: BOND_NOTIFY_TON,
            body: PayBond {
                queryId: msg.queryId,
                amount: b.face,
            },
        });
        m.send(SEND_MODE_PAY_FEES_SEPARATELY);
    }
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

get fun core(): address {
    val storage = lazy BondStorage.load();
    return storage.core;
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
