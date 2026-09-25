// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {MockBlacklistUSDC} from "./helpers/MockBlacklistUSDC.sol";

/// @notice RentEscrow pays both parties by push. With a token that can blacklist an address (Circle
///         USDC), a blocked party makes every call that pays it revert, including the other party's
///         close. These tests pin the documented limit (README "Honest limits") and the way out:
///         openDispute moves no tokens, so the unblocked party can always open a dispute, and a
///         0 or 10000 bps ruling (all to the unblocked party) settles the lease. If openDispute ever
///         starts paying someone, these tests catch the lease getting stuck for good.
contract RentEscrowBlacklistTest is Test {
    MockBlacklistUSDC internal usdc;
    RentEscrow internal escrow;

    address internal arbiter = makeAddr("arbiter");
    address internal landlord = makeAddr("landlord");
    address internal tenant = makeAddr("tenant");
    address internal keeper = makeAddr("keeper");

    uint128 internal constant DEPOSIT = 300e6;
    uint128 internal constant RENT = 100e6;
    uint32 internal constant PERIOD = 1 days;
    uint16 internal constant PERIODS = 3;
    uint256 internal constant TOTAL = uint256(DEPOSIT) + uint256(RENT) * PERIODS;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockBlacklistUSDC();
        escrow = new RentEscrow(IERC20(address(usdc)), arbiter, address(0), address(0));
    }

    function _createAndFund() internal returns (uint256 id) {
        vm.prank(landlord);
        id = escrow.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
        usdc.mint(tenant, TOTAL);
        vm.startPrank(tenant);
        usdc.approve(address(escrow), TOTAL);
        escrow.fundLease(id);
        vm.stopPrank();
    }

    function _blocked(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockBlacklistUSDC.Blacklisted.selector, account);
    }

    function test_Blacklist_LandlordBlocked_TenantExitsThroughAFullRuling() public {
        uint256 id = _createAndFund();
        vm.warp(escrow.endTime(id) + PERIOD); // past the grace window, all rent still unclaimed
        usdc.blacklist(landlord, true);

        // Every path that pays the landlord is jammed, including the tenant-side close.
        vm.prank(keeper);
        vm.expectRevert(_blocked(landlord));
        escrow.closeLease(id);
        vm.expectRevert(_blocked(landlord));
        escrow.claimRent(id);

        // openDispute moves nothing, so the tenant can still get the lease in front of the arbiter.
        vm.prank(tenant);
        escrow.openDispute(id);

        // Any split still pays the landlord and reverts; only "all to the tenant" pays out.
        vm.prank(arbiter);
        vm.expectRevert(_blocked(landlord));
        escrow.resolveDispute(id, 5_000);
        vm.prank(arbiter);
        escrow.resolveDispute(id, 10_000);

        // The known cost: the landlord's earned rent went to the tenant with the deposit.
        assertEq(usdc.balanceOf(tenant), TOTAL);
        assertEq(usdc.balanceOf(landlord), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(uint8(escrow.getLease(id).state), uint8(IRentEscrow.State.CLOSED));
        assertEq(escrow.tenantStats(tenant).rentPaid, 0);
    }

    function test_Blacklist_TenantBlocked_LandlordExitsThroughAZeroRuling() public {
        uint256 id = _createAndFund();
        vm.warp(escrow.endTime(id));
        usdc.blacklist(tenant, true);

        vm.prank(landlord);
        vm.expectRevert(_blocked(tenant));
        escrow.closeLease(id);

        // Rent only ever goes to the landlord, so claiming still works.
        escrow.claimRent(id);
        assertEq(usdc.balanceOf(landlord), uint256(RENT) * PERIODS);

        vm.prank(landlord);
        escrow.openDispute(id);
        vm.prank(arbiter);
        vm.expectRevert(_blocked(tenant));
        escrow.resolveDispute(id, 5_000);
        vm.prank(arbiter);
        escrow.resolveDispute(id, 0);

        // The known cost: the deposit went to the landlord.
        assertEq(usdc.balanceOf(landlord), TOTAL);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.tenantStats(tenant).depositsReturned, 0);
    }

    function test_Blacklist_LandlordBlockedAfterClaimingAllRent_CloseStillWorks() public {
        uint256 id = _createAndFund();
        vm.warp(escrow.endTime(id));
        escrow.claimRent(id);
        usdc.blacklist(landlord, true);

        // The landlord's leg is zero and skipped, so the tenant's deposit still comes back normally.
        vm.warp(block.timestamp + PERIOD);
        vm.prank(keeper);
        escrow.closeLease(id);
        assertEq(usdc.balanceOf(tenant), DEPOSIT);
        assertEq(escrow.tenantStats(tenant).leasesCompleted, 1);
    }

    function test_Blacklist_OpenDisputeNeverTransfers() public {
        uint256 id = _createAndFund();
        vm.warp(escrow.endTime(id)); // rent earned and unclaimed: nothing may move at dispute time
        usdc.blacklist(landlord, true);
        usdc.blacklist(tenant, true);

        vm.recordLogs();
        vm.prank(tenant);
        escrow.openDispute(id);
        assertEq(vm.getRecordedLogs().length, 1); // DisputeOpened only, no Transfer
        assertEq(escrow.escrowBalance(id), TOTAL);
    }
}
