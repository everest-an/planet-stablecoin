// Signed price update: lets an off-chain relayer/adapter (e.g. a RedStone/DIA bridge)
// push standardized data that PlanetCore verifies on-chain with isSignatureValid.
// This reduces the external dependency to a single public key (public info).

struct PricePayload {
    queryId: int64
    index: int64
    price: int64       // 1e6
    volatility: int64  // 1e6
    liquidity: int64   // 0..1e6
    riskState: int64   // 0/1/2
    timestamp: int64
}

struct (0x10000011) SetSigner {
    queryId: int64
    key: uint256       // ed25519 public key
}

struct (0x10000010) SignedPriceUpdate {
    signature: slice   // ed25519 signature over payload.hash()
    payload: cell      // PricePayload
}
