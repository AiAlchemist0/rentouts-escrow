// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {HumanGate} from "../src/HumanGate.sol";
import {WorldIdV4Gate} from "../src/WorldIdV4Gate.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";

/// @notice Replay / substitution cases for WorldIdV4Gate's RP attestation, and the end-to-end path the live
///         deployment uses: RentEscrow -> HumanGate -> WorldIdV4Gate, including swapping one World gate for
///         another (Sepolia: `fund-lease` gate 0x2705…B209 -> `fund-lease-wallet` gate 0x5Cb8…aABa).
contract WorldIdV4GateSecurityTest is Test {
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    uint256 internal constant NULLIFIER = 11;
    // secp256k1 group order; s > N/2 is the malleable twin OpenZeppelin's ECDSA rejects.
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    address internal signer = vm.addr(SIGNER_KEY);
    address internal gateOwner = makeAddr("gateOwner");
    address internal arbiter = makeAddr("arbiter");
    address internal landlord = makeAddr("landlord");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal relayer = makeAddr("relayer");

    WorldIdV4Gate internal gateV4; // action fund-lease
    WorldIdV4Gate internal walletGate; // action fund-lease-wallet, same RP signer
    HumanGate internal humanGate;
    MockUSDC internal usdc;
    RentEscrow internal escrow;

    uint256 internal deadline;

    function setUp() public {
        vm.warp(1_700_000_000);
        deadline = block.timestamp + 1 hours;
        gateV4 = new WorldIdV4Gate(signer, "fund-lease");
        walletGate = new WorldIdV4Gate(signer, "fund-lease-wallet");
        humanGate = new HumanGate(gateOwner, address(0));
        usdc = new MockUSDC();
        escrow = new RentEscrow(IERC20(address(usdc)), arbiter, address(0), address(humanGate));
    }

    // ------------------------------------------------------------------ helpers

    function _digest(uint256 chainId, address gate, bytes32 actionHash, address account, uint256 nullifier, uint256 dl)
        internal
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(chainId, gate, actionHash, account, nullifier, dl));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
    }

    function _sig(bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev A valid attestation for `account` on `gate` in this chain.
    function _attest(WorldIdV4Gate gate, address account, uint256 nullifier) internal view returns (bytes memory) {
        return _sig(_digest(block.chainid, address(gate), gate.actionHash(), account, nullifier, deadline));
    }

    function _createAndApprove(address tenant) internal returns (uint256 id) {
        vm.prank(landlord);
        id = escrow.createLease(tenant, 0.2e6, 0.1e6, 60, 3);
        usdc.mint(tenant, 0.5e6);
        vm.prank(tenant);
        usdc.approve(address(escrow), 0.5e6);
    }

    // ------------------------------------------------------------------ replay / substitution

    function test_Register_RevertsOnSignatureForAnotherChain() public {
        bytes memory sig = _sig(_digest(1, address(gateV4), gateV4.actionHash(), alice, NULLIFIER, deadline));
        vm.expectRevert(WorldIdV4Gate.BadSigner.selector);
        gateV4.register(alice, NULLIFIER, deadline, sig);
    }

    function test_Register_RevertsOnSignatureForAnotherGate() public {
        // Same signer, same wallet, same nullifier: an attestation for gateV4 does not register on walletGate.
        bytes memory sig = _attest(gateV4, alice, NULLIFIER);
        vm.expectRevert(WorldIdV4Gate.BadSigner.selector);
        walletGate.register(alice, NULLIFIER, deadline, sig);
    }

    function test_Register_RevertsOnSignatureForAnotherAction() public {
        // Right gate address, wrong action hash (fund-lease instead of fund-lease-wallet).
        bytes memory sig = _sig(_digest(block.chainid, address(walletGate), gateV4.actionHash(), alice, NULLIFIER, deadline));
        vm.expectRevert(WorldIdV4Gate.BadSigner.selector);
        walletGate.register(alice, NULLIFIER, deadline, sig);
    }

    function test_Register_RevertsWhenAccountSubstituted() public {
        bytes memory aliceSig = _attest(gateV4, alice, NULLIFIER);
        vm.expectRevert(WorldIdV4Gate.BadSigner.selector);
        gateV4.register(bob, NULLIFIER, deadline, aliceSig);
    }

    function test_Register_RevertsWhenDeadlineOrNullifierSubstituted() public {
        bytes memory sig = _attest(gateV4, alice, NULLIFIER);
        vm.expectRevert(WorldIdV4Gate.BadSigner.selector);
        gateV4.register(alice, NULLIFIER, deadline + 1, sig);
        vm.expectRevert(WorldIdV4Gate.BadSigner.selector);
        gateV4.register(alice, NULLIFIER + 1, deadline, sig);
    }

    function test_Register_RevertsOnZeroAccount() public {
        bytes memory sig = _attest(gateV4, address(0), NULLIFIER);
        vm.expectRevert(WorldIdV4Gate.ZeroAccount.selector);
        gateV4.register(address(0), NULLIFIER, deadline, sig);
    }

    function test_Register_RevertsOnBadSignatureLength() public {
        bytes memory sig = _attest(gateV4, alice, NULLIFIER);
        bytes memory short = new bytes(64);
        for (uint256 i; i < 64; ++i) {
            short[i] = sig[i];
        }
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(64)));
        gateV4.register(alice, NULLIFIER, deadline, short);
    }

    function test_Register_RevertsOnMalleableSignature() public {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SIGNER_KEY, _digest(block.chainid, address(gateV4), gateV4.actionHash(), alice, NULLIFIER, deadline));
        bytes32 highS = bytes32(N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        gateV4.register(alice, NULLIFIER, deadline, abi.encodePacked(r, highS, flippedV));
    }

    function test_Register_AcceptsDeadlineEqualToNow_AndAnyRelayer() public {
        uint256 dl = block.timestamp;
        bytes memory sig = _sig(_digest(block.chainid, address(gateV4), gateV4.actionHash(), alice, NULLIFIER, dl));
        vm.expectEmit(true, false, false, true, address(gateV4));
        emit WorldIdV4Gate.HumanRegistered(alice, NULLIFIER);
        vm.prank(relayer); // alice never sends the register tx
        gateV4.register(alice, NULLIFIER, dl, sig);
        assertTrue(gateV4.isVerified(alice));
        assertFalse(gateV4.isVerified(relayer));
    }

    function test_Constructor_RevertsOnZeroSigner() public {
        vm.expectRevert(WorldIdV4Gate.ZeroSigner.selector);
        new WorldIdV4Gate(address(0), "fund-lease");
    }

    // ------------------------------------------------------------------ RentEscrow end to end

    function test_FundLease_RevertsUntilRegistered_ThenSucceeds() public {
        vm.prank(gateOwner);
        humanGate.setVerifier(address(gateV4));
        uint256 id = _createAndApprove(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotVerifiedHuman.selector, alice));
        escrow.fundLease(id);

        vm.prank(relayer);
        gateV4.register(alice, NULLIFIER, deadline, _attest(gateV4, alice, NULLIFIER));

        vm.prank(alice);
        escrow.fundLease(id);
        assertEq(usdc.balanceOf(address(escrow)), 0.5e6);
        assertEq(usdc.balanceOf(alice), 0);
    }

    /// @dev The live Sepolia situation: the first gate has nobody registered, alice is registered on the second
    ///      gate only, and one setVerifier from the HumanGate owner switches over. No escrow redeploy.
    function test_FundLease_WorksAfterSwitchingToTheGateAliceIsRegisteredOn() public {
        vm.prank(gateOwner);
        humanGate.setVerifier(address(gateV4));
        walletGate.register(alice, NULLIFIER, deadline, _attest(walletGate, alice, NULLIFIER));
        uint256 id = _createAndApprove(alice);

        assertFalse(humanGate.isVerified(alice));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotVerifiedHuman.selector, alice));
        escrow.fundLease(id);

        vm.prank(gateOwner);
        humanGate.setVerifier(address(walletGate));
        assertTrue(humanGate.isVerified(alice));
        assertFalse(humanGate.isVerified(bob));

        vm.prank(alice);
        escrow.fundLease(id);
        assertEq(usdc.balanceOf(address(escrow)), 0.5e6);

        // bob, unregistered, still can't fund.
        uint256 bobLease = _createAndApprove(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotVerifiedHuman.selector, bob));
        escrow.fundLease(bobLease);
    }
}
