// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * PlanetBond (Monad / EVM port) — stabilisation bonds, with the review's three fixes baked in.
 *
 *   BD-1  REDEMPTION IS REQUEST + OPERATOR SETTLEMENT. A holder's redeem() only flips `requested`;
 *         it can never mark a claim dead before anyone has paid. Only the operator (owner) can
 *         settle, and settling releases the face value from totalIssued. On the TON version this
 *         was the difference between a mis-click costing nothing and a mis-click losing the claim.
 *   BD-2  the premium is bounded to [0, BPS_DENOM] (100%).
 *   BD-3  settling asserts totalIssued >= face before subtracting, so an accounting slip cannot
 *         underflow into a huge positive number.
 *
 * Not audited. Testnet only.
 */
contract PlanetBond {
    struct BondRec {
        uint64 principal; // paid in
        uint64 face; // claim to be repaid (principal + premium)
        bool requested; // the holder asked to redeem — asking destroys nothing
        bool redeemed; // the operator settled it, after paying
    }

    uint64 public constant BPS_DENOM = 10_000;

    address public owner;
    bool public open;
    uint64 public premiumBps;
    uint64 public totalIssued;

    mapping(address => BondRec) public bondAt;

    event SaleOpened(bool open);
    event PremiumSet(uint64 premiumBps);
    event Subscribed(address indexed holder, uint64 amount, uint64 face);
    event RedeemRequested(address indexed holder);
    event Redeemed(address indexed holder, uint64 face);

    error NotOwner();
    error SaleClosed();
    error ZeroAmount();
    error BadPremium();
    error NoBond();
    error AlreadyRedeemed();
    error Underflow();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, uint64 premiumBps_) {
        if (owner_ == address(0)) revert NotOwner();
        if (premiumBps_ > BPS_DENOM) revert BadPremium();
        owner = owner_;
        premiumBps = premiumBps_;
    }

    function setOpen(bool v) external onlyOwner {
        open = v;
        emit SaleOpened(v);
    }

    /// @notice BD-2: the premium can never exceed 100%.
    function setPremium(uint64 bps) external onlyOwner {
        if (bps > BPS_DENOM) revert BadPremium();
        premiumBps = bps;
        emit PremiumSet(bps);
    }

    function subscribe(uint64 amount) external {
        if (!open) revert SaleClosed();
        if (amount == 0) revert ZeroAmount();

        BondRec storage b = bondAt[msg.sender];
        if (b.redeemed) revert AlreadyRedeemed();

        uint256 newFace = uint256(amount) * (uint256(BPS_DENOM) + uint256(premiumBps)) / uint256(BPS_DENOM);
        b.principal = uint64(uint256(b.principal) + uint256(amount));
        b.face = uint64(uint256(b.face) + newFace);
        b.requested = false;
        totalIssued = uint64(uint256(totalIssued) + newFace);

        emit Subscribed(msg.sender, amount, uint64(newFace));
    }

    /// @notice BD-1: this is a REQUEST. The claim is untouched, so a mis-click costs nothing.
    function redeem() external {
        BondRec storage b = bondAt[msg.sender];
        if (b.face == 0) revert NoBond();
        if (b.redeemed) revert AlreadyRedeemed();
        b.requested = true; // idempotent: asking twice is harmless
        emit RedeemRequested(msg.sender);
    }

    /// @notice BD-1 + BD-3: the operator settles AFTER paying. Only this releases the claim.
    function settleRedeem(address holder) external onlyOwner {
        BondRec storage b = bondAt[holder];
        if (b.face == 0) revert NoBond();
        if (b.redeemed) revert AlreadyRedeemed();
        if (totalIssued < b.face) revert Underflow(); // BD-3

        b.redeemed = true;
        b.requested = true;
        totalIssued -= b.face;
        emit Redeemed(holder, b.face);
    }

    /// @notice Owner can transfer the operator role, in production to the Timelock.
    function setOwner(address next) external onlyOwner {
        if (next == address(0)) revert NotOwner();
        owner = next;
    }
}
