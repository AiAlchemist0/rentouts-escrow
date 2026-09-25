// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {HumanGate} from "../src/HumanGate.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {IHumanGate} from "../src/interfaces/IHumanGate.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";
import {MockHumanVerifier} from "./helpers/MockHumanVerifier.sol";

/// @notice The World ID seam: RentEscrow's immutable humanGate, and the HumanGate whose verifier
///         can be plugged in later without redeploying the escrow.
contract HumanGateTest is Test {
    MockUSDC internal usdc;
    MockHumanVerifier internal world; // stands in for the World ID verifier built later
    HumanGate internal gate;
    RentEscrow internal escrow; // gated through `gate`, lease shares disabled

    address internal gateOwner = makeAddr("gateOwner"); // the RentOuts deployer
    address internal arbiter = makeAddr("arbiter");
    address internal landlord = makeAddr("landlord");
    address internal tenant = makeAddr("tenant");
    address internal stranger = makeAddr("stranger");

    uint128 internal constant DEPOSIT = 300e6;
    uint128 internal constant RENT = 100e6;
    uint32 internal constant PERIOD = 1 days;
    uint16 internal constant PERIODS = 3;
    uint256 internal constant TOTAL = uint256(DEPOSIT) + uint256(RENT) * PERIODS;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        world = new MockHumanVerifier();
        gate = new HumanGate(gateOwner, address(0)); // starts open
        escrow = new RentEscrow(IERC20(address(usdc)), arbiter, address(0), address(gate));
    }

    // ------------------------------------------------------------------ helpers

    function _create(RentEscrow e) internal returns (uint256 id) {
        vm.prank(landlord);
        id = e.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
    }

    /// @dev Mints and approves TOTAL, then funds as the tenant (the call may revert).
    function _fund(RentEscrow e, uint256 id) internal {
        usdc.mint(tenant, TOTAL);
        vm.prank(tenant);
        usdc.approve(address(e), TOTAL);
        vm.prank(tenant);
        e.fundLease(id);
    }

    function _setVerifier(address v) internal {
        vm.prank(gateOwner);
        gate.setVerifier(v);
    }

    function _notHuman(address a) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IRentEscrow.NotVerifiedHuman.selector, a);
    }

    // ------------------------------------------------------------------ escrow without a gate

    function test_NoGate_FundingUnaffected() public {
        RentEscrow plain = new RentEscrow(IERC20(address(usdc)), arbiter, address(0), address(0));
        assertEq(plain.humanGate(), address(0));
        uint256 id = _create(plain);
        _fund(plain, id); // tenant was never verified anywhere
        assertEq(uint8(plain.getLease(id).state), uint8(IRentEscrow.State.ACTIVE));
        assertEq(plain.escrowBalance(id), TOTAL);
    }

    function test_Escrow_Constructor_RevertsOnGateWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(RentEscrow.HumanGateHasNoCode.selector, stranger));
        new RentEscrow(IERC20(address(usdc)), arbiter, address(0), stranger);
    }

    // ------------------------------------------------------------------ HumanGate on its own

    function test_Gate_Config() public {
        assertEq(escrow.humanGate(), address(gate));
        assertEq(gate.owner(), gateOwner);
        assertEq(address(gate.verifier()), address(0));
    }

    function testFuzz_Gate_OpenWhileVerifierIsZero(address anyone) public {
        assertTrue(gate.isVerified(anyone));
    }

    function testFuzz_Gate_ForwardsToVerifier(address account, bool ok) public {
        _setVerifier(address(world));
        world.setVerified(account, ok);
        assertEq(gate.isVerified(account), ok);
    }

    function test_Gate_SetVerifier_OnlyOwner() public {
        address[4] memory notOwner = [stranger, landlord, tenant, arbiter];
        for (uint256 i; i < notOwner.length; i++) {
            vm.prank(notOwner[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner[i]));
            gate.setVerifier(address(world));
        }
        assertEq(address(gate.verifier()), address(0));

        vm.expectEmit(address(gate));
        emit HumanGate.VerifierUpdated(address(0), address(world));
        _setVerifier(address(world));
        assertEq(address(gate.verifier()), address(world));

        vm.expectEmit(address(gate));
        emit HumanGate.VerifierUpdated(address(world), address(0));
        _setVerifier(address(0));
        assertEq(address(gate.verifier()), address(0));
    }

    function test_Gate_RejectsVerifierWithoutCode() public {
        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSelector(HumanGate.VerifierHasNoCode.selector, stranger));
        gate.setVerifier(stranger);

        vm.expectRevert(abi.encodeWithSelector(HumanGate.VerifierHasNoCode.selector, stranger));
        new HumanGate(gateOwner, stranger);
    }

    function test_Gate_ConstructorWithVerifier() public {
        vm.expectEmit();
        emit HumanGate.VerifierUpdated(address(0), address(world));
        HumanGate g = new HumanGate(gateOwner, address(world));
        assertEq(address(g.verifier()), address(world));
        assertFalse(g.isVerified(tenant));
    }

    // ------------------------------------------------------------------ gated escrow

    function test_Gated_OpenGateLetsAnyTenantFund() public {
        uint256 id = _create(escrow);
        _fund(escrow, id);
        assertEq(uint8(escrow.getLease(id).state), uint8(IRentEscrow.State.ACTIVE));
    }

    function test_Gated_UnverifiedTenantCannotFund() public {
        _setVerifier(address(world)); // tenant not verified
        uint256 id = _create(escrow);
        usdc.mint(tenant, TOTAL);
        vm.startPrank(tenant);
        usdc.approve(address(escrow), TOTAL);
        vm.expectRevert(_notHuman(tenant));
        escrow.fundLease(id);
        vm.stopPrank();

        assertEq(uint8(escrow.getLease(id).state), uint8(IRentEscrow.State.CREATED));
        assertEq(escrow.escrowBalance(id), 0);
        assertEq(usdc.balanceOf(tenant), TOTAL);
        assertEq(escrow.tenantStats(tenant).leasesFunded, 0);
    }

    function test_Gated_PartyAndStateChecksComeFirst() public {
        _setVerifier(address(world));
        uint256 id = _create(escrow);
        vm.prank(stranger); // unverified AND not the tenant: NotTenant, not NotVerifiedHuman
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotTenant.selector, id));
        escrow.fundLease(id);
    }

    function test_Gated_VerifiedTenantFunds() public {
        _setVerifier(address(world));
        world.setVerified(tenant, true);
        uint256 id = _create(escrow);
        _fund(escrow, id);
        assertEq(escrow.escrowBalance(id), TOTAL);
    }

    /// World gets plugged in (and unplugged) on the SAME escrow: no redeploy.
    function test_Gated_FlipVerifierLaterWithoutRedeployingEscrow() public {
        address escrowBefore = address(escrow);

        uint256 id1 = _create(escrow);
        _fund(escrow, id1); // open gate

        _setVerifier(address(world)); // World plugged in later
        uint256 id2 = _create(escrow);
        usdc.mint(tenant, TOTAL);
        vm.prank(tenant);
        usdc.approve(address(escrow), TOTAL);
        vm.prank(tenant);
        vm.expectRevert(_notHuman(tenant));
        escrow.fundLease(id2);

        world.setVerified(tenant, true); // tenant proves personhood
        vm.prank(tenant);
        escrow.fundLease(id2);

        world.setVerified(tenant, false);
        uint256 id3 = _create(escrow);
        usdc.mint(tenant, TOTAL);
        vm.prank(tenant);
        usdc.approve(address(escrow), TOTAL);
        vm.prank(tenant);
        vm.expectRevert(_notHuman(tenant));
        escrow.fundLease(id3);

        _setVerifier(address(0)); // unplugged again: open
        vm.prank(tenant);
        escrow.fundLease(id3);

        assertEq(address(escrow), escrowBefore);
        assertEq(escrow.humanGate(), address(gate));
        assertEq(escrow.escrowBalance(id1) + escrow.escrowBalance(id2) + escrow.escrowBalance(id3), 3 * TOTAL);
    }

    function test_Gated_VerifierDownFailsClosedUntilOwnerReopens() public {
        _setVerifier(address(world));
        world.setVerified(tenant, true);
        world.setDown(true);
        uint256 id = _create(escrow);
        usdc.mint(tenant, TOTAL);
        vm.prank(tenant);
        usdc.approve(address(escrow), TOTAL);
        vm.prank(tenant);
        vm.expectRevert(bytes("MockHumanVerifier: down"));
        escrow.fundLease(id);

        _setVerifier(address(0));
        vm.prank(tenant);
        escrow.fundLease(id);
        assertEq(uint8(escrow.getLease(id).state), uint8(IRentEscrow.State.ACTIVE));
    }

    /// The gate owner decides only who may fund NEW leases: turning the gate against a tenant after
    /// funding changes nothing for the funded lease (rent, close, dispute, resolve all still work).
    function test_Gated_NeverTouchesAFundedLease() public {
        uint256 closed = _create(escrow);
        _fund(escrow, closed);
        uint256 disputed = _create(escrow);
        _fund(escrow, disputed);

        _setVerifier(address(world)); // nobody is verified any more
        world.setDown(true); // and the verifier even reverts

        vm.warp(block.timestamp + PERIOD);
        escrow.claimRent(closed);
        vm.warp(escrow.endTime(closed));
        vm.prank(landlord);
        escrow.closeLease(closed);

        vm.prank(tenant);
        escrow.openDispute(disputed);
        vm.prank(arbiter);
        escrow.resolveDispute(disputed, 5_000);

        assertEq(uint8(escrow.getLease(closed).state), uint8(IRentEscrow.State.CLOSED));
        assertEq(uint8(escrow.getLease(disputed).state), uint8(IRentEscrow.State.CLOSED));
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(address(gate)), 0);
        assertEq(usdc.balanceOf(gateOwner), 0);
        assertEq(usdc.balanceOf(tenant) + usdc.balanceOf(landlord), 2 * TOTAL);
    }

    function test_Gated_RenouncedOwnerFreezesVerifier() public {
        _setVerifier(address(world));
        vm.prank(gateOwner);
        gate.renounceOwnership();
        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, gateOwner));
        gate.setVerifier(address(0));
        assertEq(address(gate.verifier()), address(world));
    }
}
