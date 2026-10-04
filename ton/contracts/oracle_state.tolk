// Oracle state for PlanetCore, kept in a separate module so tests can build the
// initial ref cell without importing the whole contract (which would clash with
// the generated wrapper's `PlanetCore` struct).
//
// PlanetCore stores this in a ref cell (storage field `oracleState: cell`), which
// keeps the main storage within TON's 1023-bit cell limit.

struct OracleState {
    oracle: address
    signerKey: uint256  // primary ed25519 key for signed price updates (0 = unset)
    signerKey2: uint256 // optional 2nd key; if set, updates need BOTH signatures
    lastOracleUpdate: int64
}
