// Oracle state for PlanetCore, kept in a separate module so tests can build the
// initial ref cell without importing the whole contract (which would clash with
// the generated wrapper's `PlanetCore` struct).
//
// PlanetCore stores this in a ref cell (storage field `oracleState: cell`), which
// keeps the main storage within TON's 1023-bit cell limit.

struct OracleState {
    oracle: address
    signerCount: int64              // number of registered signer slots
    threshold: int64                // required distinct valid signatures (0/1 = single)
    signers: map<int64, uint256>    // index -> ed25519 signer public key
    lastOracleUpdate: int64
}
