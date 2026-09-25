// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";

/// @dev Contract landlord that tries to re-enter the escrow when it receives its lease shares.
contract ReentrantLandlord {
    RentEscrow internal immutable escrow;
    address internal immutable tenant;

    constructor(RentEscrow escrow_, address tenant_) {
        escrow = escrow_;
        tenant = tenant_;
    }

    function list() external returns (uint256) {
        return escrow.createLease(tenant, 1e6, 1e6, 60, 1);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        escrow.createLease(tenant, 1e6, 1e6, 60, 1); // re-entry attempt
        return this.onERC1155Received.selector;
    }
}

contract RentEscrowTest is Test {
    MockUSDC internal usdc;
    LeaseShare1155 internal shares;
    RentEscrow internal escrow;

    address internal issuer = makeAddr("issuer"); // LeaseShare1155 owner
    address internal arbiter = makeAddr("arbiter");
    address internal landlord = makeAddr("landlord"); // allowlisted
    address internal tenant = makeAddr("tenant");
    address internal stranger = makeAddr("stranger"); // NOT allowlisted

    uint128 internal constant DEPOSIT = 300e6; // 300 USDC
    uint128 internal constant RENT = 100e6; // 100 USDC / period
    uint32 internal constant PERIOD = 1 days;
    uint16 internal constant PERIODS = 3;
    uint256 internal constant TOTAL = uint256(DEPOSIT) + uint256(RENT) * PERIODS;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        shares = new LeaseShare1155(issuer, "https://rentouts.co/api/lease-share/{id}.json");
        escrow = new RentEscrow(IERC20(address(usdc)), arbiter, address(shares), address(0));

        vm.startPrank(issuer);
        shares.setMinter(address(escrow));
        shares.setAllowlist(landlord, true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _create() internal returns (uint256 id) {
        vm.prank(landlord);
        id = escrow.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
    }

    function _fund(uint256 id) internal {
        usdc.mint(tenant, TOTAL);
        vm.startPrank(tenant);
        usdc.approve(address(escrow), TOTAL);
        escrow.fundLease(id);
        vm.stopPrank();
    }

    function _createAndFund() internal returns (uint256 id) {
        id = _create();
        _fund(id);
    }

    function _dispute(uint256 id) internal {
        vm.prank(tenant);
        escrow.openDispute(id);
    }

    function _invalidState(uint256 id, IRentEscrow.State s) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IRentEscrow.InvalidState.selector, id, s);
    }

    // ------------------------------------------------------------------ config

    function test_Config() public {
        assertEq(escrow.token(), address(usdc));
        assertEq(escrow.arbiter(), arbiter);
        assertEq(escrow.leaseShare(), address(shares));
        assertEq(escrow.humanGate(), address(0)); // gating: test/HumanGate.t.sol
        assertEq(escrow.SHARES_PER_LEASE(), 100);
        assertEq(escrow.MIN_PERIOD(), 60);
        assertEq(escrow.nextLeaseId(), 1);
        assertEq(usdc.decimals(), 6);
    }

    function test_Constructor_RevertsOnZeroTokenOrArbiter() public {
        vm.expectRevert(RentEscrow.ZeroAddress.selector);
        new RentEscrow(IERC20(address(0)), arbiter, address(shares), address(0));
        vm.expectRevert(RentEscrow.ZeroAddress.selector);
        new RentEscrow(IERC20(address(usdc)), address(0), address(shares), address(0));
    }

    // ------------------------------------------------------------------ createLease

    function test_CreateLease_StoresTermsAndMintsSharesToLandlord() public {
        vm.expectEmit(address(escrow));
        emit IRentEscrow.LeaseCreated(1, landlord, tenant, DEPOSIT, RENT, PERIOD, PERIODS);
        uint256 id = _create();

        assertEq(id, 1);
        assertEq(escrow.nextLeaseId(), 2);
        IRentEscrow.Lease memory l = escrow.getLease(id);
        assertEq(l.landlord, landlord);
        assertEq(l.tenant, tenant);
        assertEq(l.deposit, DEPOSIT);
        assertEq(l.rentPerPeriod, RENT);
        assertEq(l.periodSeconds, PERIOD);
        assertEq(l.periods, PERIODS);
        assertEq(l.periodsClaimed, 0);
        assertEq(l.startTime, 0);
        assertEq(uint8(l.state), uint8(IRentEscrow.State.CREATED));
        assertEq(escrow.escrowBalance(id), 0);
        assertEq(escrow.endTime(id), 0);

        // Curvegrid RWA: 100 shares of tokenId == leaseId to the (allowlisted) landlord.
        assertEq(shares.balanceOf(landlord, id), 100);
        assertEq(shares.totalSupply(id), 100);
    }

    function test_CreateLease_NumbersSequentially() public {
        uint256 a = _create();
        uint256 b = _create();
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(escrow.nextLeaseId(), 3);
        assertEq(shares.balanceOf(landlord, 2), 100);
    }

    function test_CreateLease_RevertsOnInvalidTerms() public {
        vm.startPrank(landlord);
        vm.expectRevert(IRentEscrow.InvalidTerms.selector); // no tenant
        escrow.createLease(address(0), DEPOSIT, RENT, PERIOD, PERIODS);
        vm.expectRevert(IRentEscrow.InvalidTerms.selector); // self-lease
        escrow.createLease(landlord, DEPOSIT, RENT, PERIOD, PERIODS);
        vm.expectRevert(IRentEscrow.InvalidTerms.selector); // nothing to escrow
        escrow.createLease(tenant, 0, 0, PERIOD, PERIODS);
        vm.expectRevert(IRentEscrow.InvalidTerms.selector); // zero-length term
        escrow.createLease(tenant, DEPOSIT, RENT, PERIOD, 0);
        vm.expectRevert(IRentEscrow.InvalidTerms.selector); // period below MIN_PERIOD
        escrow.createLease(tenant, DEPOSIT, RENT, 59, PERIODS);
        vm.expectRevert(IRentEscrow.InvalidTerms.selector); // total does not fit in uint128
        escrow.createLease(tenant, 0, type(uint128).max / 2 + 1, PERIOD, 2);
        vm.stopPrank();
        assertEq(escrow.nextLeaseId(), 1);
    }

    function test_CreateLease_ArbiterCanNeverBeAParty() public {
        // As landlord the arbiter could dispute at move-in and rule the whole escrow to itself, so it
        // cannot list even when it is on the share allowlist...
        vm.prank(issuer);
        shares.setAllowlist(arbiter, true);
        vm.prank(arbiter);
        vm.expectRevert(IRentEscrow.InvalidTerms.selector);
        escrow.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);

        // ...and as tenant it could rule all of its rent back to itself.
        vm.prank(landlord);
        vm.expectRevert(IRentEscrow.InvalidTerms.selector);
        escrow.createLease(arbiter, DEPOSIT, RENT, PERIOD, PERIODS);

        assertEq(escrow.nextLeaseId(), 1);
        assertEq(shares.totalSupply(1), 0);
    }

    function test_CreateLease_AcceptsEdgeTerms() public {
        vm.startPrank(landlord);
        uint256 minPeriod = escrow.createLease(tenant, DEPOSIT, RENT, 60, 1);
        uint256 depositOnly = escrow.createLease(tenant, DEPOSIT, 0, PERIOD, PERIODS);
        uint256 rentOnly = escrow.createLease(tenant, 0, RENT, PERIOD, PERIODS);
        vm.stopPrank();
        assertEq(escrow.getLease(minPeriod).periodSeconds, 60);
        assertEq(escrow.getLease(depositOnly).rentPerPeriod, 0);
        assertEq(escrow.getLease(rentOnly).deposit, 0);
    }

    function test_CreateLease_NonAllowlistedLandlordCannotList() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LeaseShare1155.NotAllowlisted.selector, stranger));
        escrow.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
        assertEq(escrow.nextLeaseId(), 1);

        vm.prank(issuer);
        shares.setAllowlist(stranger, true);
        vm.prank(stranger);
        assertEq(escrow.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS), 1);
        assertEq(shares.balanceOf(stranger, 1), 100);
    }

    function test_CreateLease_RevertsIfEscrowIsNotShareMinter() public {
        RentEscrow notMinter = new RentEscrow(IERC20(address(usdc)), arbiter, address(shares), address(0));
        vm.prank(landlord);
        vm.expectRevert(abi.encodeWithSelector(LeaseShare1155.NotMinter.selector, address(notMinter)));
        notMinter.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
    }

    function test_CreateLease_SharesDisabled() public {
        RentEscrow plain = new RentEscrow(IERC20(address(usdc)), arbiter, address(0), address(0));
        assertEq(plain.leaseShare(), address(0));
        vm.prank(stranger); // not allowlisted anywhere: fine when shares are disabled
        uint256 id = plain.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
        assertEq(id, 1);
        assertEq(shares.totalSupply(id), 0);
        assertEq(uint8(plain.getLease(id).state), uint8(IRentEscrow.State.CREATED));
    }

    function test_CreateLease_ReentryThroughShareCallbackBlocked() public {
        ReentrantLandlord evil = new ReentrantLandlord(escrow, tenant);
        vm.prank(issuer);
        shares.setAllowlist(address(evil), true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        evil.list();
        assertEq(escrow.nextLeaseId(), 1);
    }

    // ------------------------------------------------------------------ cancelLease

    function test_CancelLease() public {
        uint256 id = _create();
        vm.expectEmit(address(escrow));
        emit IRentEscrow.LeaseCancelled(id);
        vm.prank(landlord);
        escrow.cancelLease(id);
        assertEq(uint8(escrow.getLease(id).state), uint8(IRentEscrow.State.CANCELLED));

        // A cancelled lease can no longer be funded or cancelled again.
        vm.prank(tenant);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.CANCELLED));
        escrow.fundLease(id);
        vm.prank(landlord);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.CANCELLED));
        escrow.cancelLease(id);
    }

    function test_CancelLease_RevertsForNonLandlord() public {
        uint256 id = _create();
        vm.prank(tenant);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotLandlord.selector, id));
        escrow.cancelLease(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotLandlord.selector, id));
        escrow.cancelLease(id);
    }

    function test_CancelLease_RevertsOnceFundedOrUnknown() public {
        uint256 id = _createAndFund();
        vm.prank(landlord);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.ACTIVE));
        escrow.cancelLease(id);

        vm.prank(landlord);
        vm.expectRevert(_invalidState(99, IRentEscrow.State.NONE));
        escrow.cancelLease(99);
    }

    // ------------------------------------------------------------------ fundLease

    function test_FundLease_PullsDepositPlusAllRent() public {
        uint256 id = _create();
        usdc.mint(tenant, TOTAL);
        vm.startPrank(tenant);
        usdc.approve(address(escrow), TOTAL);
        vm.expectEmit(address(escrow));
        emit IRentEscrow.LeaseFunded(id, tenant, TOTAL, uint64(block.timestamp));
        escrow.fundLease(id);
        vm.stopPrank();

        IRentEscrow.Lease memory l = escrow.getLease(id);
        assertEq(uint8(l.state), uint8(IRentEscrow.State.ACTIVE));
        assertEq(l.startTime, block.timestamp);
        assertEq(escrow.endTime(id), block.timestamp + uint256(PERIOD) * PERIODS);
        assertEq(escrow.escrowBalance(id), TOTAL);
        assertEq(usdc.balanceOf(address(escrow)), TOTAL);
        assertEq(usdc.balanceOf(tenant), 0);
        assertEq(escrow.tenantStats(tenant).leasesFunded, 1);
    }

    function test_FundLease_RevertsForNonTenant() public {
        uint256 id = _create();
        vm.prank(landlord);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotTenant.selector, id));
        escrow.fundLease(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotTenant.selector, id));
        escrow.fundLease(id);
    }

    function test_FundLease_RevertsWhenAlreadyFundedOrUnknown() public {
        uint256 id = _createAndFund();
        vm.prank(tenant);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.ACTIVE));
        escrow.fundLease(id);
        vm.prank(tenant);
        vm.expectRevert(_invalidState(7, IRentEscrow.State.NONE));
        escrow.fundLease(7);
    }

    function test_FundLease_RevertsWithoutApproval() public {
        uint256 id = _create();
        usdc.mint(tenant, TOTAL);
        vm.prank(tenant);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, TOTAL)
        );
        escrow.fundLease(id);
    }

    // ------------------------------------------------------------------ claimable / claimRent

    function test_ClaimRent_NothingBeforeFirstPeriod() public {
        uint256 id = _createAndFund();
        vm.warp(block.timestamp + PERIOD - 1);
        (uint16 n, uint256 amt) = escrow.claimable(id);
        assertEq(n, 0);
        assertEq(amt, 0);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NothingToClaim.selector, id));
        escrow.claimRent(id);
    }

    function test_ClaimRent_AnyoneReleasesElapsedRentToLandlord() public {
        uint256 id = _createAndFund();
        vm.warp(block.timestamp + PERIOD);
        (uint16 n, uint256 amt) = escrow.claimable(id);
        assertEq(n, 1);
        assertEq(amt, RENT);

        vm.expectEmit(address(escrow));
        emit IRentEscrow.RentClaimed(id, landlord, 1, RENT);
        vm.prank(stranger);
        escrow.claimRent(id);

        assertEq(usdc.balanceOf(landlord), RENT);
        assertEq(usdc.balanceOf(stranger), 0);
        assertEq(escrow.escrowBalance(id), TOTAL - RENT);
        assertEq(escrow.getLease(id).periodsClaimed, 1);
        IRentEscrow.TenantStats memory s = escrow.tenantStats(tenant);
        assertEq(s.periodsPaid, 1);
        assertEq(s.rentPaid, RENT);

        (n,) = escrow.claimable(id);
        assertEq(n, 0);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NothingToClaim.selector, id));
        escrow.claimRent(id);
    }

    function test_ClaimRent_PartialPeriodsRoundDownThenCatchUp() public {
        uint256 id = _createAndFund();
        uint256 start = escrow.getLease(id).startTime;

        vm.warp(start + PERIOD + PERIOD / 2); // 1.5 periods
        (uint16 n,) = escrow.claimable(id);
        assertEq(n, 1);
        escrow.claimRent(id);

        vm.warp(start + 3 * uint256(PERIOD) - 1); // 2.99 periods: one more
        (n,) = escrow.claimable(id);
        assertEq(n, 1);
        escrow.claimRent(id);
        assertEq(usdc.balanceOf(landlord), 2 * uint256(RENT));

        vm.warp(start + 3 * uint256(PERIOD)); // last period
        escrow.claimRent(id);
        assertEq(usdc.balanceOf(landlord), 3 * uint256(RENT));
        assertEq(escrow.escrowBalance(id), DEPOSIT);
    }

    function test_ClaimRent_CappedAtTerm() public {
        uint256 id = _createAndFund();
        vm.warp(block.timestamp + 10 * uint256(PERIOD));
        (uint16 n, uint256 amt) = escrow.claimable(id);
        assertEq(n, PERIODS);
        assertEq(amt, uint256(RENT) * PERIODS);
        escrow.claimRent(id);
        assertEq(escrow.escrowBalance(id), DEPOSIT); // the deposit is never claimable as rent
        assertEq(escrow.tenantStats(tenant).periodsPaid, PERIODS);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NothingToClaim.selector, id));
        escrow.claimRent(id);
    }

    function test_ClaimRent_RevertsUnlessActive() public {
        uint256 id = _create();
        vm.expectRevert(_invalidState(id, IRentEscrow.State.CREATED));
        escrow.claimRent(id);

        _fund(id);
        vm.warp(block.timestamp + 2 * uint256(PERIOD));
        _dispute(id);
        // Frozen while disputed: nothing is claimable even though two periods elapsed.
        (uint16 n, uint256 amt) = escrow.claimable(id);
        assertEq(n, 0);
        assertEq(amt, 0);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.DISPUTED));
        escrow.claimRent(id);
    }

    function testFuzz_Claimable_MatchesElapsedPeriods(uint256 dt, uint256 claimAt) public {
        uint256 id = _createAndFund();
        uint256 start = escrow.getLease(id).startTime;
        dt = bound(dt, 0, (uint256(PERIODS) + 3) * PERIOD);
        claimAt = bound(claimAt, 0, dt);

        // An intermediate claim must not change what is released in total.
        vm.warp(start + claimAt);
        (uint16 early,) = escrow.claimable(id);
        if (early > 0) escrow.claimRent(id);

        vm.warp(start + dt);
        uint256 elapsed = dt / PERIOD;
        if (elapsed > PERIODS) elapsed = PERIODS;
        (uint16 n, uint256 amt) = escrow.claimable(id);
        assertEq(uint256(n) + early, elapsed);
        assertEq(amt, uint256(n) * RENT);
        assertEq(usdc.balanceOf(landlord), uint256(early) * RENT);
    }

    // ------------------------------------------------------------------ endTime

    function test_EndTime() public {
        uint256 id = _create();
        assertEq(escrow.endTime(id), 0);
        assertEq(escrow.endTime(42), 0);
        _fund(id);
        assertEq(escrow.endTime(id), block.timestamp + 3 days);
    }

    // ------------------------------------------------------------------ closeLease

    function test_CloseLease_RevertsBeforeTermEnds() public {
        uint256 id = _createAndFund();
        vm.warp(escrow.endTime(id) - 1);
        vm.prank(landlord);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.TermNotOver.selector, id));
        escrow.closeLease(id);
    }

    function test_CloseLease_LandlordAtEndPaysRestOfRentAndReturnsDeposit() public {
        uint256 id = _createAndFund();
        vm.warp(block.timestamp + PERIOD);
        escrow.claimRent(id); // one period released early

        vm.warp(escrow.endTime(id));
        vm.expectEmit(address(escrow));
        emit IRentEscrow.LeaseClosed(id, tenant, DEPOSIT, 2 * uint256(RENT));
        vm.prank(landlord);
        escrow.closeLease(id);

        IRentEscrow.Lease memory l = escrow.getLease(id);
        assertEq(uint8(l.state), uint8(IRentEscrow.State.CLOSED));
        assertEq(l.periodsClaimed, PERIODS);
        assertEq(escrow.escrowBalance(id), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(landlord), uint256(RENT) * PERIODS);
        assertEq(usdc.balanceOf(tenant), DEPOSIT);

        IRentEscrow.TenantStats memory s = escrow.tenantStats(tenant);
        assertEq(s.leasesFunded, 1);
        assertEq(s.leasesCompleted, 1);
        assertEq(s.leasesDisputed, 0);
        assertEq(s.periodsPaid, PERIODS);
        assertEq(s.rentPaid, uint256(RENT) * PERIODS);
        assertEq(s.depositsPosted, DEPOSIT);
        assertEq(s.depositsReturned, DEPOSIT);
    }

    function test_CloseLease_OthersMustWaitOneGracePeriod() public {
        uint256 id = _createAndFund();
        uint256 end = escrow.endTime(id);

        vm.warp(end);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.TermNotOver.selector, id));
        escrow.closeLease(id);
        vm.warp(end + PERIOD - 1);
        vm.prank(tenant);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.TermNotOver.selector, id));
        escrow.closeLease(id);

        vm.warp(end + PERIOD);
        vm.prank(stranger);
        escrow.closeLease(id);
        assertEq(usdc.balanceOf(tenant), DEPOSIT);
        assertEq(usdc.balanceOf(landlord), uint256(RENT) * PERIODS);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    function test_CloseLease_LandlordCanDisputeDepositDuringGrace() public {
        uint256 id = _createAndFund();
        vm.warp(escrow.endTime(id));
        vm.prank(landlord);
        escrow.openDispute(id);

        vm.warp(block.timestamp + PERIOD);
        vm.prank(tenant);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.DISPUTED));
        escrow.closeLease(id);
    }

    function test_CloseLease_RevertsUnlessActive() public {
        uint256 id = _create();
        vm.prank(landlord);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.CREATED));
        escrow.closeLease(id);

        _fund(id);
        vm.warp(escrow.endTime(id));
        vm.prank(landlord);
        escrow.closeLease(id);
        vm.prank(landlord);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.CLOSED));
        escrow.closeLease(id);
    }

    // ------------------------------------------------------------------ openDispute

    function test_OpenDispute_ByTenant() public {
        uint256 id = _createAndFund();
        vm.expectEmit(address(escrow));
        emit IRentEscrow.DisputeOpened(id, tenant);
        vm.prank(tenant);
        escrow.openDispute(id);
        assertEq(uint8(escrow.getLease(id).state), uint8(IRentEscrow.State.DISPUTED));
        assertEq(escrow.tenantStats(tenant).leasesDisputed, 1);
        assertEq(escrow.escrowBalance(id), TOTAL); // nothing moves until the arbiter rules
    }

    function test_OpenDispute_ByLandlordCountsOnTenantRecord() public {
        uint256 id = _createAndFund();
        vm.expectEmit(address(escrow));
        emit IRentEscrow.DisputeOpened(id, landlord);
        vm.prank(landlord);
        escrow.openDispute(id);
        assertEq(escrow.tenantStats(tenant).leasesDisputed, 1);
        assertEq(escrow.tenantStats(landlord).leasesDisputed, 0);
    }

    function test_OpenDispute_RevertsForNonParty() public {
        uint256 id = _createAndFund();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotParty.selector, id));
        escrow.openDispute(id);
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotParty.selector, id));
        escrow.openDispute(id);
    }

    function test_OpenDispute_RevertsUnlessActive() public {
        uint256 id = _create();
        vm.prank(tenant);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.CREATED));
        escrow.openDispute(id);

        _fund(id);
        _dispute(id);
        vm.prank(landlord);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.DISPUTED));
        escrow.openDispute(id);
    }

    // ------------------------------------------------------------------ resolveDispute

    function test_ResolveDispute_RevertsForNonArbiter() public {
        uint256 id = _createAndFund();
        _dispute(id);
        vm.prank(landlord);
        vm.expectRevert(IRentEscrow.NotArbiter.selector);
        escrow.resolveDispute(id, 0);
        vm.prank(tenant);
        vm.expectRevert(IRentEscrow.NotArbiter.selector);
        escrow.resolveDispute(id, 10_000);
    }

    function test_ResolveDispute_RevertsOnBpsAbove10000() public {
        uint256 id = _createAndFund();
        _dispute(id);
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.InvalidBps.selector, uint16(10_001)));
        escrow.resolveDispute(id, 10_001);
    }

    function test_ResolveDispute_RevertsUnlessDisputed() public {
        uint256 id = _createAndFund();
        vm.prank(arbiter);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.ACTIVE));
        escrow.resolveDispute(id, 5_000);

        _dispute(id);
        vm.prank(arbiter);
        escrow.resolveDispute(id, 5_000);
        vm.prank(arbiter);
        vm.expectRevert(_invalidState(id, IRentEscrow.State.CLOSED));
        escrow.resolveDispute(id, 5_000);
    }

    function test_ResolveDispute_ZeroBpsAllToLandlord() public {
        uint256 id = _createAndFund();
        vm.warp(block.timestamp + PERIOD); // elapsed-but-unclaimed rent is frozen into the split
        _dispute(id);

        vm.expectEmit(address(escrow));
        emit IRentEscrow.DisputeResolved(id, 0, 0, TOTAL);
        vm.prank(arbiter);
        escrow.resolveDispute(id, 0);

        assertEq(usdc.balanceOf(landlord), TOTAL);
        assertEq(usdc.balanceOf(tenant), 0);
        assertEq(usdc.balanceOf(arbiter), 0);
        assertEq(escrow.escrowBalance(id), 0);
        assertEq(uint8(escrow.getLease(id).state), uint8(IRentEscrow.State.CLOSED));

        IRentEscrow.TenantStats memory s = escrow.tenantStats(tenant);
        assertEq(s.leasesCompleted, 0);
        assertEq(s.leasesDisputed, 1);
        assertEq(s.depositsPosted, DEPOSIT);
        assertEq(s.depositsReturned, 0);
    }

    function test_ResolveDispute_HalfSplitAfterPartialClaim() public {
        uint256 id = _createAndFund();
        vm.warp(block.timestamp + PERIOD);
        escrow.claimRent(id);
        _dispute(id);

        uint256 remaining = TOTAL - RENT; // 500 USDC
        uint256 toTenant = remaining / 2;
        vm.expectEmit(address(escrow));
        emit IRentEscrow.DisputeResolved(id, 5_000, toTenant, remaining - toTenant);
        vm.prank(arbiter);
        escrow.resolveDispute(id, 5_000);

        assertEq(usdc.balanceOf(tenant), toTenant);
        assertEq(usdc.balanceOf(landlord), RENT + (remaining - toTenant));
        assertEq(usdc.balanceOf(address(escrow)), 0);

        IRentEscrow.TenantStats memory s = escrow.tenantStats(tenant);
        assertEq(s.leasesCompleted, 0);
        assertEq(s.periodsPaid, 1); // only the claimed period counts as rent paid
        assertEq(s.rentPaid, RENT);
        assertEq(s.depositsPosted, DEPOSIT);
        // 250 to the tenant: 200 refunds the 2 unearned periods, only 50 is deposit coming back.
        assertEq(s.depositsReturned, toTenant - 2 * uint256(RENT));
    }

    function test_ResolveDispute_RefundingUnusedRentIsNotADepositReturn() public {
        uint256 id = _createAndFund();
        vm.prank(landlord);
        escrow.openDispute(id); // at move-in: no rent earned yet

        // The landlord keeps the whole 300 deposit; the tenant only gets its 3 x 100 prepaid rent back.
        vm.prank(arbiter);
        escrow.resolveDispute(id, 5_000);
        assertEq(usdc.balanceOf(tenant), uint256(RENT) * PERIODS);
        assertEq(usdc.balanceOf(landlord), DEPOSIT);

        IRentEscrow.TenantStats memory s = escrow.tenantStats(tenant);
        assertEq(s.depositsPosted, DEPOSIT);
        assertEq(s.depositsReturned, 0); // a forfeited deposit, not a 100% return rate
    }

    function test_ResolveDispute_DepositReturnedWhileEarnedRentUnclaimed() public {
        uint256 id = _createAndFund();
        uint256 end = escrow.endTime(id);
        vm.warp(end); // all rent earned, none of it claimed
        vm.prank(landlord);
        escrow.openDispute(id); // disputes the deposit in the grace window
        vm.warp(end + 30 days); // a slow arbiter changes nothing: earned rent is fixed at dispute time

        // The landlord keeps the earned rent, the tenant gets the whole deposit back.
        vm.prank(arbiter);
        escrow.resolveDispute(id, 5_000);
        assertEq(usdc.balanceOf(tenant), DEPOSIT);
        assertEq(usdc.balanceOf(landlord), uint256(RENT) * PERIODS);
        assertEq(escrow.tenantStats(tenant).depositsReturned, DEPOSIT);
    }

    function test_ResolveDispute_FullBpsAllToTenantCapsDepositsReturned() public {
        uint256 id = _createAndFund();
        _dispute(id);
        vm.expectEmit(address(escrow));
        emit IRentEscrow.DisputeResolved(id, 10_000, TOTAL, 0);
        vm.prank(arbiter);
        escrow.resolveDispute(id, 10_000);

        assertEq(usdc.balanceOf(tenant), TOTAL);
        assertEq(usdc.balanceOf(landlord), 0);
        IRentEscrow.TenantStats memory s = escrow.tenantStats(tenant);
        assertEq(s.depositsPosted, DEPOSIT);
        assertEq(s.depositsReturned, DEPOSIT); // min(toTenant, deposit)
    }

    function testFuzz_ResolveDispute_PaysOutExactlyRemainingEscrow(
        uint16 bps,
        uint256 dt,
        bool claimFirst,
        uint256 ruleDelay
    ) public {
        bps = uint16(bound(bps, 0, 10_000));
        uint256 id = _createAndFund();
        uint256 start = escrow.getLease(id).startTime;
        dt = bound(dt, 0, 5 * uint256(PERIOD));
        vm.warp(start + dt);
        (uint16 n,) = escrow.claimable(id);
        if (claimFirst && n > 0) escrow.claimRent(id);
        _dispute(id);
        vm.warp(start + dt + bound(ruleDelay, 0, 10 * uint256(PERIOD))); // rent stays frozen meanwhile

        uint256 remaining = escrow.escrowBalance(id);
        uint256 landlordBefore = usdc.balanceOf(landlord);
        vm.prank(arbiter);
        escrow.resolveDispute(id, bps);

        uint256 toTenant = usdc.balanceOf(tenant);
        uint256 toLandlord = usdc.balanceOf(landlord) - landlordBefore;
        assertEq(toTenant + toLandlord, remaining);
        assertEq(toTenant, remaining * bps / 10_000);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.escrowBalance(id), 0);

        // depositsReturned: the payout refunds rent unearned at dispute time first, then the deposit.
        uint256 earned = dt / PERIOD > PERIODS ? PERIODS : dt / PERIOD;
        uint256 unearned = uint256(RENT) * (PERIODS - earned);
        uint256 depositBack = toTenant > unearned ? toTenant - unearned : 0;
        if (depositBack > DEPOSIT) depositBack = DEPOSIT;
        assertEq(escrow.tenantStats(tenant).depositsReturned, depositBack);
    }

    // ------------------------------------------------------------------ multi-lease accounting

    function test_Stats_AccumulateAcrossLeases() public {
        uint256 a = _createAndFund(); // closes normally
        uint256 b = _createAndFund(); // disputed, split 50/50

        vm.warp(block.timestamp + PERIOD);
        escrow.claimRent(b);
        vm.prank(landlord);
        escrow.openDispute(b);
        vm.prank(arbiter);
        escrow.resolveDispute(b, 5_000);

        vm.warp(escrow.endTime(a));
        vm.prank(landlord);
        escrow.closeLease(a);

        uint256 bToTenant = (TOTAL - RENT) / 2; // 250: 200 unearned rent refunded + 50 of the deposit
        IRentEscrow.TenantStats memory s = escrow.tenantStats(tenant);
        assertEq(s.leasesFunded, 2);
        assertEq(s.leasesCompleted, 1);
        assertEq(s.leasesDisputed, 1);
        assertEq(s.periodsPaid, PERIODS + 1);
        assertEq(s.rentPaid, uint256(RENT) * (PERIODS + 1));
        assertEq(s.depositsPosted, 2 * uint256(DEPOSIT));
        assertEq(s.depositsReturned, DEPOSIT + (bToTenant - 2 * uint256(RENT)));
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_EscrowBalancesAreSegregatedPerLease() public {
        address landlord2 = makeAddr("landlord2");
        address tenant2 = makeAddr("tenant2");
        vm.prank(issuer);
        shares.setAllowlist(landlord2, true);

        uint256 a = _createAndFund();
        vm.prank(landlord2);
        uint256 b = escrow.createLease(tenant2, 50e6, 10e6, 60, 5);
        usdc.mint(tenant2, 100e6);
        vm.startPrank(tenant2);
        usdc.approve(address(escrow), 100e6);
        escrow.fundLease(b);
        vm.stopPrank();

        assertEq(escrow.escrowBalance(a) + escrow.escrowBalance(b), usdc.balanceOf(address(escrow)));

        // Resolving lease b in full for its tenant cannot touch lease a's funds.
        vm.prank(tenant2);
        escrow.openDispute(b);
        vm.prank(arbiter);
        escrow.resolveDispute(b, 10_000);
        assertEq(usdc.balanceOf(tenant2), 100e6);
        assertEq(escrow.escrowBalance(a), TOTAL);
        assertEq(usdc.balanceOf(address(escrow)), TOTAL);
    }
}
