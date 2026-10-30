// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev TEST ONLY. A settable price source so the PnL / funding / liquidation paths can be tested
///      without waiting for a real market move. Never deploy this to a production market.
contract MockPrice {
    uint256 public twapOverride;

    function setTwap(uint256 t) external { twapOverride = t; }
    uint256 public price;
    uint8 public level;

    constructor(uint256 price_, uint8 level_) {
        price = price_;
        level = level_;
    }

    function set(uint256 price_, uint8 level_) external {
        price = price_;
        level = level_;
    }

    function twap() external view returns (uint256) {
        return twapOverride == 0 ? price : twapOverride;
    }

    function triggerPrice(bool isLong) external view returns (uint256) {
        uint256 spot = price;
        uint256 t = twapOverride == 0 ? spot : twapOverride;
        if (isLong) return spot > t ? spot : t;
        return spot < t ? spot : t;
    }

    function riskLevel() external view returns (uint8) {
        return level;
    }
}

/// @dev TEST ONLY. Minimal 6-decimal ERC20 for market tests.
contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev TEST ONLY. Minimal PlanetCore surface so PPIPriceSource can be exercised, including the
///      future-timestamp case the real signer produces (now + 120).
contract MockCore {
    uint64 public currentPpi = 1_000_000;
    uint64 public lastOracleUpdate;
    uint8 public st;
    address public relayer;

    function set(uint64 ppi_, uint64 ts_, uint8 st_) external {
        currentPpi = ppi_;
        lastOracleUpdate = ts_;
        st = st_;
    }

    function setRelayer(address r) external {
        relayer = r;
    }

    function assetCount() external pure returns (uint256) {
        return 1;
    }

    function assets(uint256)
        external
        view
        returns (uint64 weight, uint64 basePrice, uint64 currentPrice, uint64 volatility, uint64 liquidity, uint8 riskState, uint64 lastUpdate)
    {
        return (1_000_000, 1_000_000, 1_000_000, 0, 1_000_000, st, lastOracleUpdate);
    }
}
