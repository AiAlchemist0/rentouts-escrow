// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LeaseShare1155Test is Test {
    LeaseShare1155 internal shares;

    address internal owner = makeAddr("owner");
    address internal escrow = makeAddr("escrow");
    address internal tenant = makeAddr("tenant"); // allowlisted holder
    address internal investor = makeAddr("investor"); // allowlisted holder
    address internal outsider = makeAddr("outsider"); // NOT allowlisted

    uint256 internal constant LEASE_ID = 1;

    function setUp() public {
        vm.prank(owner);
        shares = new LeaseShare1155(owner, "https://rentouts.co/api/lease-share/{id}.json");

        vm.startPrank(owner);
        shares.setMinter(escrow);
        shares.setAllowlist(tenant, true);
        shares.setAllowlist(investor, true);
        vm.stopPrank();
    }

    // --- minting ---

    function test_MintByEscrow_ToAllowlisted_Succeeds() public {
        vm.prank(escrow);
        shares.mintShare(LEASE_ID, tenant, 100);

        assertEq(shares.balanceOf(tenant, LEASE_ID), 100);
        assertEq(shares.totalSupply(LEASE_ID), 100);
    }

    function test_MintByOwner_Succeeds() public {
        vm.prank(owner);
        shares.mintShare(LEASE_ID, investor, 50);
        assertEq(shares.balanceOf(investor, LEASE_ID), 50);
    }

    function test_MintByStranger_Reverts() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(LeaseShare1155.NotMinter.selector, outsider));
        shares.mintShare(LEASE_ID, tenant, 100);
    }

    function test_MintToNonAllowlisted_Reverts() public {
        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSelector(LeaseShare1155.NotAllowlisted.selector, outsider));
        shares.mintShare(LEASE_ID, outsider, 100);
    }

    // --- compliance-aware transfers (the judged behavior) ---

    function test_Transfer_ToAllowlisted_Succeeds() public {
        vm.prank(escrow);
        shares.mintShare(LEASE_ID, tenant, 100);

        vm.prank(tenant);
        shares.safeTransferFrom(tenant, investor, LEASE_ID, 40, "");

        assertEq(shares.balanceOf(tenant, LEASE_ID), 60);
        assertEq(shares.balanceOf(investor, LEASE_ID), 40);
    }

    function test_Transfer_ToNonAllowlisted_Reverts() public {
        vm.prank(escrow);
        shares.mintShare(LEASE_ID, tenant, 100);

        vm.prank(tenant);
        vm.expectRevert(abi.encodeWithSelector(LeaseShare1155.NotAllowlisted.selector, outsider));
        shares.safeTransferFrom(tenant, outsider, LEASE_ID, 10, "");
    }

    function test_Transfer_AfterAllowlistRevoked_Reverts() public {
        vm.prank(escrow);
        shares.mintShare(LEASE_ID, tenant, 100);

        // compliance action: revoke the investor mid-life
        vm.prank(owner);
        shares.setAllowlist(investor, false);

        vm.prank(tenant);
        vm.expectRevert(abi.encodeWithSelector(LeaseShare1155.NotAllowlisted.selector, investor));
        shares.safeTransferFrom(tenant, investor, LEASE_ID, 10, "");
    }

    // --- access control ---

    function test_SetAllowlist_OnlyOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        shares.setAllowlist(outsider, true);
    }

    function test_SetMinter_OnlyOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        shares.setMinter(outsider);
    }

    // --- fuzz: any non-allowlisted recipient is rejected ---

    function testFuzz_TransferToRandom_RejectedUnlessAllowlisted(address to, uint96 amount) public {
        vm.assume(to != address(0));
        vm.assume(amount > 0 && amount <= 1_000_000);

        vm.prank(escrow);
        shares.mintShare(LEASE_ID, tenant, amount);

        // Read allowlist status BEFORE pranking — a view call would otherwise consume the prank.
        bool ok = shares.allowlisted(to);

        if (ok) {
            vm.prank(tenant);
            shares.safeTransferFrom(tenant, to, LEASE_ID, amount, "");
            assertEq(shares.balanceOf(to, LEASE_ID), amount);
        } else {
            vm.prank(tenant);
            vm.expectRevert(abi.encodeWithSelector(LeaseShare1155.NotAllowlisted.selector, to));
            shares.safeTransferFrom(tenant, to, LEASE_ID, amount, "");
        }
    }
}
