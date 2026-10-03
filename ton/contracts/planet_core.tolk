// PlanetCore.tolk — Planet on TON (Phase 0 skeleton, Tolk language)
//
// Compiled with the Acton toolchain (see ton/README.md). CI: .github/workflows/ton-build.yml
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
    jettonMinter: address   // PLT Jetton minter (0 = unset)
    totalReserve: int64
    totalSupply: int64
    currentPpi: int64
    paused: bool
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

type AllowedMessage = Mint | Burn | UpdatePrice | SetPaused | SetJettonMinter

// ---------------- Contract ABI ----------------

contract PlanetCore {
    storage: Storage
    incomingMessages: AllowedMessage
}

// ---------------- Pure math ----------------

// Minted = D * (1 - f) / PPI
// NOTE: Phase 0 skeleton; 64-bit intermediates can overflow for very large inputs
// (real implementation needs u128 / reordered math — tracked in docs/TON-MAPPING.md).
fun mintAmount(deposit: int64, ppi: int64): int64 {
    val net = deposit * (BPS_DENOM - FEE_BPS) / BPS_DENOM;
    return net * PPI_SCALE / ppi;
}

// Received = B * PPI * (1 - f)
fun burnAmount(plt: int64, ppi: int64): int64 {
    val gross = plt * ppi / PPI_SCALE;
    return gross * (BPS_DENOM - FEE_BPS) / BPS_DENOM;
}

// ---------------- Message handling ----------------

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessage.fromSlice(in.body);
    match (msg) {
        Mint => { handleMint(msg); }
        Burn => { handleBurn(msg); }
        UpdatePrice => { handleUpdatePrice(in.senderAddress, msg); }
        SetPaused => { handleSetPaused(in.senderAddress, msg); }
        SetJettonMinter => { handleSetJettonMinter(in.senderAddress, msg); }
        else => { assert (in.body.isEmpty()) throw 0xFFFF; }
    }
}

fun handleMint(msg: Mint) {
    var storage = lazy Storage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    val minted = mintAmount(msg.amount, storage.currentPpi);
    storage.totalReserve += msg.amount;
    storage.totalSupply += minted;
    storage.save();
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
