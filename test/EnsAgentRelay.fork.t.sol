// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AIArbiter} from "../src/AIArbiter.sol";
import {EnsAgentRelay, IJudgeArbiter, IJudgeSubnames} from "../src/EnsAgentRelay.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {DeployEnsAgentRelay} from "../script/DeployEnsAgentRelay.s.sol";

/// @dev The live RentoutsSubnames calls the fork test makes as its admin / issuer (ens/src/RentoutsSubnames.sol).
interface ILiveSubnames {
    function register(string calldata label, address holder) external returns (uint256);
    function revoke(string calldata label, string calldata reason) external;
    function nameOf(address holder) external view returns (string memory);
    function isIssuer(address account) external view returns (bool);
}

interface ILiveGate {
    function setVerifier(address newVerifier) external;
}

interface ILiveShares {
    function setAllowlist(address account, bool allowed) external;
}

/// @notice The whole ENS-gated judge against the LIVE Sepolia contracts on a fork: register
///         judge.rentouts.eth to the judge key on the real RentoutsSubnames, deploy the relay with its
///         deploy script, the human makes it AIArbiter's agent, and a real lease on the real RentEscrow goes
///         to dispute and gets an AI proposal through the relay. Non-holders are refused, and revoking the
///         name stops the AI. Nothing is broadcast.
///         Run: forge test --match-path test/EnsAgentRelay.fork.t.sol -vv
contract EnsAgentRelayForkTest is Test {
    AIArbiter constant ARB = AIArbiter(0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5);
    ILiveSubnames constant SUBNAMES = ILiveSubnames(0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60);
    address constant DEPLOYER = 0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE; // subnames admin/issuer, gate + shares owner
    bytes32 constant HASH = keccak256("canonical ruling json");

    RentEscrow escrow;
    IERC20 usdc;
    EnsAgentRelay relay;
    address judgeKey;
    address human;
    address landlord = makeAddr("rentouts.test.relay.landlord");
    address tenant = makeAddr("rentouts.test.relay.tenant");
    address stranger = makeAddr("rentouts.test.relay.stranger");

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")));
        escrow = RentEscrow(address(ARB.escrow()));
        usdc = IERC20(address(escrow.token()));
        judgeKey = ARB.agent();
        human = ARB.human();
        require(judgeKey.code.length == 0, "fork: AIArbiter.agent() is not the judge EOA any more (relay already on?)");

        // judge.rentouts.eth -> the judge key, by the issuer (what ens/script/JudgeName.s.sol registerJudge does).
        vm.prank(DEPLOYER);
        SUBNAMES.register("judge", judgeKey);
        assertEq(SUBNAMES.nameOf(judgeKey), "judge.rentouts.eth");

        // The relay, deployed by its own deploy script.
        DeployEnsAgentRelay deployScript = new DeployEnsAgentRelay();
        relay = deployScript.deploy(DEPLOYER, address(ARB), address(SUBNAMES), "judge");

        // A real lease on the live escrow: open the World ID gate and allowlist the landlord (both owned
        // by the deployer), fund the tenant with Sepolia USDC.
        vm.startPrank(DEPLOYER);
        ILiveGate(escrow.humanGate()).setVerifier(address(0));
        ILiveShares(escrow.leaseShare()).setAllowlist(landlord, true);
        vm.stopPrank();
    }

    function _disputedLease() internal returns (uint256 id) {
        vm.prank(landlord);
        id = escrow.createLease(tenant, 3e5, 2e5, 120, 3);
        // Circle's FiatToken keeps balances in `balanceAndBlacklistStates` (slot 9; top bit = blacklisted),
        // which forge's deal() can't find.
        vm.store(address(usdc), keccak256(abi.encode(tenant, uint256(9))), bytes32(uint256(9e5)));
        assertEq(usdc.balanceOf(tenant), 9e5);
        vm.startPrank(tenant);
        usdc.approve(address(escrow), 9e5);
        escrow.fundLease(id);
        escrow.openDispute(id);
        vm.stopPrank();
    }

    function _switchOn() internal {
        vm.prank(human);
        ARB.setAgent(address(relay));
    }

    function test_RelayWiring() public {
        assertEq(address(relay.arbiter()), address(ARB));
        assertEq(address(relay.subnames()), address(SUBNAMES));
        assertEq(relay.name(), "judge.rentouts.eth");
        assertEq(relay.judge(), judgeKey, "the ENS judge is AIArbiter's current agent");
    }

    function test_EnsJudgeProposesThroughRelay() public {
        uint256 id = _disputedLease();
        _switchOn();
        assertEq(ARB.agent(), address(relay));

        vm.prank(judgeKey);
        relay.propose(id, 7500, HASH, 8500, "Relayed: E2 admits E1.");
        AIArbiter.Ruling memory r = ARB.getRuling(id);
        assertEq(uint8(r.status), uint8(AIArbiter.Status.PROPOSED));
        assertEq(r.tenantBps, 7500);
        assertEq(r.rulingHash, HASH);

        // Then the ordinary flow: the window runs out, anyone executes, the escrow pays out.
        vm.warp(r.deadline);
        uint256 before = usdc.balanceOf(tenant);
        ARB.execute(id);
        assertEq(uint8(ARB.getRuling(id).status), uint8(AIArbiter.Status.EXECUTED));
        assertGt(usdc.balanceOf(tenant), before);
    }

    function test_NonHolderAndBypassAreRefused() public {
        uint256 id = _disputedLease();
        _switchOn();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EnsAgentRelay.NotEnsJudge.selector, stranger, judgeKey));
        relay.propose(id, 7500, HASH, 8500, "");
        // The judge key can't go around the name either.
        vm.prank(judgeKey);
        vm.expectRevert(AIArbiter.NotAgent.selector);
        ARB.propose(id, 7500, HASH, 8500, "");
    }

    function test_RevokingTheNameStopsTheAI() public {
        uint256 id = _disputedLease();
        _switchOn();
        vm.prank(DEPLOYER);
        SUBNAMES.revoke("judge", "judge key rotated");
        assertEq(relay.judge(), address(0));
        vm.prank(judgeKey);
        vm.expectRevert(abi.encodeWithSelector(EnsAgentRelay.NotEnsJudge.selector, judgeKey, address(0)));
        relay.propose(id, 7500, HASH, 8500, "");
        // The human still rules.
        vm.prank(human);
        ARB.resolveByHuman(id, 5000);
        assertEq(uint8(ARB.getRuling(id).status), uint8(AIArbiter.Status.HUMAN_RESOLVED));
    }

    function test_RollbackToTheJudgeEoa() public {
        uint256 id = _disputedLease();
        _switchOn();
        vm.prank(human);
        ARB.setAgent(judgeKey);
        vm.prank(judgeKey);
        ARB.propose(id, 5000, HASH, 9000, "direct again");
        assertEq(ARB.getRuling(id).tenantBps, 5000);
    }
}
