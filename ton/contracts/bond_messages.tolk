// Shared PlanetBond <-> PlanetCore messages.
//
// Kept in its own module (like `burn_mirror.tolk`) so both contracts import the message
// structs without importing each other's contract definition. Tolk rejects two contracts
// that define the same top-level symbol in one compilation unit, so the shared structs
// must live outside both .tolk files.

const BOND_NOTIFY_TON = ton("0.03"); // gas attached to a Core<->Bond notification

// ---------------- Core -> Bond ----------------

// PlanetCore sends this when the index crosses the stabilization-bond band:
// open below BOND_TRIGGER_PPI, close again after BOND_CLOSE_PPI (hysteresis).
// The Bond accepts it from its owner OR from the Core address it was deployed with.
struct (0x20000010) SetOpen {
    queryId: int64
    open: bool
}

// ---------------- Bond -> Core ----------------

// Sent after an operator settles a bond redemption. PlanetCore draws the amount from
// the risk fund (capped at the available balance) and records it in `bondPaid`.
// The actual payout stays an operator action (mock accounting, see docs/peg-stability.md §7).
struct (0x20000015) PayBond {
    queryId: int64
    amount: int64   // face value being settled (mock USDC units)
}

// ---------------- Bond-internal commands ----------------

struct (0x20000011) SetPremium {
    queryId: int64
    premiumBps: int64
}

struct (0x20000012) Subscribe {
    queryId: int64
    amount: int64   // mock USDC units
}

struct (0x20000013) Redeem {
    queryId: int64
}

// BD-1: settlement is an OPERATOR action. The holder asking to redeem must never be able to
// mark their own claim dead before anyone has paid (that used to lose the claim permanently).
struct (0x20000014) SettleRedeem {
    queryId: int64
    holder: address
}

// Shared zero-address test (the all-zero workchain-0 address has no code and can never be
// a real contract). Used to mean "no bond wired" / "reject ownership burn".
fun isZeroAddress(a: address): bool {
    val (wc, h) = a.getWorkchainAndHash();
    return wc == 0 && h == 0;
}
