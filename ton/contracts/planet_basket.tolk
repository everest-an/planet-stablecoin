// PlanetBasket.tolk — on-chain commodity basket registry (Phase 1)
// Exposes each basket asset (weight/basePrice/currentPrice/positionValue) so users
// and the TG Mini App can read the token's underlying composition directly on-chain.

struct Asset {
    weight: int64         // ppm, 1e6 = 100%
    basePrice: int64      // 1e6 fixed point
    currentPrice: int64   // 1e6 fixed point
    positionValue: int64  // USD, 1e6 fixed point
}

struct BasketStorage {
    owner: address
    assetCount: int64
    assets: map<int64, Asset>   // index -> asset
}

fun BasketStorage.load() {
    return BasketStorage.fromCell(contract.getData())
}

fun BasketStorage.save(self) {
    contract.setData(self.toCell())
}

// ---------------- Messages ----------------

struct (0x20000001) SetAsset {
    queryId: int64
    index: int64
    weight: int64
    basePrice: int64
    currentPrice: int64
    positionValue: int64
}

type AllowedMessage = SetAsset

contract PlanetBasket {
    storage: BasketStorage
    incomingMessages: AllowedMessage
}

// ---------------- Handling ----------------

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessage.fromSlice(in.body);
    match (msg) {
        SetAsset => { handleSetAsset(in.senderAddress, msg); }
        else => { assert (in.body.isEmpty()) throw 0xFFFF; }
    }
}

fun handleSetAsset(sender: address, msg: SetAsset) {
    var storage = lazy BasketStorage.load();
    assert (sender == storage.owner) throw 101;
    val asset: Asset = {
        weight: msg.weight,
        basePrice: msg.basePrice,
        currentPrice: msg.currentPrice,
        positionValue: msg.positionValue,
    };
    storage.assets.set(msg.index, asset);
    if (msg.index >= storage.assetCount) {
        storage.assetCount = msg.index + 1;
    }
    storage.save();
}

// ---------------- Getters (public composition view) ----------------

get fun assetCount(): int64 {
    val storage = lazy BasketStorage.load();
    return storage.assetCount;
}

get fun assetAt(index: int64): Asset {
    val storage = lazy BasketStorage.load();
    return storage.assets.get(index)!;
}
