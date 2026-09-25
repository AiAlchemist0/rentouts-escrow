// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployEscrow} from "../script/DeployEscrow.s.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";

/// @notice script/DeployEscrow.s.sol on a local chain that reports Sepolia's chain id: the config
///         checks, and that the deployed system is wired the way the README demo expects.
contract DeployEscrowTest is Test {
    DeployEscrow internal script;
    MockUSDC internal usdc;

    address internal deployer = makeAddr("deployer"); // also the demo landlord
    address internal arbiter = makeAddr("arbiter");
    address internal tenant = makeAddr("tenant");

    function setUp() public {
        vm.chainId(11155111);
        script = new DeployEscrow();
        usdc = new MockUSDC();
    }

    function test_Deploy_NewShares_WiresEscrowAndDeployerCanList() public {
        (RentEscrow escrow, LeaseShare1155 shares) = script.deploy(deployer, address(usdc), arbiter, address(0));

        assertEq(escrow.token(), address(usdc));
        assertEq(escrow.arbiter(), arbiter);
        assertEq(escrow.leaseShare(), address(shares));
        assertEq(shares.owner(), deployer);
        assertEq(shares.minter(), address(escrow));
        assertTrue(shares.allowlisted(deployer));

        vm.prank(deployer);
        assertEq(escrow.createLease(tenant, 300000, 100000, 60, 3), 1); // the README demo lease
        assertEq(shares.balanceOf(deployer, 1), 100);
    }

    function test_Deploy_RevertsWhenArbiterIsTheDeployer() public {
        // deployer == arbiter would make the only allowlisted landlord the arbiter.
        vm.expectRevert(bytes("DeployEscrow: ESCROW_ARBITER must not be the deployer (the demo landlord)"));
        script.deploy(deployer, address(usdc), deployer, address(0));
    }

    function test_Deploy_RevertsOnBadConfig() public {
        vm.expectRevert(bytes("DeployEscrow: ESCROW_ARBITER is zero"));
        script.deploy(deployer, address(usdc), address(0), address(0));

        vm.expectRevert(bytes("DeployEscrow: ESCROW_TOKEN has no code on this chain"));
        script.deploy(deployer, makeAddr("no-code"), arbiter, address(0));

        LeaseShare1155 notOwned = new LeaseShare1155(makeAddr("someone-else"), "");
        vm.expectRevert(bytes("DeployEscrow: deployer must own LEASE_SHARE"));
        script.deploy(deployer, address(usdc), arbiter, address(notOwned));

        vm.chainId(84532); // Base Sepolia
        vm.expectRevert(bytes("DeployEscrow: Ethereum Sepolia (11155111) only"));
        script.deploy(deployer, address(usdc), arbiter, address(0));
    }

    function test_Deploy_ExistingShares_UnusedOneIsWired() public {
        LeaseShare1155 existing = new LeaseShare1155(deployer, "");
        (RentEscrow escrow, LeaseShare1155 shares) = script.deploy(deployer, address(usdc), arbiter, address(existing));
        assertEq(address(shares), address(existing));
        assertEq(existing.minter(), address(escrow));
        vm.prank(deployer);
        assertEq(escrow.createLease(tenant, 300000, 100000, 60, 3), 1);
    }

    function test_Deploy_ExistingShares_RevertsIfAlreadyWiredToAnEscrow() public {
        // First deploy: escrow e1 lists lease 1 (tokenId 1).
        (RentEscrow e1, LeaseShare1155 shares) = script.deploy(deployer, address(usdc), arbiter, address(0));
        vm.prank(deployer);
        e1.createLease(tenant, 300000, 100000, 60, 3);

        // Redeploying the escrow on the same share contract would mint a second lease 1 under
        // tokenId 1 and make e1 unable to list: refused.
        vm.expectRevert(bytes("DeployEscrow: LEASE_SHARE already wired to an escrow"));
        script.deploy(deployer, address(usdc), arbiter, address(shares));

        assertEq(shares.minter(), address(e1));
        assertEq(shares.totalSupply(1), 100);
        vm.prank(deployer);
        assertEq(e1.createLease(tenant, 300000, 100000, 60, 3), 2); // e1 still lists
    }

    function test_Deploy_ExistingShares_RevertsIfTokenIdOneAlreadyMinted() public {
        LeaseShare1155 existing = new LeaseShare1155(deployer, "");
        vm.prank(deployer);
        existing.mintShare(1, deployer, 1); // the owner can mint without an escrow
        vm.expectRevert(bytes("DeployEscrow: LEASE_SHARE already has shares of tokenId 1"));
        script.deploy(deployer, address(usdc), arbiter, address(existing));
    }

    function test_Deploy_ArbiterCannotBeAPartyOnTheDeployedEscrow() public {
        (RentEscrow escrow,) = script.deploy(deployer, address(usdc), arbiter, address(0));
        vm.prank(deployer);
        vm.expectRevert(IRentEscrow.InvalidTerms.selector);
        escrow.createLease(arbiter, 300000, 100000, 60, 3);
    }
}
