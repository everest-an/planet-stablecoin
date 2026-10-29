// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev TEST ONLY. A settable price source so the PnL / funding / liquidation paths can be tested
///      without waiting for a real market move. Never deploy this to a production market.
contract MockPrice {
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
