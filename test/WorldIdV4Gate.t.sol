// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HumanGate} from "../src/HumanGate.sol";
import {WorldIdV4Gate} from "../src/WorldIdV4Gate.sol";

contract WorldIdV4GateTest is Test {
    uint256 internal signerKey = 0xA11CE;
    address internal signer = vm.addr(signerKey);
    address internal gateOwner = makeAddr("gateOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    WorldIdV4Gate internal gateV4;
    HumanGate internal humanGate;

    function setUp() public {
        vm.warp(1_700_000_000);
        gateV4 = new WorldIdV4Gate(signer, "fund-lease");
        humanGate = new HumanGate(gateOwner, address(0));
    }

    function _hash() internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(gateV4), gateV4.actionHash(), alice, uint256(11), block.timestamp + 1 hours));
    }

    function _sign(bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash)));
        return abi.encodePacked(r, s, v);
    }

    function test_Register_MarksWalletAndNullifier() public {
        bytes32 structHash = _hash();
        gateV4.register(alice, 11, block.timestamp + 1 hours, _sign(structHash));
        assertTrue(gateV4.isVerified(alice));
        assertTrue(gateV4.nullifierUsed(11));
        assertFalse(gateV4.isVerified(bob));
    }

    function test_Register_RevertsOnReusedNullifier() public {
        bytes32 aliceHash = _hash();
        gateV4.register(alice, 11, block.timestamp + 1 hours, _sign(aliceHash));
        bytes32 bobHash = keccak256(abi.encode(block.chainid, address(gateV4), gateV4.actionHash(), bob, uint256(11), block.timestamp + 1 hours));
        vm.expectRevert(WorldIdV4Gate.InvalidNullifier.selector);
        gateV4.register(bob, 11, block.timestamp + 1 hours, _sign(bobHash));
    }

    function test_Register_RevertsOnWrongSigner() public {
        bytes32 structHash = _hash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash)));
        vm.expectRevert(WorldIdV4Gate.BadSigner.selector);
        gateV4.register(alice, 11, block.timestamp + 1 hours, abi.encodePacked(r, s, v));
    }

    function test_Register_RevertsWhenExpired() public {
        bytes32 structHash = keccak256(abi.encode(block.chainid, address(gateV4), gateV4.actionHash(), alice, uint256(11), block.timestamp - 1));
        vm.expectRevert(WorldIdV4Gate.Expired.selector);
        gateV4.register(alice, 11, block.timestamp - 1, _sign(structHash));
    }

    function test_HumanGate_ForwardsAfterSetVerifier() public {
        bytes32 structHash = _hash();
        gateV4.register(alice, 11, block.timestamp + 1 hours, _sign(structHash));
        vm.prank(gateOwner);
        humanGate.setVerifier(address(gateV4));
        assertTrue(humanGate.isVerified(alice));
        assertFalse(humanGate.isVerified(bob));
    }

    function test_ActionHash_MatchesHashToField() public {
        bytes32 expected = bytes32(uint256(keccak256("fund-lease")) >> 8);
        assertEq(gateV4.actionHash(), expected);
    }
}
