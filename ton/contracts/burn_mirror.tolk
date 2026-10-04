// Burn mirror message, shared by PlanetCore and the PLT Jetton minter.
//
// When a user redeems via their wallet (TEP-74 AskToBurn), the minter decrements
// its supply and then forwards this message to PlanetCore (which is the minter's
// admin) so core's totalSupply/totalReserve stay in sync with the minter — the
// single source of truth for PLT supply.

struct (0x10000008) BurnMirror {
    queryId: int64
    jettonAmount: int64   // PLT already burned from the minter's supply
}
