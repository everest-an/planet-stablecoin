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
    index: int64       // signer slot to register/replace
    key: uint256       // ed25519 public key
}

struct (0x10000015) SetThreshold {
    queryId: int64
    m: int64           // required distinct valid signatures (1 = single-signer)
}

// Signatures are 512-bit (R||S) — too wide to inline twice, so each is carried in a ref.
struct (0x10000010) SignedPriceUpdate {
    sig1: cell         // 512-bit ed25519 signature over payload.hash()
    sig2: cell         // second signer's 512-bit signature (required only if signerKey2 set)
    payload: cell      // PricePayload
}

// M>2 variant: `sigs` data = uint8 count, followed by `count` refs, each a cell
// holding one 512-bit signature over payload.hash(). Needed when threshold > 2.
struct (0x10000016) SignedPriceUpdateN {
    sigs: cell         // uint8 count + count refs (one 512-bit sig each)
    payload: cell      // PricePayload
}
