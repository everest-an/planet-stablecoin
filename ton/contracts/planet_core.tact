// PlanetCore.tact — Planet on TON (Phase 0 skeleton)
// 定点整数 1e6，禁止浮点。链路：TG Mini App -> TON Connect -> PlanetCore.

message Mint {
    amount: Int as uint64; // USDC, 6 decimals
}

message Burn {
    amount: Int as uint64; // PLT, 6 decimals
}

message UpdatePrice {
    index: Int as uint8;
    price: Int as uint64; // 1e6 scale
}

message SetPaused {
    paused: Bool;
}

const FEE_BPS: Int = 50;         // 0.5% = 50 bps
const BPS_DENOM: Int = 10000;
const PPI_SCALE: Int = 1000000;  // 1.0
const BPS_SCALE: Int = 1000000;  // USD fixed point

contract PlanetCore {
    owner: Address;
    totalReserve: Int as uint64;
    totalSupply: Int as uint64;
    currentPpi: Int as uint64;
    paused: Bool;

    init(owner: Address) {
        self.owner = owner;
        self.totalReserve = 0;
        self.totalSupply = 0;
        self.currentPpi = PPI_SCALE;
        self.paused = false;
    }

    // Minted = D * (1 - f) / PPI
    fun mintAmount(deposit: Int): Int {
        let net: Int = deposit * (BPS_DENOM - FEE_BPS) / BPS_DENOM;
        return net * PPI_SCALE / self.currentPpi;
    }

    // Received = B * PPI * (1 - f)
    fun burnAmount(plt: Int): Int {
        let gross: Int = plt * self.currentPpi / PPI_SCALE;
        return gross * (BPS_DENOM - FEE_BPS) / BPS_DENOM;
    }

    receive(msg: Mint) {
        require(!self.paused, "PlanetCore: paused");
        let minted: Int = self.mintAmount(msg.amount);
        self.totalReserve = self.totalReserve + msg.amount;
        self.totalSupply = self.totalSupply + minted;
    }

    receive(msg: Burn) {
        require(!self.paused, "PlanetCore: paused");
        require(self.totalSupply >= msg.amount, "PlanetCore: insufficient supply");
        let received: Int = self.burnAmount(msg.amount);
        self.totalSupply = self.totalSupply - msg.amount;
        self.totalReserve = self.totalReserve - received;
    }

    // Price feed is a placeholder in Phase 0 (oracle TBD, see docs/PLAN-TON.md §3).
    receive(msg: UpdatePrice) {
        require(sender() == self.owner, "PlanetCore: not owner");
        self.currentPpi = msg.price;
    }

    receive(msg: SetPaused) {
        require(sender() == self.owner, "PlanetCore: not owner");
        self.paused = msg.paused;
    }

    get fun reserve(): Int {
        return self.totalReserve;
    }

    get fun supply(): Int {
        return self.totalSupply;
    }

    get fun ppi(): Int {
        return self.currentPpi;
    }
}
