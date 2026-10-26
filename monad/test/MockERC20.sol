// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Test-only ERC-20 standing in for the deposit asset (6 decimals, like USDC).
contract MockERC20 {
    string public name = "Test USD";
    string public symbol = "tUSD";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

interface IPlanetMint {
    function mint(uint64 deposit) external returns (uint64);
}

/// Deposit token that tries to re-enter the core from inside transferFrom. The core pulls collateral
/// with an external call before it touches state, so it must not assume the token is well behaved.
contract ReentrantToken {
    IPlanetMint public core;
    bool public armed;
    mapping(address => uint256) public balanceOf;

    function setCore(address c) external {
        core = IPlanetMint(c);
    }

    function arm() external {
        armed = true;
    }

    function mintTo(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        if (armed) {
            armed = false;
            core.mint(1);
        }
        return true;
    }
}
