// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployAIArbiter} from "../script/DeployAIArbiter.s.sol";
import {DeployEscrow, GateChoice} from "../script/DeployEscrow.s.sol";
import {AIArbiter} from "../src/AIArbiter.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";

/// @notice script/DeployAIArbiter.s.sol on a local chain that reports Sepolia's chain id: config
///         checks, the documented deploy order (AIArbiter -> RentEscrow -> bindEscrow) and the record.
contract DeployAIArbiterTest is Test {
    DeployAIArbiter internal script;
    MockUSDC internal usdc;

    address internal deployer = makeAddr("deployer"); // also the demo landlord
    address internal human = makeAddr("human");
    address internal agent = makeAddr("agent");
    address internal tenant = makeAddr("tenant");

    string internal constant SCRATCH_DIR = "./cache/deploy-ai-arbiter-test";
    string internal constant UPSERT_FILE = "./cache/deploy-ai-arbiter-test/upsert.json";
    string internal constant MISSING_FILE = "./cache/deploy-ai-arbiter-test/missing.json";

    function setUp() public {
        vm.chainId(11155111);
        script = new DeployAIArbiter();
        usdc = new MockUSDC();
    }

    function test_Deploy_ThenEscrowThenBind_EndToEnd() public {
        AIArbiter arb = script.deploy(deployer, human, agent, 120);
        assertEq(arb.human(), human);
        assertEq(arb.agent(), agent);
        assertEq(arb.challengeWindow(), 120);
        assertEq(address(arb.escrow()), address(0));

        // DeployEscrow with ESCROW_ARBITER = the AIArbiter (a contract arbiter is accepted).
        DeployEscrow escrowScript = new DeployEscrow();
        (RentEscrow escrow, LeaseShare1155 shares,) =
            escrowScript.deploy(deployer, address(usdc), address(arb), address(0), GateChoice.DeployNew, address(0));
        assertEq(escrow.arbiter(), address(arb));
        assertTrue(shares.allowlisted(deployer));

        vm.prank(human);
        arb.bindEscrow(escrow);
        assertEq(address(arb.escrow()), address(escrow));

        // The README demo lease, disputed, AI proposal, window, execute.
        vm.prank(deployer);
        uint256 id = escrow.createLease(tenant, 300000, 100000, 60, 3);
        usdc.mint(tenant, 600000);
        vm.startPrank(tenant);
        usdc.approve(address(escrow), 600000);
        escrow.fundLease(id);
        escrow.openDispute(id);
        vm.stopPrank();
        vm.prank(agent);
        arb.propose(id, 10_000, keccak256("ruling"), 9000, "Deposit and unused rent back to the tenant.");
        vm.warp(vm.getBlockTimestamp() + 120);
        arb.execute(id);
        assertEq(usdc.balanceOf(tenant), 600000);
    }

    function test_Deploy_RevertsOnBadConfig() public {
        vm.expectRevert(bytes("DeployAIArbiter: AI_HUMAN is zero"));
        script.deploy(deployer, address(0), agent, 120);
        vm.expectRevert(bytes("DeployAIArbiter: AI_AGENT is required (the judge service address)"));
        script.deploy(deployer, human, address(0), 120);
        vm.expectRevert(bytes("DeployAIArbiter: AI_AGENT must not be AI_HUMAN"));
        script.deploy(deployer, human, human, 120);
        vm.expectRevert(bytes("DeployAIArbiter: AI_HUMAN must not be the deployer (the demo landlord)"));
        script.deploy(deployer, deployer, agent, 120);
        vm.expectRevert(bytes("DeployAIArbiter: AI_AGENT must not be the deployer (the demo landlord)"));
        script.deploy(deployer, human, deployer, 120);
        vm.expectRevert(bytes("DeployAIArbiter: AI_CHALLENGE_WINDOW must be 60 s .. 30 days"));
        script.deploy(deployer, human, agent, 59);
        vm.expectRevert(bytes("DeployAIArbiter: AI_CHALLENGE_WINDOW must be 60 s .. 30 days"));
        script.deploy(deployer, human, agent, 30 days + 1);

        vm.chainId(84532); // Base Sepolia
        vm.expectRevert(bytes("DeployAIArbiter: Ethereum Sepolia (11155111) only"));
        script.deploy(deployer, human, agent, 120);
    }

    function test_Run_DefaultsAndNoRecordOutsideABroadcast() public {
        vm.setEnv("AI_AGENT", vm.toString(agent));
        vm.setEnv("AI_HUMAN", vm.toString(script.DEFAULT_HUMAN()));
        vm.setEnv("AI_CHALLENGE_WINDOW", "120");
        vm.setEnv("BROADCAST", "true"); // an env flag alone must never trigger a write
        string memory file = script.DEPLOYMENTS_FILE();
        bool existed = vm.exists(file);
        string memory before = existed ? vm.readFile(file) : "";

        AIArbiter arb = script.run();
        assertEq(arb.human(), 0x798b01Cef62b889943Ce1D3C5011a755B297e486);
        assertEq(arb.agent(), agent);
        assertEq(arb.challengeWindow(), 120);

        assertEq(vm.exists(file), existed, "deployments.json created outside a broadcast");
        if (existed) assertEq(vm.readFile(file), before, "deployments.json rewritten outside a broadcast");
    }

    /// The AIArbiter record survives DeployEscrow's later rewrite of "sepolia" (the documented order),
    /// and neither touches "baseSepolia".
    function test_Record_SurvivesTheEscrowRecordAndKeepsBaseSepolia() public {
        vm.createDir(SCRATCH_DIR, true);
        vm.copyFile(script.DEPLOYMENTS_FILE(), UPSERT_FILE);
        string memory original = vm.readFile(UPSERT_FILE);
        address baseShare = vm.parseJsonAddress(original, ".baseSepolia.LeaseShare1155.address");

        address arb = makeAddr("aiArbiter");
        script.record(UPSERT_FILE, deployer, human, agent, 120, makeAddr("old"));
        script.record(UPSERT_FILE, deployer, human, agent, 120, arb); // a redeploy replaces it
        new DeployEscrow()
            .record(UPSERT_FILE, deployer, address(usdc), arb, makeAddr("gate"), makeAddr("escrow"), makeAddr("shares"));

        string memory json = vm.readFile(UPSERT_FILE);
        assertEq(vm.parseJsonAddress(json, ".baseSepolia.LeaseShare1155.address"), baseShare);
        assertEq(vm.parseJsonUint(json, ".sepoliaAIArbiter.chainId"), 11155111);
        assertEq(vm.parseJsonAddress(json, ".sepoliaAIArbiter.aiArbiter"), arb);
        assertEq(vm.parseJsonAddress(json, ".sepoliaAIArbiter.human"), human);
        assertEq(vm.parseJsonAddress(json, ".sepoliaAIArbiter.agent"), agent);
        assertEq(vm.parseJsonAddress(json, ".sepoliaAIArbiter.deployer"), deployer);
        assertEq(vm.parseJsonUint(json, ".sepoliaAIArbiter.challengeWindow"), 120);
        assertEq(vm.parseJsonAddress(json, ".sepolia.arbiter"), arb);
        assertEq(vm.parseJsonAddress(json, ".sepolia.rentEscrow"), makeAddr("escrow"));
        vm.removeFile(UPSERT_FILE);
    }

    function test_Record_CreatesAMissingFile() public {
        vm.createDir(SCRATCH_DIR, true);
        if (vm.exists(MISSING_FILE)) vm.removeFile(MISSING_FILE);
        script.record(MISSING_FILE, deployer, human, agent, 600, makeAddr("aiArbiter"));
        string memory json = vm.readFile(MISSING_FILE);
        assertEq(vm.parseJsonAddress(json, ".sepoliaAIArbiter.aiArbiter"), makeAddr("aiArbiter"));
        assertEq(vm.parseJsonUint(json, ".sepoliaAIArbiter.challengeWindow"), 600);
        vm.removeFile(MISSING_FILE);
    }
}
