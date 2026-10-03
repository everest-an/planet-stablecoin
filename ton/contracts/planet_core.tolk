// PlanetCore.tolk — Planet on TON (Phase 0 skeleton, Tolk language)
//
// ⚠️ DRAFT: this file must be compiled with the **Acton** toolchain
//    (WSL/Linux/Docker). It has NOT been compiled yet on this Windows machine
//    because Acton does not support native Windows (see ton/README.md).
//
// Fixed-point integers only (1e6). No floats.

const FEE_BPS = 50;          // 0.5% = 50 bps
const BPS_DENOM = 10000;
const PPI_SCALE = 1000000;   // 1.0 in 1e6 fixed point

const ERR_PAUSED = 100;
const ERR_NOT_OWNER = 101;
const ERR_SUPPLY = 102;

// ---------------- Storage ----------------

struct Storage {
    owner: address
    totalReserve: int
    totalSupply: int
    currentPpi: int
    paused: bool
}

// ---------------- Messages ----------------

struct Mint {
    queryId: int
    amount: int      // USDC (6 decimals)
}

struct Burn {
    queryId: int
    amount: int      // PLT (6 decimals)
}

struct UpdatePrice {
    queryId: int
    price: int       // 1e6 fixed point (Phase 0 placeholder; oracle TBD)
}

struct SetPaused {
    queryId: int
    paused: bool
}

type AllowedMessage = Mint | Burn | UpdatePrice | SetPaused

// ---------------- Contract ABI ----------------

contract PlanetCore {
    storage: Storage
    incomingMessages: AllowedMessage
}

// ---------------- Pure math ----------------

// Minted = D * (1 - f) / PPI
fun mintAmount(deposit: int, ppi: int): int {
    val net = deposit * (BPS_DENOM - FEE_BPS) / BPS_DENOM;
    return net * PPI_SCALE / ppi;
}

// Received = B * PPI * (1 - f)
fun burnAmount(plt: int, ppi: int): int {
    val gross = plt * ppi / PPI_SCALE;
    return gross * (BPS_DENOM - FEE_BPS) / BPS_DENOM;
}

// ---------------- Message handling ----------------

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessage.fromSlice(in.body);
    match (msg) {
        Mint => { handleMint(msg); }
        Burn => { handleBurn(msg); }
        UpdatePrice => { handleUpdatePrice(msg); }
        SetPaused => { handleSetPaused(msg); }
    }
}

fun handleMint(msg: Mint) {
    val storage = lazy Storage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    val minted = mintAmount(msg.amount, storage.currentPpi);
    storage.totalReserve += msg.amount;
    storage.totalSupply += minted;
    storage.save();
}

fun handleBurn(msg: Burn) {
    val storage = lazy Storage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    assert (storage.totalSupply >= msg.amount) throw ERR_SUPPLY;
    val received = burnAmount(msg.amount, storage.currentPpi);
    storage.totalSupply -= msg.amount;
    storage.totalReserve -= received;
    storage.save();
}

fun handleUpdatePrice(msg: UpdatePrice) {
    val storage = lazy Storage.load();
    assert (in.senderAddress == storage.owner) throw ERR_NOT_OWNER;
    storage.currentPpi = msg.price;
    storage.save();
}

fun handleSetPaused(msg: SetPaused) {
    val storage = lazy Storage.load();
    assert (in.senderAddress == storage.owner) throw ERR_NOT_OWNER;
    storage.paused = msg.paused;
    storage.save();
}

// ---------------- Getters ----------------

get fun reserve(): int {
    val storage = lazy Storage.load();
    return storage.totalReserve;
}

get fun supply(): int {
    val storage = lazy Storage.load();
    return storage.totalSupply;
}

get fun ppi(): int {
    val storage = lazy Storage.load();
    return storage.currentPpi;
}
