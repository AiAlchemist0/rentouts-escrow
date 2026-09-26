// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HumanGate} from "../src/HumanGate.sol";
import {WorldHumanVerifier} from "../src/WorldHumanVerifier.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

/// @notice Stand-in router. `verifyProof` is a view, so it only reads flags the test set earlier.
contract MockWorldIDRouter is IWorldID {
    bool public accept = true;
    uint256 public expectedSignal; // 0 = do not check

    function setAccept(bool accept_) external {
        accept = accept_;
    }

    function setExpectedSignal(uint256 signal_) external {
        expectedSignal = signal_;
    }

    function verifyProof(
        uint256,
        uint256 groupId,
        uint256 signalHash,
        uint256,
        uint256,
        uint256[8] calldata
    ) external view {
        require(accept, "reject");
        require(groupId == 1, "group");
        if (expectedSignal != 0) require(signalHash == expectedSignal, "signal");
    }
}

contract WorldHumanVerifierTest is Test {
    MockWorldIDRouter internal router;
    WorldHumanVerifier internal verifier;
    HumanGate internal gate;

    address internal gateOwner = makeAddr("gateOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256[8] internal proof;

    function setUp() public {
        router = new MockWorldIDRouter();
        verifier = new WorldHumanVerifier(IWorldID(address(router)), "app_staging_rentouts", "fund-lease");
        gate = new HumanGate(gateOwner, address(0));
        proof[0] = 1;
    }

    function _signal(address account) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(account))) >> 8;
    }

    function test_Verify_MarksWalletAndConsumesNullifier() public {
        verifier.verify(alice, 1, 11, proof);

        assertTrue(verifier.isVerified(alice));
        assertTrue(verifier.nullifierHashes(11));
        assertFalse(verifier.isVerified(bob));
    }

    function test_Verify_BindsSignalToTheAccount() public {
        router.setExpectedSignal(_signal(alice));
        verifier.verify(alice, 1, 11, proof);
        assertTrue(verifier.isVerified(alice));
    }

    function test_Verify_RevertsWhenSignalIsForSomeoneElse() public {
        router.setExpectedSignal(_signal(bob));
        vm.expectRevert(bytes("signal"));
        verifier.verify(alice, 1, 11, proof);
        assertFalse(verifier.isVerified(alice));
    }

    function test_Verify_RevertsOnReusedNullifier() public {
        verifier.verify(alice, 1, 11, proof);
        vm.expectRevert(WorldHumanVerifier.InvalidNullifier.selector);
        verifier.verify(bob, 1, 11, proof);
        assertFalse(verifier.isVerified(bob));
    }

    function test_Verify_RevertsWhenRouterRejects() public {
        router.setAccept(false);
        vm.expectRevert(bytes("reject"));
        verifier.verify(alice, 1, 11, proof);
        assertFalse(verifier.isVerified(alice));
        assertFalse(verifier.nullifierHashes(11));
    }

    function test_Verify_RevertsForZeroAccount() public {
        vm.expectRevert(WorldHumanVerifier.ZeroAccount.selector);
        verifier.verify(address(0), 1, 11, proof);
    }

    function test_HumanGate_ForwardsOnceVerifierIsSet() public {
        assertTrue(gate.isVerified(alice)); // open gate

        verifier.verify(alice, 1, 11, proof);
        vm.prank(gateOwner);
        gate.setVerifier(address(verifier));

        assertTrue(gate.isVerified(alice));
        assertFalse(gate.isVerified(bob));
    }

    function test_ExternalNullifier_IsStableAndNonZero() public {
        WorldHumanVerifier again =
            new WorldHumanVerifier(IWorldID(address(router)), "app_staging_rentouts", "fund-lease");
        assertGt(verifier.externalNullifierHash(), 0);
        assertEq(verifier.externalNullifierHash(), again.externalNullifierHash());

        WorldHumanVerifier otherAction =
            new WorldHumanVerifier(IWorldID(address(router)), "app_staging_rentouts", "other-action");
        assertTrue(verifier.externalNullifierHash() != otherAction.externalNullifierHash());
    }
}
