// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SignedPriceOracle} from "../src/SignedPriceOracle.sol";

/// Focused on the properties that actually fail in production: distinct-signer enforcement,
/// replay onto another deployment/chain, and ECDSA malleability.
contract SignedPriceOracleTest is Test {
    SignedPriceOracle oracle;

    uint256 constant K1 = 0xA11CE111;
    uint256 constant K2 = 0xB0B2222;
    uint256 constant K3 = 0xCAFE333;

    address s1;
    address s2;
    address s3;

    function setUp() public {
        s1 = vm.addr(K1);
        s2 = vm.addr(K2);
        s3 = vm.addr(K3);

        address[] memory set = new address[](2);
        set[0] = s1;
        set[1] = s2;
        oracle = new SignedPriceOracle(address(this), set, 2); // 2-of-2
    }

    function payload() internal pure returns (SignedPriceOracle.PricePayload memory) {
        return SignedPriceOracle.PricePayload({
            index: 0,
            price: 90_000_000,
            volatility: 0,
            liquidity: 1_000_000,
            riskState: 0,
            timestamp: 1_700_000_000
        });
    }

    function sig(uint256 key, SignedPriceOracle.PricePayload memory p) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, oracle.digest(p));
        return abi.encodePacked(r, s, v); // r || s || v — the layout the contract parses
    }

    function cat(bytes memory a, bytes memory b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, b);
    }

    function test_two_distinct_signers_pass() public {
        SignedPriceOracle.PricePayload memory p = payload();
        assertTrue(oracle.verify(p, cat(sig(K1, p), sig(K2, p))));
    }

    /// THE rule: one key cannot satisfy M-of-N by signing twice.
    function test_one_signer_twice_does_not_pass() public {
        SignedPriceOracle.PricePayload memory p = payload();
        assertFalse(oracle.verify(p, cat(sig(K1, p), sig(K1, p))));
    }

    function test_unregistered_signer_does_not_count() public {
        SignedPriceOracle.PricePayload memory p = payload();
        assertFalse(oracle.verify(p, cat(sig(K1, p), sig(K3, p))));
    }

    /// Domain separation: chain id is bound into the digest.
    function test_replay_on_another_chain_fails() public {
        SignedPriceOracle.PricePayload memory p = payload();
        bytes memory sigs = cat(sig(K1, p), sig(K2, p));
        assertTrue(oracle.verify(p, sigs));
        vm.chainId(9999);
        assertFalse(oracle.verify(p, sigs));
    }

    /// Domain separation: the contract address is bound into the digest.
    function test_replay_on_another_deployment_fails() public {
        SignedPriceOracle.PricePayload memory p = payload();
        address[] memory set = new address[](2);
        set[0] = s1;
        set[1] = s2;
        SignedPriceOracle other = new SignedPriceOracle(address(this), set, 2);
        // signatures made for `oracle` must not verify on `other`
        assertFalse(other.verify(p, cat(sig(K1, p), sig(K2, p))));
    }

    /// EIP-2: an s value above the curve half-order is malleable and must be rejected.
    function test_malleable_signature_is_rejected() public {
        SignedPriceOracle.PricePayload memory p = payload();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(K1, oracle.digest(p));
        bytes32 flipped = bytes32(uint256(s) ^ (uint256(1) << 255)); // force s into the bad half
        bytes memory bad = abi.encodePacked(r, flipped, v);
        assertFalse(oracle.verify(p, cat(bad, sig(K2, p))));
    }

    function test_threshold_zero_reverts() public {
        address[] memory set = new address[](1);
        set[0] = s1;
        vm.expectRevert(SignedPriceOracle.BadThreshold.selector);
        new SignedPriceOracle(address(this), set, 0);
    }

    function test_threshold_above_set_size_reverts() public {
        address[] memory set = new address[](1);
        set[0] = s1;
        vm.expectRevert(SignedPriceOracle.BadThreshold.selector);
        new SignedPriceOracle(address(this), set, 2);
    }

    function test_duplicate_signer_in_set_reverts() public {
        address[] memory set = new address[](2);
        set[0] = s1;
        set[1] = s1;
        vm.expectRevert(SignedPriceOracle.DuplicateSigner.selector);
        new SignedPriceOracle(address(this), set, 1);
    }

    function test_not_enough_signatures_short_circuits() public {
        SignedPriceOracle.PricePayload memory p = payload();
        assertFalse(oracle.verify(p, sig(K1, p))); // 1 of 2
    }
}
