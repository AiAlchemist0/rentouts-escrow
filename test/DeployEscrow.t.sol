// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployEscrow, GateChoice} from "../script/DeployEscrow.s.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {HumanGate} from "../src/HumanGate.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";
import {MockHumanVerifier} from "./helpers/MockHumanVerifier.sol";

/// @dev An arbiter that is a contract (as a Safe would be): it resolves disputes by calling the escrow.
contract ContractArbiter {
    function resolve(RentEscrow escrow, uint256 leaseId, uint16 tenantBps) external {
        escrow.resolveDispute(leaseId, tenantBps);
    }
}

/// @notice script/DeployEscrow.s.sol on a local chain that reports Sepolia's chain id: the config
///         checks, and that the deployed system is wired the way the README demo expects.
contract DeployEscrowTest is Test {
    DeployEscrow internal script;
    MockUSDC internal usdc;

    address internal deployer = makeAddr("deployer"); // also the demo landlord
    address internal arbiter = makeAddr("arbiter");
    address internal tenant = makeAddr("tenant");

    string internal constant SCRATCH_DIR = "./cache/deploy-escrow-test";
    // one scratch file per test: forge runs tests in parallel
    string internal constant UPSERT_FILE = "./cache/deploy-escrow-test/upsert.json";
    string internal constant MISSING_FILE = "./cache/deploy-escrow-test/missing.json";

    function setUp() public {
        vm.chainId(11155111);
        script = new DeployEscrow();
        usdc = new MockUSDC();
    }

    /// @dev The default deploy: a new open HumanGate, and a new LeaseShare1155 unless `existingShares`.
    function _deploy(address arbiter_, address existingShares)
        internal
        returns (RentEscrow escrow, LeaseShare1155 shares)
    {
        (escrow, shares,) =
            script.deploy(deployer, address(usdc), arbiter_, existingShares, GateChoice.DeployNew, address(0));
    }

    // ------------------------------------------------------------------ wiring

    function test_Deploy_NewShares_WiresEscrowAndDeployerCanList() public {
        (RentEscrow escrow, LeaseShare1155 shares, address gate) =
            script.deploy(deployer, address(usdc), arbiter, address(0), GateChoice.DeployNew, address(0));

        assertEq(escrow.token(), address(usdc));
        assertEq(escrow.arbiter(), arbiter);
        assertEq(escrow.leaseShare(), address(shares));
        assertEq(shares.owner(), deployer);
        assertEq(shares.minter(), address(escrow));
        assertTrue(shares.allowlisted(deployer));
        // The default human gate: new, owned by the deployer, open until a verifier is plugged in.
        assertEq(escrow.humanGate(), gate);
        assertEq(HumanGate(gate).owner(), deployer);
        assertEq(address(HumanGate(gate).verifier()), address(0));

        vm.prank(deployer);
        assertEq(escrow.createLease(tenant, 300000, 100000, 60, 3), 1); // the README demo lease
        assertEq(shares.balanceOf(deployer, 1), 100);
        usdc.mint(tenant, 600000);
        vm.startPrank(tenant);
        usdc.approve(address(escrow), 600000);
        escrow.fundLease(1); // open gate: the demo tenant needs no World ID yet
        vm.stopPrank();

        // Plugging World in later is one call by the deployer on the gate; the escrow stays.
        MockHumanVerifier world = new MockHumanVerifier();
        vm.prank(deployer);
        HumanGate(gate).setVerifier(address(world));
        vm.prank(deployer);
        escrow.createLease(tenant, 300000, 100000, 60, 3);
        usdc.mint(tenant, 600000);
        vm.startPrank(tenant);
        usdc.approve(address(escrow), 600000);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotVerifiedHuman.selector, tenant));
        escrow.fundLease(2);
        vm.stopPrank();
    }

    function test_Deploy_GateNone_FundingNeverGated() public {
        (RentEscrow escrow,, address gate) =
            script.deploy(deployer, address(usdc), arbiter, address(0), GateChoice.None, address(0));
        assertEq(gate, address(0));
        assertEq(escrow.humanGate(), address(0));
    }

    function test_Deploy_GateExisting_IsWiredAsIs() public {
        HumanGate existing = new HumanGate(makeAddr("gate-owner"), address(0));
        (RentEscrow escrow,, address gate) =
            script.deploy(deployer, address(usdc), arbiter, address(0), GateChoice.Existing, address(existing));
        assertEq(gate, address(existing));
        assertEq(escrow.humanGate(), address(existing));
    }

    function test_Deploy_GateExisting_RevertsUnlessItAnswersIsVerified() public {
        vm.expectRevert(bytes("DeployEscrow: ESCROW_HUMAN_GATE has no code on this chain"));
        script.deploy(deployer, address(usdc), arbiter, address(0), GateChoice.Existing, makeAddr("no-code"));

        // A contract that is not a gate (no isVerified): refused before anything is deployed.
        vm.expectRevert(bytes("DeployEscrow: ESCROW_HUMAN_GATE does not answer isVerified(address)"));
        script.deploy(deployer, address(usdc), arbiter, address(0), GateChoice.Existing, address(usdc));
    }

    function test_GateFromEnv() public {
        (GateChoice c, address g) = script.gateFromEnv("");
        assertEq(uint8(c), uint8(GateChoice.DeployNew));
        assertEq(g, address(0));
        (c, g) = script.gateFromEnv("new");
        assertEq(uint8(c), uint8(GateChoice.DeployNew));
        (c, g) = script.gateFromEnv("none");
        assertEq(uint8(c), uint8(GateChoice.None));
        assertEq(g, address(0));
        (c, g) = script.gateFromEnv("0x0000000000000000000000000000000000000000");
        assertEq(uint8(c), uint8(GateChoice.None));
        (c, g) = script.gateFromEnv("0xBB8A105f48Ac836F549eC0B6A1a45BB7BA0961E5");
        assertEq(uint8(c), uint8(GateChoice.Existing));
        assertEq(g, 0xBB8A105f48Ac836F549eC0B6A1a45BB7BA0961E5);
    }

    function test_Deploy_ArbiterMayBeAContract() public {
        ContractArbiter safe = new ContractArbiter();
        (RentEscrow escrow,) = _deploy(address(safe), address(0));
        assertEq(escrow.arbiter(), address(safe));

        vm.prank(deployer);
        uint256 id = escrow.createLease(tenant, 300000, 100000, 60, 3);
        usdc.mint(tenant, 600000);
        vm.startPrank(tenant);
        usdc.approve(address(escrow), 600000);
        escrow.fundLease(id);
        escrow.openDispute(id);
        vm.stopPrank();

        safe.resolve(escrow, id, 10_000);
        assertEq(usdc.balanceOf(tenant), 600000);
        assertEq(usdc.balanceOf(address(safe)), 0);
    }

    // ------------------------------------------------------------------ config checks

    function test_Deploy_RevertsWhenArbiterIsTheDeployer() public {
        // deployer == arbiter would make the only allowlisted landlord the arbiter.
        vm.expectRevert(bytes("DeployEscrow: ESCROW_ARBITER must not be the deployer (the demo landlord)"));
        _deploy(deployer, address(0));
    }

    function test_Deploy_RevertsOnBadConfig() public {
        vm.expectRevert(bytes("DeployEscrow: ESCROW_ARBITER is zero"));
        _deploy(address(0), address(0));

        vm.expectRevert(bytes("DeployEscrow: ESCROW_TOKEN has no code on this chain"));
        script.deploy(deployer, makeAddr("no-code"), arbiter, address(0), GateChoice.DeployNew, address(0));

        LeaseShare1155 notOwned = new LeaseShare1155(makeAddr("someone-else"), "");
        vm.expectRevert(bytes("DeployEscrow: deployer must own LEASE_SHARE"));
        _deploy(arbiter, address(notOwned));

        vm.chainId(84532); // Base Sepolia
        vm.expectRevert(bytes("DeployEscrow: Ethereum Sepolia (11155111) only"));
        _deploy(arbiter, address(0));
    }

    function test_Deploy_ExistingShares_UnusedOneIsWired() public {
        LeaseShare1155 existing = new LeaseShare1155(deployer, "");
        (RentEscrow escrow, LeaseShare1155 shares) = _deploy(arbiter, address(existing));
        assertEq(address(shares), address(existing));
        assertEq(existing.minter(), address(escrow));
        vm.prank(deployer);
        assertEq(escrow.createLease(tenant, 300000, 100000, 60, 3), 1);
    }

    function test_Deploy_ExistingShares_RevertsIfAlreadyWiredToAnEscrow() public {
        // First deploy: escrow e1 lists lease 1 (tokenId 1).
        (RentEscrow e1, LeaseShare1155 shares) = _deploy(arbiter, address(0));
        vm.prank(deployer);
        e1.createLease(tenant, 300000, 100000, 60, 3);

        // Redeploying the escrow on the same share contract would mint a second lease 1 under
        // tokenId 1 and make e1 unable to list: refused.
        vm.expectRevert(bytes("DeployEscrow: LEASE_SHARE already wired to an escrow"));
        _deploy(arbiter, address(shares));

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
        _deploy(arbiter, address(existing));
    }

    function test_Deploy_ArbiterCannotBeAPartyOnTheDeployedEscrow() public {
        (RentEscrow escrow,) = _deploy(arbiter, address(0));
        vm.prank(deployer);
        vm.expectRevert(IRentEscrow.InvalidTerms.selector);
        escrow.createLease(arbiter, 300000, 100000, 60, 3);
    }

    // ------------------------------------------------------------------ deployment record

    function test_Run_DoesNotRecordDeploymentsOutsideABroadcast() public {
        vm.setEnv("ESCROW_ARBITER", vm.toString(arbiter));
        vm.setEnv("ESCROW_TOKEN", vm.toString(address(usdc)));
        vm.setEnv("LEASE_SHARE", vm.toString(address(0)));
        vm.setEnv("ESCROW_HUMAN_GATE", "");
        vm.setEnv("BROADCAST", "true"); // an env flag alone must never trigger a write
        string memory file = script.DEPLOYMENTS_FILE();
        bool existed = vm.exists(file);
        string memory before = existed ? vm.readFile(file) : "";

        (RentEscrow escrow,, address gate) = script.run(); // not a --broadcast run: nothing reaches the chain
        assertEq(escrow.arbiter(), arbiter);
        assertEq(escrow.humanGate(), gate);
        assertTrue(gate != address(0));

        assertEq(vm.exists(file), existed, "deployments.json created outside a broadcast");
        if (existed) assertEq(vm.readFile(file), before, "deployments.json rewritten outside a broadcast");
    }

    /// The record is a read-modify-write of the "sepolia" key: Dean's "baseSepolia" entry survives,
    /// and re-recording replaces the sepolia entry instead of adding a second one.
    function test_Record_UpsertsSepoliaAndKeepsBaseSepolia() public {
        vm.createDir(SCRATCH_DIR, true);
        vm.copyFile(script.DEPLOYMENTS_FILE(), UPSERT_FILE);
        string memory original = vm.readFile(UPSERT_FILE);
        address baseShare = vm.parseJsonAddress(original, ".baseSepolia.LeaseShare1155.address");
        string memory baseTx = vm.parseJsonString(original, ".baseSepolia.LeaseShare1155.deployTx");

        address[5] memory a =
            [makeAddr("token"), makeAddr("arb"), makeAddr("gate"), makeAddr("escrow"), makeAddr("shares")];
        script.record(UPSERT_FILE, deployer, a[0], a[1], a[2], a[3], a[4]);
        script.record(UPSERT_FILE, deployer, a[0], a[1], a[2], makeAddr("escrow2"), a[4]); // a redeploy

        string memory json = vm.readFile(UPSERT_FILE);
        assertEq(vm.parseJsonUint(json, ".baseSepolia.chainId"), 84532);
        assertEq(vm.parseJsonAddress(json, ".baseSepolia.LeaseShare1155.address"), baseShare);
        assertEq(vm.parseJsonString(json, ".baseSepolia.LeaseShare1155.deployTx"), baseTx);

        assertEq(vm.parseJsonUint(json, ".sepolia.chainId"), 11155111);
        assertEq(vm.parseJsonAddress(json, ".sepolia.deployer"), deployer);
        assertEq(vm.parseJsonAddress(json, ".sepolia.token"), a[0]);
        assertEq(vm.parseJsonAddress(json, ".sepolia.arbiter"), a[1]);
        assertEq(vm.parseJsonAddress(json, ".sepolia.humanGate"), a[2]);
        assertEq(vm.parseJsonAddress(json, ".sepolia.rentEscrow"), makeAddr("escrow2"));
        assertEq(vm.parseJsonAddress(json, ".sepolia.leaseShare1155"), a[4]);

        // Only the "sepolia" entry is added (or replaced): other entries, e.g. DeployAIArbiter's
        // "sepoliaAIArbiter", are kept as they are.
        uint256 before = vm.parseJsonKeys(original, "$").length;
        uint256 added = vm.keyExists(original, ".sepolia") ? 0 : 1;
        assertEq(vm.parseJsonKeys(json, "$").length, before + added, "record added more than the sepolia entry");
        vm.removeFile(UPSERT_FILE);
    }

    function test_Record_CreatesAMissingFile() public {
        vm.createDir(SCRATCH_DIR, true);
        if (vm.exists(MISSING_FILE)) vm.removeFile(MISSING_FILE);
        script.record(MISSING_FILE, deployer, address(usdc), arbiter, address(0), makeAddr("escrow"), address(0));
        string memory json = vm.readFile(MISSING_FILE);
        assertEq(vm.parseJsonAddress(json, ".sepolia.rentEscrow"), makeAddr("escrow"));
        assertEq(vm.parseJsonAddress(json, ".sepolia.humanGate"), address(0));
        vm.removeFile(MISSING_FILE);
    }
}
