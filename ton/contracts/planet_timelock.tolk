// PlanetTimelock.tolk — a delayed-owner (timelock) contract for PlanetCore.
//
// PlanetCore's owner can be migrated to this contract with `SetOwner`. Then every
// owner-only action (SetOracle / SetSigner / SetThreshold / SetJettonMinter /
// SetLimits / SetBasketAsset / SetCam / SetArb / SetOwner ...) must be:
//
//     Propose  ->  wait `delay` seconds  ->  Execute
//
// giving holders a window to react or exit before a privileged change takes effect.
//
// For M-of-N, point this timelock's `owner` at a TON multisig wallet address — then
// every proposal also needs M-of-N signatures. This composes WITHOUT touching
// PlanetCore: Core only ever sees `owner == timelock` and an ordinary message.

const TL_ERR_NOT_OWNER = 101;
const TL_ERR_NO_PENDING = 210;
const TL_ERR_ALREADY_PENDING = 211;
const TL_ERR_TOO_EARLY = 212;
const TL_ERR_BAD_DELAY = 213;

struct TimelockStorage {
    owner: address      // proposer/executor (use a TON multisig wallet for M-of-N)
    delay: int64        // seconds a proposal must age before Execute (0 = immediate)
    hasPending: bool
    dest: address       // pending action target (usually PlanetCore)
    body: cell          // pending action body (op + args), replayed verbatim on Execute
    eta: int64          // block time at/after which Execute is allowed
}

fun TimelockStorage.load() {
    return TimelockStorage.fromCell(contract.getData())
}

fun TimelockStorage.save(self) {
    contract.setData(self.toCell())
}

// ---------------- Messages ----------------

struct (0x20000001) TlPropose {
    queryId: int64
    dest: address
    body: cell
}

struct (0x20000002) TlExecute {
    queryId: int64
}

struct (0x20000003) TlCancel {
    queryId: int64
}

struct (0x20000004) TlSetDelay {
    queryId: int64
    delay: int64
}

struct (0x20000005) TlSetOwner {
    queryId: int64
    newOwner: address
}

type TimelockMessage = TlPropose | TlExecute | TlCancel | TlSetDelay | TlSetOwner

contract PlanetTimelock {
    storage: TimelockStorage
    incomingMessages: TimelockMessage
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy TimelockMessage.fromSlice(in.body);
    match (msg) {
        TlPropose => { handlePropose(in.senderAddress, msg); }
        TlExecute => { handleExecute(in.senderAddress, msg); }
        TlCancel => { handleCancel(in.senderAddress, msg); }
        TlSetDelay => { handleSetDelay(in.senderAddress, msg); }
        TlSetOwner => { tlHandleSetOwner(in.senderAddress, msg); }
        else => { assert (in.body.isEmpty()) throw 0xFFFF; }
    }
}

fun handlePropose(sender: address, msg: TlPropose) {
    var storage = lazy TimelockStorage.load();
    assert (sender == storage.owner) throw TL_ERR_NOT_OWNER;
    assert (!storage.hasPending) throw TL_ERR_ALREADY_PENDING;
    storage.hasPending = true;
    storage.dest = msg.dest;
    storage.body = msg.body;
    storage.eta = (blockchain.now() as int64) + storage.delay;
    storage.save();
}

fun handleExecute(sender: address, msg: TlExecute) {
    var storage = lazy TimelockStorage.load();
    assert (sender == storage.owner) throw TL_ERR_NOT_OWNER;
    assert (storage.hasPending) throw TL_ERR_NO_PENDING;
    assert ((blockchain.now() as int64) >= storage.eta) throw TL_ERR_TOO_EARLY;

    // Replay the proposed body to its target, from THIS contract (which holds owner
    // rights on Core). Carry the attached value so the inner message is funded.
    val out = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: storage.dest,
        body: storage.body,
    });
    out.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);

    storage.hasPending = false;
    storage.save();
}

fun handleCancel(sender: address, msg: TlCancel) {
    var storage = lazy TimelockStorage.load();
    assert (sender == storage.owner) throw TL_ERR_NOT_OWNER;
    assert (storage.hasPending) throw TL_ERR_NO_PENDING;
    storage.hasPending = false;
    storage.save();
}

fun handleSetDelay(sender: address, msg: TlSetDelay) {
    var storage = lazy TimelockStorage.load();
    assert (sender == storage.owner) throw TL_ERR_NOT_OWNER;
    assert (msg.delay >= 0) throw TL_ERR_BAD_DELAY;
    storage.delay = msg.delay;
    storage.save();
}

fun tlHandleSetOwner(sender: address, msg: TlSetOwner) {
    var storage = lazy TimelockStorage.load();
    assert (sender == storage.owner) throw TL_ERR_NOT_OWNER;
    storage.owner = msg.newOwner;
    storage.save();
}

// ---------------- Getters ----------------

get fun tlOwner(): address {
    val storage = lazy TimelockStorage.load();
    return storage.owner;
}

get fun delay(): int64 {
    val storage = lazy TimelockStorage.load();
    return storage.delay;
}

get fun hasPending(): bool {
    val storage = lazy TimelockStorage.load();
    return storage.hasPending;
}

get fun pendingEta(): int64 {
    val storage = lazy TimelockStorage.load();
    return storage.eta;
}

get fun pendingDest(): address {
    val storage = lazy TimelockStorage.load();
    return storage.dest;
}
