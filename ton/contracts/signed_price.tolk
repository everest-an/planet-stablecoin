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

// Ed25519 signatures are 64 bytes; message fields must be fixed-width, so the
// signature is split into two 256-bit halves (R || S) and rebuilt on-chain.
struct (0x10000013) SetSigner2 {
    queryId: int64
    key: uint256       // second signer key (0 = disable dual-sign)
}

// Signatures are 512-bit (R||S) — too wide to inline twice, so each is carried in a ref.
struct (0x10000010) SignedPriceUpdate {
    sig1: cell         // 512-bit ed25519 signature over payload.hash()
    sig2: cell         // second signer's 512-bit signature (required only if signerKey2 set)
    payload: cell      // PricePayload
}
