// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AIArbiter} from "../src/AIArbiter.sol";
import {EnsAgentRelay, IJudgeArbiter, IJudgeSubnames} from "../src/EnsAgentRelay.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";

/// @notice TEST-ONLY RentoutsSubnames + UserRegistry stand-ins: who holds a label, and who the registry
///         says owns it (they diverge when a name is unregistered out of band or expires).
contract MockJudgeSubnames {
    mapping(uint256 => address) public holderOf;
    MockJudgeRegistry public immutable reg;

    constructor() {
        reg = new MockJudgeRegistry();
    }

    function registry() external view returns (address) {
        return address(reg);
    }

    function parentName() external pure returns (string memory) {
        return "rentouts.eth";
    }

    function issue(string memory label, address holder) external {
        uint256 id = uint256(keccak256(bytes(label)));
        holderOf[id] = holder;
        reg.setOwner(id, holder);
    }

    function revoke(string memory label) external {
        uint256 id = uint256(keccak256(bytes(label)));
        delete holderOf[id];
        reg.setOwner(id, address(0));
    }
}

contract MockJudgeRegistry {
    mapping(uint256 => address) public getOwner;

    function setOwner(uint256 id, address owner) external {
        getOwner[id] = owner;
    }
}

/// @notice EnsAgentRelay against the real AIArbiter + RentEscrow, with mocked ENS: only the current holder
///         of judge.rentouts.eth can propose once the relay is AIArbiter's agent.
contract EnsAgentRelayTest is Test {
    MockUSDC usdc;
    RentEscrow escrow;
    AIArbiter arb;
    MockJudgeSubnames subnames;
    EnsAgentRelay relay;

    address human = makeAddr("human");
    address judgeKey = makeAddr("judge");
    address issuer = makeAddr("issuer");
    address landlord = makeAddr("landlord");
    address tenant = makeAddr("tenant");
    address stranger = makeAddr("stranger");

    uint128 constant DEPOSIT = 300e6;
    uint128 constant RENT = 100e6;
    bytes32 constant HASH = keccak256("canonical ruling json");
    uint256 constant JUDGE_ID = uint256(keccak256("judge"));

    event RelayedProposal(uint256 indexed leaseId, address indexed judge, string name, uint16 tenantBps, bytes32 rulingHash);
    event Proposed(
        uint256 indexed leaseId,
        address indexed agent,
        uint16 tenantBps,
        uint16 confidenceBps,
        bytes32 rulingHash,
        uint64 deadline,
        string summary
    );

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        LeaseShare1155 shares = new LeaseShare1155(issuer, "");
        arb = new AIArbiter(human, judgeKey, 120);
        escrow = new RentEscrow(IERC20(address(usdc)), address(arb), address(shares), address(0));
        vm.startPrank(issuer);
        shares.setMinter(address(escrow));
        shares.setAllowlist(landlord, true);
        shares.setAllowlist(judgeKey, true);
        vm.stopPrank();
        vm.prank(human);
        arb.bindEscrow(escrow);

        subnames = new MockJudgeSubnames();
        subnames.issue("judge", judgeKey);
        relay = new EnsAgentRelay(IJudgeArbiter(address(arb)), IJudgeSubnames(address(subnames)), "judge");
        vm.prank(human);
        arb.setAgent(address(relay));
    }

    function _disputed(address l, address t) internal returns (uint256 id) {
        vm.prank(l);
        id = escrow.createLease(t, DEPOSIT, RENT, 1 days, 3);
        usdc.mint(t, DEPOSIT + RENT * 3);
        vm.startPrank(t);
        usdc.approve(address(escrow), DEPOSIT + RENT * 3);
        escrow.fundLease(id);
        escrow.openDispute(id);
        vm.stopPrank();
    }

    function _propose(address from, uint256 id) internal {
        vm.prank(from);
        relay.propose(id, 7500, HASH, 8500, "E2 admits E1.");
    }

    // ------------------------------------------------------------------ wiring

    function test_Config() public {
        assertEq(address(relay.arbiter()), address(arb));
        assertEq(address(relay.subnames()), address(subnames));
        assertEq(address(relay.registry()), subnames.registry());
        assertEq(relay.labelId(), JUDGE_ID);
        assertEq(relay.label(), "judge");
        assertEq(relay.name(), "judge.rentouts.eth");
        assertEq(relay.judge(), judgeKey);
        assertTrue(relay.isJudge(judgeKey));
        assertFalse(relay.isJudge(stranger));
        assertFalse(relay.isJudge(address(0)));
        assertEq(arb.agent(), address(relay));
    }

    function test_Constructor_Reverts() public {
        vm.expectRevert(EnsAgentRelay.ZeroAddress.selector);
        new EnsAgentRelay(IJudgeArbiter(address(0)), IJudgeSubnames(address(subnames)), "judge");
        vm.expectRevert(EnsAgentRelay.ZeroAddress.selector);
        new EnsAgentRelay(IJudgeArbiter(address(arb)), IJudgeSubnames(address(0)), "judge");
        vm.expectRevert(EnsAgentRelay.InvalidLabel.selector);
        new EnsAgentRelay(IJudgeArbiter(address(arb)), IJudgeSubnames(address(subnames)), "");
    }

    // ------------------------------------------------------------------ the ENS gate

    function test_HolderProposesThroughRelay() public {
        uint256 id = _disputed(landlord, tenant);
        vm.expectEmit(true, true, false, true, address(relay));
        emit RelayedProposal(id, judgeKey, "judge.rentouts.eth", 7500, HASH);
        vm.expectEmit(true, true, false, true, address(arb));
        emit Proposed(id, address(relay), 7500, 8500, HASH, uint64(block.timestamp + 120), "E2 admits E1.");
        _propose(judgeKey, id);

        AIArbiter.Ruling memory r = arb.getRuling(id);
        assertEq(uint8(r.status), uint8(AIArbiter.Status.PROPOSED));
        assertEq(r.tenantBps, 7500);
        assertEq(r.rulingHash, HASH);

        // The rest of the flow is AIArbiter's, unchanged: execute after the window.
        vm.warp(block.timestamp + 120);
        arb.execute(id);
        assertEq(uint8(arb.getRuling(id).status), uint8(AIArbiter.Status.EXECUTED));
    }

    function test_NonHolderIsRefused() public {
        uint256 id = _disputed(landlord, tenant);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EnsAgentRelay.NotEnsJudge.selector, stranger, judgeKey));
        relay.propose(id, 7500, HASH, 8500, "");
    }

    /// With the relay as agent the judge EOA can no longer go around ENS.
    function test_JudgeKeyCannotBypassTheRelay() public {
        uint256 id = _disputed(landlord, tenant);
        vm.prank(judgeKey);
        vm.expectRevert(AIArbiter.NotAgent.selector);
        arb.propose(id, 7500, HASH, 8500, "");
    }

    function test_RevokedNameStopsTheJudge() public {
        uint256 id = _disputed(landlord, tenant);
        subnames.revoke("judge");
        assertEq(relay.judge(), address(0));
        vm.prank(judgeKey);
        vm.expectRevert(abi.encodeWithSelector(EnsAgentRelay.NotEnsJudge.selector, judgeKey, address(0)));
        relay.propose(id, 7500, HASH, 8500, "");
    }

    /// RentoutsSubnames still names the key, but the ENS registry no longer does (unregistered / expired).
    function test_NameNoLongerLiveInRegistry() public {
        uint256 id = _disputed(landlord, tenant);
        subnames.reg().setOwner(JUDGE_ID, address(0));
        assertEq(relay.judge(), address(0));
        vm.prank(judgeKey);
        vm.expectRevert(abi.encodeWithSelector(EnsAgentRelay.EnsNameNotLive.selector, judgeKey, address(0)));
        relay.propose(id, 7500, HASH, 8500, "");
    }

    /// A new holder of the name (re-issued) is the judge; the old key is out.
    function test_TheNameDecidesWhoJudges() public {
        uint256 id = _disputed(landlord, tenant);
        address next = makeAddr("next judge");
        subnames.issue("judge", next);
        vm.prank(judgeKey);
        vm.expectRevert(abi.encodeWithSelector(EnsAgentRelay.NotEnsJudge.selector, judgeKey, next));
        relay.propose(id, 7500, HASH, 8500, "");
        _propose(next, id);
        assertEq(uint8(arb.getRuling(id).status), uint8(AIArbiter.Status.PROPOSED));
    }

    /// AIArbiter's "a party cannot arbitrate" rule, kept for the judge key behind the relay.
    function test_JudgeWhoIsAPartyIsRefused() public {
        uint256 id = _disputed(judgeKey, tenant);
        vm.prank(judgeKey);
        vm.expectRevert(abi.encodeWithSelector(EnsAgentRelay.PartyCannotArbitrate.selector, id, judgeKey));
        relay.propose(id, 7500, HASH, 8500, "");
    }

    function test_RelayNotAgentBubblesNotAgent() public {
        uint256 id = _disputed(landlord, tenant);
        vm.prank(human);
        arb.setAgent(judgeKey);
        vm.prank(judgeKey);
        vm.expectRevert(AIArbiter.NotAgent.selector);
        relay.propose(id, 7500, HASH, 8500, "");
    }

    /// Rollback: the human points AIArbiter back at the judge EOA, which proposes directly again.
    function test_RollbackToEoa() public {
        uint256 id = _disputed(landlord, tenant);
        vm.prank(human);
        arb.setAgent(judgeKey);
        vm.prank(judgeKey);
        arb.propose(id, 5000, HASH, 9000, "");
        assertEq(arb.getRuling(id).tenantBps, 5000);
    }

    /// AIArbiter's own checks still apply behind the relay.
    function test_ArbiterChecksStillApply() public {
        uint256 id = _disputed(landlord, tenant);
        vm.prank(judgeKey);
        vm.expectRevert(abi.encodeWithSelector(AIArbiter.InvalidBps.selector, uint16(10_001)));
        relay.propose(id, 10_001, HASH, 8500, "");
    }

    function testFuzz_OnlyTheHolderGetsThrough(address caller) public {
        vm.assume(caller != judgeKey);
        uint256 id = _disputed(landlord, tenant);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(EnsAgentRelay.NotEnsJudge.selector, caller, judgeKey));
        relay.propose(id, 7500, HASH, 8500, "");
    }
}
