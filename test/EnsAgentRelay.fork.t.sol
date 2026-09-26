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

/// @notice The ENS-gated judge as it is LIVE on Sepolia, exercised on a fork. judge.rentouts.eth is held by
///         the judge key 0x4a44…d0dA (register tx 0x5454ab9b…4e73, block 11783660), the EnsAgentRelay
///         0xe56E…C3eE is deployed (block 11783676) and the human made it AIArbiter's agent (setAgent tx
///         0x0fc2c12c…44ad, block 11783678). A real lease on the real RentEscrow goes to dispute and gets an AI
///         proposal through the LIVE relay; non-holders and the direct call are refused; revoking the name
///         (on the fork only: labels are single-use) stops the AI; rollback is setAgent(judge key). The
///         deploy script still builds a relay with the live relay's exact runtime code. Nothing is broadcast.
///         If the human has rolled back (agent() = judge key), _switchOn re-applies setAgent(relay) on the fork.
///         Run: forge test --match-path test/EnsAgentRelay.fork.t.sol -vv
contract EnsAgentRelayForkTest is Test {
    AIArbiter constant ARB = AIArbiter(0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5);
    ILiveSubnames constant SUBNAMES = ILiveSubnames(0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60);
    address constant DEPLOYER = 0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE; // subnames admin/issuer, gate + shares owner
    address constant JUDGE_KEY = 0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA; // keystore rentouts-judge
    EnsAgentRelay constant LIVE_RELAY = EnsAgentRelay(0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE);
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
        relay = LIVE_RELAY;
        judgeKey = JUDGE_KEY;
        human = ARB.human();
        require(address(relay).code.length != 0, "fork: no EnsAgentRelay at the recorded address");
        address agent = ARB.agent();
        require(agent == address(relay) || agent == judgeKey, "fork: AIArbiter.agent() is neither the relay nor the judge key");
        require(relay.judge() == judgeKey, "fork: judge.rentouts.eth is not held by the judge key");
        assertEq(SUBNAMES.nameOf(judgeKey), "judge.rentouts.eth");

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

    /// @dev Live since block 11783678; re-applied on the fork only if the human has rolled back since.
    function _switchOn() internal {
        if (ARB.agent() == address(relay)) return;
        vm.prank(human);
        ARB.setAgent(address(relay));
    }

    function test_RelayWiring() public {
        assertEq(address(relay.arbiter()), address(ARB));
        assertEq(address(relay.subnames()), address(SUBNAMES));
        assertEq(relay.label(), "judge");
        assertEq(relay.labelId(), uint256(keccak256("judge")));
        assertEq(relay.name(), "judge.rentouts.eth");
        assertEq(relay.judge(), judgeKey, "the ENS judge is the judge key");
        assertTrue(relay.isJudge(judgeKey));
        assertFalse(relay.isJudge(DEPLOYER));
        assertFalse(relay.isJudge(address(0)));
    }

    /// The recorded live state (deployments.json "sepoliaAIArbiter.agent" / "sepoliaEnsAgentRelay").
    function test_LiveAgentIsTheRelay() public {
        assertEq(ARB.agent(), address(relay), "AIArbiter.agent() is the EnsAgentRelay since block 11783678");
    }

    /// The deploy script builds a relay whose runtime code is byte-identical to the live one (no drift
    /// between src/EnsAgentRelay.sol and what is on Sepolia), and which names the same judge.
    function test_DeployScriptMatchesTheLiveRelay() public {
        DeployEnsAgentRelay deployScript = new DeployEnsAgentRelay();
        EnsAgentRelay fresh = deployScript.deploy(DEPLOYER, address(ARB), address(SUBNAMES), "judge");
        assertEq(address(fresh).code, address(relay).code, "runtime code == live relay");
        assertEq(fresh.judge(), judgeKey);
        assertEq(fresh.name(), relay.name());
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

    /// FORK ONLY: the live name is never revoked (labels are single-use in RentoutsSubnames).
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

    /// Rollback, as ../sign-judge-name.sh rollback sends it: the human's setAgent(judge key).
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
