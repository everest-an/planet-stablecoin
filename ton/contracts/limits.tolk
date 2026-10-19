// Rate limits and stability wiring for PlanetCore, kept in a ref cell so the main
// storage stays within TON's 1023-bit cell limit. This cell has spare room, so the
// stabilization-bond link lives here rather than in the (full) main storage.

struct Limits {
    maxPerTx: int64      // per-transaction mint cap in USDC units (0 = unlimited)
    arbRebateBps: int64  // mint-fee rebate when PPI > BAND_RICH (0 = off)
    riskFund: int64      // accumulated risk buffer (mock USDC units)
    bond: address        // PlanetBond on the PPI trigger (zero = auto-sync disabled)
    bondOpen: bool       // last sale state pushed to the bond (edge trigger, no spam)
    bondPaid: int64      // cumulative face value drawn from the risk fund on settlement
}
