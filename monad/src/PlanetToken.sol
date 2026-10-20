// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * PlanetToken (Monad / EVM port) — the PLT token, deliberately self-contained.
 *
 * No OpenZeppelin dependency on purpose: the whole point of this contract is that an auditor can
 * read every line, and a 90-line ERC-20 with one privileged relationship is easier to audit than a
 * 400-line inheritance tree. The surface is exactly what the protocol needs:
 *
 *   - ERC-20 transfer / approve / transferFrom with standard events
 *   - mint / burn callable ONLY by `minter` (the PlanetCore)
 *   - `minter` settable only by `owner` (wire the owner to the Timelock in production)
 *
 * EVM simplification worth noting: the TON version needed an asynchronous jetton mint plus a
 * "burn mirror" notification back to the core to keep supply in sync. Here the Core calls
 * token.mint()/burn() synchronously, so supply and core accounting cannot drift by construction.
 * That removes an entire class of finding (the C-2 mirror asymmetry) rather than fixing it.
 *
 * Not audited. Testnet only.
 */
contract PlanetToken {
    string public constant name = "Planet";
    string public constant symbol = "PLT";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;
    address public minter; // the PlanetCore

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MinterChanged(address indexed minter);
    event OwnerChanged(address indexed from, address indexed to);

    error NotOwner();
    error NotMinter();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, address minter_) {
        if (owner_ == address(0) || minter_ == address(0)) revert ZeroAddress();
        owner = owner_;
        minter = minter_;
    }

    // ---------------------------------------------------------------- ERC-20
    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - value;
        }
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - value;
        }
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    // ---------------------------------------------------------------- supply (Core only)
    function mint(address to, uint256 value) external onlyMinter {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function burn(address from, uint256 value) external onlyMinter {
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - value;
            totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
    }

    // ---------------------------------------------------------------- admin
    function setMinter(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        minter = next;
        emit MinterChanged(next);
    }

    function setOwner(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OwnerChanged(owner, next);
        owner = next;
    }

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }
}
