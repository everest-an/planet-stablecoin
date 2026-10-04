// Rate limits for mint/redeem, kept in a ref cell so PlanetCore's main storage
// stays within TON's 1023-bit cell limit.

struct Limits {
    maxPerTx: int64      // per-transaction mint cap in USDC units (0 = unlimited)
    arbRebateBps: int64  // mint-fee rebate when PPI > BAND_RICH (0 = off)
}
