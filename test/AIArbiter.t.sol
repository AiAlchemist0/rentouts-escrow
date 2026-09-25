// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AIArbiter} from "../src/AIArbiter.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";
import {classifyArbiterCalls} from "./helpers/ArbiterCalls.sol";

/// @notice AIArbiter against the real RentEscrow + MockUSDC: the AI-proposes / human-decides flows,
///         access control, parameter bounds, and that the arbiter only ever calls resolveDispute.
contract AIArbiterTest is Test {
    MockUSDC internal usdc;
    LeaseShare1155 internal shares;
    RentEscrow internal escrow;
    AIArbiter internal arb;

    address internal human = makeAddr("human");
    address internal agent = makeAddr("agent");
    address internal issuer = makeAddr("issuer");
    address internal landlord = makeAddr("landlord");
    address internal tenant = makeAddr("tenant");
    address internal stranger = makeAddr("stranger");

    uint32 internal constant WINDOW = 120;
    uint128 internal constant DEPOSIT = 300e6;
    uint128 internal constant RENT = 100e6;
    uint32 internal constant PERIOD = 1 days;
    uint16 internal constant PERIODS = 3;
    uint256 internal constant TOTAL = uint256(DEPOSIT) + uint256(RENT) * PERIODS;
    bytes32 internal constant HASH = keccak256("canonical ruling json");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        shares = new LeaseShare1155(issuer, "");
        arb = new AIArbiter(human, agent, WINDOW);
        escrow = new RentEscrow(IERC20(address(usdc)), address(arb), address(shares), address(0));
        vm.startPrank(issuer);
        shares.setMinter(address(escrow));
        shares.setAllowlist(landlord, true);
        vm.stopPrank();
        vm.prank(human);
        arb.bindEscrow(escrow);
    }

    // ------------------------------------------------------------------ helpers

    function _lease() internal returns (uint256 id) {
        vm.prank(landlord);
        id = escrow.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
        usdc.mint(tenant, TOTAL);
        vm.startPrank(tenant);
        usdc.approve(address(escrow), TOTAL);
        escrow.fundLease(id);
        vm.stopPrank();
    }

    /// @dev A funded lease, one period elapsed (claimed), then disputed by the landlord.
    function _disputed() internal returns (uint256 id) {
        id = _lease();
        vm.warp(vm.getBlockTimestamp() + PERIOD);
        escrow.claimRent(id); // landlord gets period 1
        vm.prank(landlord);
        escrow.openDispute(id);
    }

    function _propose(uint256 id, uint16 bps) internal {
        vm.prank(agent);
        arb.propose(id, bps, HASH, 8500, "Deposit partly kept for documented damage.");
    }

    function _status(uint256 id) internal view returns (AIArbiter.Status) {
        return arb.getRuling(id).status;
    }

    // ------------------------------------------------------------------ config

    function test_Config() public {
        assertEq(address(arb.escrow()), address(escrow));
        assertEq(escrow.arbiter(), address(arb));
        assertEq(arb.human(), human);
        assertEq(arb.agent(), agent);
        assertEq(arb.challengeWindow(), WINDOW);
        assertEq(arb.MIN_CHALLENGE_WINDOW(), 60);
        assertEq(arb.MAX_CHALLENGE_WINDOW(), 30 days);
        assertEq(arb.MAX_STATEMENT_BYTES(), 1000);
    }

    function test_Constructor_RevertsOnZeroHumanOrBadWindow() public {
        vm.expectRevert(AIArbiter.ZeroAddress.selector);
        new AIArbiter(address(0), agent, WINDOW);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.InvalidChallengeWindow.selector, uint32(59)));
        new AIArbiter(human, agent, 59);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.InvalidChallengeWindow.selector, uint32(30 days + 1)));
        new AIArbiter(human, agent, 30 days + 1);
        new AIArbiter(human, address(0), 60); // agent 0 = AI off: allowed
        new AIArbiter(human, agent, 30 days);
    }

    // ------------------------------------------------------------------ bindEscrow

    function test_BindEscrow_OnlyOnce() public {
        RentEscrow other = new RentEscrow(IERC20(address(usdc)), address(arb), address(0), address(0));
        vm.prank(human);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.EscrowAlreadyBound.selector, address(escrow)));
        arb.bindEscrow(other);
        assertEq(address(arb.escrow()), address(escrow));
    }

    function test_BindEscrow_OnlyHuman() public {
        AIArbiter fresh = new AIArbiter(human, agent, WINDOW);
        RentEscrow e = new RentEscrow(IERC20(address(usdc)), address(fresh), address(0), address(0));
        address[3] memory notHuman = [agent, stranger, landlord];
        for (uint256 i; i < notHuman.length; i++) {
            vm.prank(notHuman[i]);
            vm.expectRevert(AIArbiter.NotHuman.selector);
            fresh.bindEscrow(e);
        }
        vm.expectEmit(address(fresh));
        emit AIArbiter.EscrowBound(address(e));
        vm.prank(human);
        fresh.bindEscrow(e);
    }

    function test_BindEscrow_RefusesAnEscrowWithAnotherArbiter() public {
        AIArbiter fresh = new AIArbiter(human, agent, WINDOW);
        RentEscrow notOurs = new RentEscrow(IERC20(address(usdc)), makeAddr("someone"), address(0), address(0));
        vm.startPrank(human);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotEscrowArbiter.selector, address(notOurs)));
        fresh.bindEscrow(notOurs);
        // not a contract / not an escrow at all
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotEscrowArbiter.selector, stranger));
        fresh.bindEscrow(IRentEscrow(stranger));
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotEscrowArbiter.selector, address(usdc)));
        fresh.bindEscrow(IRentEscrow(address(usdc)));
        vm.stopPrank();
        assertEq(address(fresh.escrow()), address(0));
    }

    function test_Unbound_EverythingThatNeedsALeaseReverts() public {
        AIArbiter fresh = new AIArbiter(human, agent, WINDOW);
        vm.prank(tenant);
        vm.expectRevert(AIArbiter.EscrowNotBound.selector);
        fresh.submitEvidence(1, "x");
        vm.prank(agent);
        vm.expectRevert(AIArbiter.EscrowNotBound.selector);
        fresh.propose(1, 5000, HASH, 9000, "");
        vm.prank(human);
        vm.expectRevert(AIArbiter.EscrowNotBound.selector);
        fresh.resolveByHuman(1, 5000);
    }

    // ------------------------------------------------------------------ happy path: AI proposes, nobody appeals

    function test_Flow_EvidenceProposeWindowExecute() public {
        uint256 id = _disputed();
        uint256 remaining = escrow.escrowBalance(id); // deposit 300 + 2 unreleased periods 200
        assertEq(remaining, 500e6);

        vm.expectEmit(address(arb));
        emit AIArbiter.Evidence(id, landlord, "Broken window in the living room, repair quote 150 USDC.");
        vm.prank(landlord);
        arb.submitEvidence(id, "Broken window in the living room, repair quote 150 USDC.");
        vm.prank(tenant);
        arb.submitEvidence(id, "The window was cracked at move-in; see the check-in report.");
        assertEq(arb.evidenceCount(id, landlord), 1);
        assertEq(arb.evidenceCount(id, tenant), 1);

        uint64 deadline = uint64(vm.getBlockTimestamp()) + WINDOW;
        vm.expectEmit(address(arb));
        emit AIArbiter.Proposed(id, agent, 7500, 8500, HASH, deadline, "Deposit partly kept for documented damage.");
        _propose(id, 7500);

        AIArbiter.Ruling memory r = arb.getRuling(id);
        assertEq(uint8(r.status), uint8(AIArbiter.Status.PROPOSED));
        assertEq(r.tenantBps, 7500);
        assertEq(r.confidenceBps, 8500);
        assertEq(r.proposedAt, vm.getBlockTimestamp());
        assertEq(r.deadline, deadline);
        assertEq(r.rulingHash, HASH);

        // Too early: the window is still open (also one second before the deadline).
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.ChallengeWindowOpen.selector, id, deadline));
        arb.execute(id);
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.ChallengeWindowOpen.selector, id, deadline));
        arb.execute(id);

        vm.warp(deadline);
        uint256 landlordBefore = usdc.balanceOf(landlord);
        vm.expectEmit(address(arb));
        emit AIArbiter.Executed(id, 7500, stranger);
        vm.expectEmit(address(escrow));
        emit IRentEscrow.DisputeResolved(id, 7500, 375e6, 125e6);
        vm.prank(stranger); // anyone can execute
        arb.execute(id);

        assertEq(usdc.balanceOf(tenant), 375e6);
        assertEq(usdc.balanceOf(landlord) - landlordBefore, 125e6);
        assertEq(usdc.balanceOf(address(arb)), 0);
        assertEq(uint8(escrow.getLease(id).state), uint8(IRentEscrow.State.CLOSED));
        assertEq(uint8(_status(id)), uint8(AIArbiter.Status.EXECUTED));

        // Final: no second execution, no appeal, no new proposal, no human ruling.
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NoOpenProposal.selector, id, AIArbiter.Status.EXECUTED));
        arb.execute(id);
        vm.prank(tenant);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NoOpenProposal.selector, id, AIArbiter.Status.EXECUTED));
        arb.appeal(id);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotDisputed.selector, id, IRentEscrow.State.CLOSED));
        arb.propose(id, 0, HASH, 9000, "");
        vm.prank(human);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotDisputed.selector, id, IRentEscrow.State.CLOSED));
        arb.resolveByHuman(id, 0);
    }

    // ------------------------------------------------------------------ appeal -> human

    function test_Flow_AppealBlocksExecuteThenHumanResolves() public {
        uint256 id = _disputed();
        _propose(id, 0); // AI: everything to the landlord
        uint64 deadline = arb.getRuling(id).deadline;

        vm.warp(deadline - 1); // last second of the window
        vm.expectEmit(address(arb));
        emit AIArbiter.Appealed(id, tenant);
        vm.prank(tenant);
        arb.appeal(id);
        assertEq(uint8(_status(id)), uint8(AIArbiter.Status.APPEALED));

        vm.warp(deadline + 1 days);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NoOpenProposal.selector, id, AIArbiter.Status.APPEALED));
        arb.execute(id);
        // The agent cannot re-propose after an appeal.
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.ProposalLocked.selector, id, AIArbiter.Status.APPEALED));
        arb.propose(id, 10_000, HASH, 9000, "");
        // Nobody appeals twice.
        vm.prank(landlord);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NoOpenProposal.selector, id, AIArbiter.Status.APPEALED));
        arb.appeal(id);

        uint256 landlordBefore = usdc.balanceOf(landlord);
        vm.expectEmit(address(arb));
        emit AIArbiter.HumanResolved(id, 5000, human, AIArbiter.Status.APPEALED);
        vm.prank(human);
        arb.resolveByHuman(id, 5000);
        assertEq(usdc.balanceOf(tenant), 250e6);
        assertEq(usdc.balanceOf(landlord) - landlordBefore, 250e6);
        assertEq(uint8(_status(id)), uint8(AIArbiter.Status.HUMAN_RESOLVED));
        AIArbiter.Ruling memory r = arb.getRuling(id);
        assertEq(r.tenantBps, 5000); // final ruling
        assertEq(r.rulingHash, HASH); // the AI's proposal stays on record
    }

    function test_Appeal_LandlordCanAppealToo() public {
        uint256 id = _disputed();
        _propose(id, 10_000);
        vm.prank(landlord);
        arb.appeal(id);
        assertEq(uint8(_status(id)), uint8(AIArbiter.Status.APPEALED));
    }

    function test_Appeal_OnlyPartiesInsideTheWindow() public {
        uint256 id = _disputed();
        vm.prank(tenant);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NoOpenProposal.selector, id, AIArbiter.Status.NONE));
        arb.appeal(id);

        _propose(id, 2500);
        address[3] memory notParty = [stranger, agent, human];
        for (uint256 i; i < notParty.length; i++) {
            vm.prank(notParty[i]);
            vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotParty.selector, id));
            arb.appeal(id);
        }

        uint64 deadline = arb.getRuling(id).deadline;
        vm.warp(deadline);
        vm.prank(tenant);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.ChallengeWindowOver.selector, id, deadline));
        arb.appeal(id);
        arb.execute(id);
        assertEq(usdc.balanceOf(tenant), 125e6);
    }

    // ------------------------------------------------------------------ human override / direct

    function test_Human_OverridesAProposalInsideTheWindow() public {
        uint256 id = _disputed();
        _propose(id, 0);
        vm.expectEmit(address(arb));
        emit AIArbiter.HumanResolved(id, 10_000, human, AIArbiter.Status.PROPOSED);
        vm.prank(human);
        arb.resolveByHuman(id, 10_000);
        assertEq(usdc.balanceOf(tenant), 500e6);

        vm.warp(vm.getBlockTimestamp() + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NoOpenProposal.selector, id, AIArbiter.Status.HUMAN_RESOLVED));
        arb.execute(id);
    }

    function test_Human_OverridesAfterTheWindowBeforeExecute() public {
        uint256 id = _disputed();
        _propose(id, 0);
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1 hours); // executable, but nobody executed yet
        vm.prank(human);
        arb.resolveByHuman(id, 2500);
        assertEq(usdc.balanceOf(tenant), 125e6);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NoOpenProposal.selector, id, AIArbiter.Status.HUMAN_RESOLVED));
        arb.execute(id);
    }

    function test_Human_ResolvesDirectlyWithoutAProposal() public {
        uint256 id = _disputed();
        vm.expectEmit(address(arb));
        emit AIArbiter.HumanResolved(id, 4000, human, AIArbiter.Status.NONE);
        vm.prank(human);
        arb.resolveByHuman(id, 4000);
        assertEq(usdc.balanceOf(tenant), 200e6);
        assertEq(uint8(_status(id)), uint8(AIArbiter.Status.HUMAN_RESOLVED));
        assertEq(arb.getRuling(id).rulingHash, bytes32(0));
    }

    function test_Human_OnlyHumanAndBoundedBps() public {
        uint256 id = _disputed();
        address[4] memory notHuman = [agent, tenant, landlord, stranger];
        for (uint256 i; i < notHuman.length; i++) {
            vm.prank(notHuman[i]);
            vm.expectRevert(AIArbiter.NotHuman.selector);
            arb.resolveByHuman(id, 5000);
        }
        vm.prank(human);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.InvalidBps.selector, uint16(10_001)));
        arb.resolveByHuman(id, 10_001);
    }

    function test_Human_CannotRuleOnANonDisputedLease() public {
        uint256 id = _lease(); // ACTIVE
        vm.prank(human);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotDisputed.selector, id, IRentEscrow.State.ACTIVE));
        arb.resolveByHuman(id, 5000);
        vm.prank(human);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotDisputed.selector, 99, IRentEscrow.State.NONE));
        arb.resolveByHuman(99, 5000);
    }

    // ------------------------------------------------------------------ propose: access + state

    function test_Propose_OnlyAgent() public {
        uint256 id = _disputed();
        address[4] memory notAgent = [human, tenant, landlord, stranger];
        for (uint256 i; i < notAgent.length; i++) {
            vm.prank(notAgent[i]);
            vm.expectRevert(AIArbiter.NotAgent.selector);
            arb.propose(id, 5000, HASH, 9000, "");
        }
    }

    function test_Propose_OnlyOnDisputedLeases() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotDisputed.selector, 1, IRentEscrow.State.NONE));
        arb.propose(1, 5000, HASH, 9000, "");

        vm.prank(landlord);
        uint256 created = escrow.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotDisputed.selector, created, IRentEscrow.State.CREATED));
        arb.propose(created, 5000, HASH, 9000, "");

        uint256 active = _lease();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotDisputed.selector, active, IRentEscrow.State.ACTIVE));
        arb.propose(active, 5000, HASH, 9000, "");
    }

    function test_Propose_BoundsOnBpsConfidenceAndSummary() public {
        uint256 id = _disputed();
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.InvalidBps.selector, uint16(10_001)));
        arb.propose(id, 10_001, HASH, 9000, "");
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.InvalidBps.selector, uint16(10_001)));
        arb.propose(id, 5000, HASH, 10_001, "");
        string memory tooLong = string(new bytes(1001));
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.SummaryTooLong.selector, uint256(1001)));
        arb.propose(id, 5000, HASH, 9000, tooLong);
        arb.propose(id, 10_000, HASH, 10_000, string(new bytes(1000))); // limits are inclusive
        vm.stopPrank();
    }

    function test_Propose_ReplacesAnOpenProposalAndRestartsTheWindow() public {
        uint256 id = _disputed();
        _propose(id, 0);
        vm.warp(vm.getBlockTimestamp() + WINDOW - 1); // still open

        bytes32 hash2 = keccak256("second ruling");
        uint64 deadline2 = uint64(vm.getBlockTimestamp()) + WINDOW;
        vm.expectEmit(address(arb));
        emit AIArbiter.ProposalReplaced(id, 0, HASH);
        vm.expectEmit(address(arb));
        emit AIArbiter.Proposed(id, agent, 5000, 9100, hash2, deadline2, "revised");
        vm.prank(agent);
        arb.propose(id, 5000, hash2, 9100, "revised");

        AIArbiter.Ruling memory r = arb.getRuling(id);
        assertEq(r.tenantBps, 5000);
        assertEq(r.rulingHash, hash2);
        assertEq(r.deadline, deadline2);

        vm.warp(deadline2 - 1);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.ChallengeWindowOpen.selector, id, deadline2));
        arb.execute(id); // the first proposal's window no longer counts
        vm.warp(deadline2);
        arb.execute(id);
        assertEq(usdc.balanceOf(tenant), 250e6);
    }

    function test_Propose_CannotReplaceOnceTheWindowIsOver() public {
        uint256 id = _disputed();
        _propose(id, 0);
        uint64 deadline = arb.getRuling(id).deadline;
        vm.warp(deadline);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.ChallengeWindowOver.selector, id, deadline));
        arb.propose(id, 10_000, HASH, 9000, "");
    }

    function test_Propose_AgentOffWhenZero() public {
        uint256 id = _disputed();
        vm.prank(human);
        arb.setAgent(address(0));
        vm.prank(agent);
        vm.expectRevert(AIArbiter.NotAgent.selector);
        arb.propose(id, 5000, HASH, 9000, "");
    }

    /// The agent or the human cannot rule on a lease it is a party to (mirrors RentEscrow's rule
    /// that the arbiter is never a party).
    function test_PartiesCannotArbitrateTheirOwnLease() public {
        vm.prank(issuer);
        shares.setAllowlist(agent, true);
        vm.prank(agent); // the agent key lists a lease as landlord
        uint256 id = escrow.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
        usdc.mint(tenant, TOTAL);
        vm.startPrank(tenant);
        usdc.approve(address(escrow), TOTAL);
        escrow.fundLease(id);
        escrow.openDispute(id);
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.PartyCannotArbitrate.selector, id, agent));
        arb.propose(id, 0, HASH, 9000, "");

        // The human as a tenant.
        vm.prank(landlord);
        uint256 id2 = escrow.createLease(human, DEPOSIT, RENT, PERIOD, PERIODS);
        usdc.mint(human, TOTAL);
        vm.startPrank(human);
        usdc.approve(address(escrow), TOTAL);
        escrow.fundLease(id2);
        escrow.openDispute(id2);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.PartyCannotArbitrate.selector, id2, human));
        arb.resolveByHuman(id2, 10_000);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ evidence

    function test_Evidence_OnlyPartiesOfADisputedLease() public {
        uint256 id = _lease(); // ACTIVE
        vm.prank(tenant);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotDisputed.selector, id, IRentEscrow.State.ACTIVE));
        arb.submitEvidence(id, "too early");

        vm.prank(tenant);
        escrow.openDispute(id);
        address[3] memory notParty = [stranger, agent, human];
        for (uint256 i; i < notParty.length; i++) {
            vm.prank(notParty[i]);
            vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotParty.selector, id));
            arb.submitEvidence(id, "I am not a party");
        }
        vm.prank(tenant);
        arb.submitEvidence(id, "ok");

        vm.prank(human);
        arb.resolveByHuman(id, 5000);
        vm.prank(tenant);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NotDisputed.selector, id, IRentEscrow.State.CLOSED));
        arb.submitEvidence(id, "too late");
    }

    function test_Evidence_LengthAndCountCaps() public {
        uint256 id = _disputed();
        vm.startPrank(tenant);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.InvalidStatementLength.selector, uint256(0)));
        arb.submitEvidence(id, "");
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.InvalidStatementLength.selector, uint256(1001)));
        arb.submitEvidence(id, string(new bytes(1001)));
        arb.submitEvidence(id, string(new bytes(1000)));
        for (uint256 i = 1; i < 5; i++) {
            arb.submitEvidence(id, "more");
        }
        assertEq(arb.evidenceCount(id, tenant), 5);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.TooManyStatements.selector, id, tenant));
        arb.submitEvidence(id, "sixth");
        vm.stopPrank();
        // The landlord's quota is separate.
        vm.prank(landlord);
        arb.submitEvidence(id, "landlord's first");
    }

    function test_Evidence_AllowedWhileAProposalIsOpen() public {
        uint256 id = _disputed();
        _propose(id, 5000);
        vm.prank(tenant);
        arb.submitEvidence(id, "Late evidence goes to the human if I appeal.");
    }

    // ------------------------------------------------------------------ parameters (human)

    function test_Setters_OnlyHuman() public {
        vm.startPrank(stranger);
        vm.expectRevert(AIArbiter.NotHuman.selector);
        arb.setAgent(stranger);
        vm.expectRevert(AIArbiter.NotHuman.selector);
        arb.setHuman(stranger);
        vm.expectRevert(AIArbiter.NotHuman.selector);
        arb.setChallengeWindow(600);
        vm.stopPrank();
        vm.startPrank(agent);
        vm.expectRevert(AIArbiter.NotHuman.selector);
        arb.setAgent(stranger);
        vm.expectRevert(AIArbiter.NotHuman.selector);
        arb.setChallengeWindow(600);
        vm.stopPrank();
    }

    function test_Setters_UpdateAndEmit() public {
        address newAgent = makeAddr("newAgent");
        address safe = makeAddr("safe");

        vm.startPrank(human);
        vm.expectEmit(address(arb));
        emit AIArbiter.AgentUpdated(agent, newAgent);
        arb.setAgent(newAgent);
        vm.expectEmit(address(arb));
        emit AIArbiter.ChallengeWindowUpdated(WINDOW, 3 days);
        arb.setChallengeWindow(3 days);
        vm.expectEmit(address(arb));
        emit AIArbiter.HumanTransferStarted(human, safe);
        arb.setHuman(safe);
        vm.stopPrank();
        assertEq(arb.human(), human); // nominated, not yet the human
        assertEq(arb.pendingHuman(), safe);

        vm.expectEmit(address(arb));
        emit AIArbiter.HumanUpdated(human, safe);
        vm.prank(safe);
        arb.acceptHuman();

        assertEq(arb.agent(), newAgent);
        assertEq(arb.challengeWindow(), 3 days);
        assertEq(arb.human(), safe);
        assertEq(arb.pendingHuman(), address(0));
        vm.prank(human); // the old human is out
        vm.expectRevert(AIArbiter.NotHuman.selector);
        arb.setAgent(agent);
    }

    /// A mistyped handover must not strand an appealed lease: only the human can close it, and
    /// RentEscrow's arbiter is immutable. The old human keeps the role until the nominee accepts.
    function test_SetHuman_AWrongAddressDoesNotStrandAppealedLeases() public {
        uint256 id = _disputed();
        _propose(id, 0);
        vm.prank(tenant);
        arb.appeal(id);

        vm.prank(human);
        arb.setHuman(address(0xdead)); // typo: nobody holds this key
        assertEq(arb.human(), human);

        // Nobody else can take the role, and the agent / execute still cannot close the lease.
        address[4] memory notNominee = [stranger, agent, tenant, human];
        for (uint256 i; i < notNominee.length; i++) {
            vm.prank(notNominee[i]);
            vm.expectRevert(AIArbiter.NotPendingHuman.selector);
            arb.acceptHuman();
        }
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.NoOpenProposal.selector, id, AIArbiter.Status.APPEALED));
        arb.execute(id);

        // The real human still rules, and can cancel the bad nomination.
        vm.startPrank(human);
        arb.resolveByHuman(id, 5000);
        vm.expectEmit(address(arb));
        emit AIArbiter.HumanTransferStarted(human, address(0));
        arb.setHuman(address(0));
        vm.stopPrank();
        assertEq(uint8(_status(id)), uint8(AIArbiter.Status.HUMAN_RESOLVED));
        assertEq(arb.pendingHuman(), address(0));
        vm.prank(address(0xdead));
        vm.expectRevert(AIArbiter.NotPendingHuman.selector);
        arb.acceptHuman();
    }

    function test_AcceptHuman_NoNomineeNobody() public {
        address[4] memory callers = [stranger, agent, human, address(0)];
        for (uint256 i; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(AIArbiter.NotPendingHuman.selector);
            arb.acceptHuman();
        }
        // A second nomination replaces the first.
        address safe = makeAddr("safe");
        vm.startPrank(human);
        arb.setHuman(stranger);
        arb.setHuman(safe);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(AIArbiter.NotPendingHuman.selector);
        arb.acceptHuman();
        vm.prank(safe);
        arb.acceptHuman();
        assertEq(arb.human(), safe);
    }

    function test_Setters_Bounds() public {
        vm.startPrank(human);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.InvalidChallengeWindow.selector, uint32(59)));
        arb.setChallengeWindow(59);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.InvalidChallengeWindow.selector, uint32(30 days + 1)));
        arb.setChallengeWindow(30 days + 1);
        arb.setChallengeWindow(60);
        arb.setChallengeWindow(30 days);
        vm.stopPrank();
    }

    function test_SetChallengeWindow_OnlyAffectsNewProposals() public {
        uint256 id = _disputed();
        _propose(id, 5000);
        uint64 deadline = arb.getRuling(id).deadline;
        vm.prank(human);
        arb.setChallengeWindow(30 days);
        assertEq(arb.getRuling(id).deadline, deadline);
        vm.warp(deadline);
        arb.execute(id);
    }

    // ------------------------------------------------------------------ AI-1: the only thing it can do

    /// Records every call AIArbiter makes while running each flow, and checks that the only
    /// state-changing one is escrow.resolveDispute (views: escrow.arbiter / escrow.getLease).
    function test_AI1_OnlyEverCallsEscrowResolveDispute() public {
        AIArbiter fresh = new AIArbiter(human, agent, WINDOW);
        RentEscrow e = new RentEscrow(IERC20(address(usdc)), address(fresh), address(0), address(0));

        vm.startStateDiffRecording();
        vm.prank(human);
        fresh.bindEscrow(e);
        // lease A: evidence, propose, replace, execute
        uint256 a = _disputedOn(e);
        vm.prank(tenant);
        fresh.submitEvidence(a, "statement");
        vm.startPrank(agent);
        fresh.propose(a, 1000, HASH, 9000, "one");
        fresh.propose(a, 2000, HASH, 9000, "two");
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        fresh.execute(a);
        // lease B: propose, appeal, human
        uint256 b = _disputedOn(e);
        vm.prank(agent);
        fresh.propose(b, 0, HASH, 9000, "");
        vm.prank(landlord);
        fresh.appeal(b);
        vm.prank(human);
        fresh.resolveByHuman(b, 7000);
        // lease C: human directly; parameters
        uint256 c = _disputedOn(e);
        vm.startPrank(human);
        fresh.resolveByHuman(c, 10_000);
        fresh.setAgent(stranger);
        fresh.setChallengeWindow(600);
        fresh.setHuman(stranger);
        vm.stopPrank();
        vm.prank(stranger);
        fresh.acceptHuman();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        (uint256 forbidden, uint256 resolves) = classifyArbiterCalls(accesses, address(fresh), address(e));
        assertEq(forbidden, 0, "AIArbiter made a call other than escrow views / resolveDispute");
        assertEq(resolves, 3);
        assertEq(usdc.balanceOf(address(fresh)), 0);
    }

    function _disputedOn(RentEscrow e) internal returns (uint256 id) {
        vm.prank(landlord);
        id = e.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
        usdc.mint(tenant, TOTAL);
        vm.startPrank(tenant);
        usdc.approve(address(e), TOTAL);
        e.fundLease(id);
        e.openDispute(id);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ fuzz

    /// Whatever the agent proposes, execution pays out exactly the remaining escrow, split by it,
    /// to the lease's two parties only.
    function testFuzz_ExecutedSplitIsExact(uint16 bps, uint32 elapsed) public {
        bps = uint16(bound(bps, 0, 10_000));
        uint256 id = _lease();
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, uint256(PERIOD) * PERIODS));
        vm.prank(tenant);
        escrow.openDispute(id);
        uint256 remaining = escrow.escrowBalance(id);
        uint256 landlordBefore = usdc.balanceOf(landlord);

        _propose(id, bps);
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        vm.prank(stranger);
        arb.execute(id);

        uint256 toTenant = remaining * bps / 10_000;
        assertEq(usdc.balanceOf(tenant), toTenant);
        assertEq(usdc.balanceOf(landlord) - landlordBefore, remaining - toTenant);
        assertEq(usdc.balanceOf(stranger) + usdc.balanceOf(agent) + usdc.balanceOf(human), 0);
        assertEq(usdc.balanceOf(address(arb)) + usdc.balanceOf(address(escrow)), 0);
    }
}
