// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {JudgeName, IAIArbiterAgent} from "../script/JudgeName.s.sol";
import {RentoutsSubnames} from "../src/RentoutsSubnames.sol";
import {IAddrResolver, ITextResolver, IUniversalResolver, IUserRegistry} from "../src/interfaces/IENSv2.sol";
import {EnsSepolia} from "../script/EnsSepolia.sol";

/// @dev JudgeName with the same per-instance env / sender seams as DeployEnsHarness.
contract JudgeNameHarness is JudgeName {
    mapping(string key => string) internal env;
    mapping(string key => bool) internal envSet;
    address internal senderOverride;

    function setEnv(string memory key, string memory value) external {
        env[key] = value;
        envSet[key] = true;
    }

    function setSender(address a) external {
        senderOverride = a;
    }

    function _sender() internal view override returns (address) {
        return senderOverride == address(0) ? msg.sender : senderOverride;
    }

    function _statePath() internal view override returns (string memory) {
        require(envSet["ENS_STATE"], "harness: set ENS_STATE to a test file");
        return env["ENS_STATE"];
    }

    function _envString(string memory key) internal view override returns (string memory) {
        require(envSet[key], string.concat("harness: env ", key, " not set"));
        return env[key];
    }

    function _envAddress(string memory key) internal view override returns (address) {
        return vm.parseAddress(_envString(key));
    }

    function _envOr(string memory key, string memory dflt) internal view override returns (string memory) {
        return envSet[key] ? env[key] : dflt;
    }

    function _envOr(string memory key, address dflt) internal view override returns (address) {
        return envSet[key] ? vm.parseAddress(env[key]) : dflt;
    }

    function _envOr(string memory key, bool dflt) internal view override returns (bool) {
        return envSet[key] ? vm.parseBool(env[key]) : dflt;
    }

    function _envOr(string memory key, uint256 dflt) internal view override returns (uint256) {
        return envSet[key] ? vm.parseUint(env[key]) : dflt;
    }
}

/// @dev The live EnsAgentRelay's views (src/EnsAgentRelay.sol in the root project).
interface IJudgeRelayView {
    function judge() external view returns (address);
    function name() external view returns (string memory);
}

interface IAIArbiterAdmin {
    function human() external view returns (address);
    function setAgent(address newAgent) external;
}

/// @notice judge.rentouts.eth as it is LIVE on Sepolia, checked on a fork: the real RentoutsSubnames,
///         registry, resolver, AIArbiter, EnsAgentRelay and Universal Resolver. Since Sat 12:47 JST the
///         name is held by the judge key 0x4a44…d0dA (register tx 0x5454ab9b…4e73, block 11783660; the
///         judge key set description + url in blocks 11783662-3), and since 12:51 JST AIArbiter.agent() is
///         the EnsAgentRelay 0xe56E…C3eE (setAgent tx 0x0fc2c12c…44ad, block 11783678), which forwards
///         proposals only for the name's holder. Labels are single-use, so the live name is never revoked:
///         the revoke case runs on the fork only. The pre-broadcast rehearsal of registerJudge /
///         judgeProfile on a fresh label is in docs/ens/LOG.md (Sat 12:44). Nothing is broadcast.
///         Run: forge test --match-path test/JudgeName.fork.t.sol -vv
contract JudgeNameForkTest is Test {
    using stdJson for string;

    string constant NAME = "judge.rentouts.eth";
    address constant DEPLOYER = 0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE; // RentoutsSubnames admin + issuer
    address constant JUDGE_KEY = 0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA; // keystore rentouts-judge
    address constant RELAY = 0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE; // EnsAgentRelay = AIArbiter.agent()

    IUniversalResolver ur = IUniversalResolver(EnsSepolia.UNIVERSAL_RESOLVER);
    JudgeNameHarness script;
    RentoutsSubnames sub;
    IUserRegistry registry;
    address arbiter;
    uint256 id = uint256(keccak256("judge"));
    string statePath;

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")));
        string memory live = vm.readFile("deployments/sepolia.json");
        sub = RentoutsSubnames(live.readAddress(".rentoutsSubnames"));
        registry = IUserRegistry(address(sub.registry()));
        script = new JudgeNameHarness();
        arbiter = script.SEPOLIA_AI_ARBITER();

        // The live state this whole feature rests on.
        require(sub.holderOf(id) == JUDGE_KEY, "fork: judge.rentouts.eth is not held by the judge key any more");
        require(sub.isIssuer(DEPLOYER), "fork: deployer is no longer an issuer");

        script.setEnv("ENS_PARENT_LABEL", "rentouts");
        script.setEnv("BROADCAST", "true");
    }

    /// @dev Each test gets its own copy of the live state file (forge runs tests in parallel). With
    ///      `withJudge` false the copy has no judgeHolder / judgeName, as before the name was recorded.
    function _useState(string memory name, bool withJudge) internal {
        statePath = string.concat("deployments/test-judge-", name, ".json");
        string memory json = vm.readFile("deployments/sepolia.json");
        if (!withJudge) {
            json = vm.replace(json, string.concat('"judgeHolder": "', vm.toString(JUDGE_KEY), '",'), "");
            json = vm.replace(json, string.concat('"judgeName": "', NAME, '",'), "");
            assertFalse(json.keyExists(".judgeHolder"), "strip judgeHolder");
            assertFalse(json.keyExists(".judgeName"), "strip judgeName");
        }
        vm.writeFile(statePath, json);
        script.setEnv("ENS_STATE", statePath);
    }

    function test_JudgeKeyIsAPlainEoa() public view {
        assertEq(JUDGE_KEY.code.length, 0, "judge key has code (EIP-7702?): the ENSIP-19 default addr would not be written");
    }

    function test_LiveNameResolvesToTheJudgeKey() public view {
        assertEq(_addr(NAME), JUDGE_KEY, "UR addr(judge.rentouts.eth)");
        assertEq(sub.nameOf(JUDGE_KEY), NAME);
        assertEq(registry.getOwner(id), JUDGE_KEY);
        assertEq(registry.getExpiry(id), type(uint64).max);
        assertFalse(sub.retired(id));

        assertEq(_text(NAME, "description"), script.judgeDescription(arbiter));
        assertEq(
            _text(NAME, "description"),
            "RentOuts AI dispute judge: proposes rulings on AIArbiter 0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5; humans can appeal and override"
        );
        assertEq(_text(NAME, "url"), "https://github.com/AiAlchemist0/rentouts-escrow");
        assertEq(_text(NAME, "rentouts.status"), "active");
        assertEq(_text(NAME, "rentouts.credential"), "tenant/v1");

        // The committed state file names what the chain shows.
        string memory json = vm.readFile("deployments/sepolia.json");
        assertEq(json.readAddress(".judgeHolder"), JUDGE_KEY);
        assertEq(json.readString(".judgeName"), NAME);
    }

    /// ENS gates the AI on-chain: AIArbiter's agent is the relay, and the relay's judge is the name's address.
    function test_AIArbiterAgentIsTheRelayAndItsJudgeIsTheName() public view {
        assertEq(IAIArbiterAgent(arbiter).agent(), RELAY, "AIArbiter.agent() is the EnsAgentRelay");
        assertEq(IJudgeRelayView(RELAY).judge(), JUDGE_KEY, "relay.judge()");
        assertEq(IJudgeRelayView(RELAY).judge(), _addr(NAME), "relay.judge() == addr(judge.rentouts.eth)");
        assertEq(IJudgeRelayView(RELAY).name(), NAME);
    }

    /// The mismatch check the judge and the app rely on: true only for the name's own address.
    function test_ResolvesToRejectsAnyOtherAddress() public {
        assertTrue(script.resolvesTo(NAME, JUDGE_KEY));
        assertFalse(script.resolvesTo(NAME, RELAY), "the relay is the agent, not the name's address");
        assertFalse(script.resolvesTo(NAME, DEPLOYER));
        assertFalse(script.resolvesTo(NAME, address(0)));
        assertFalse(script.resolvesTo(NAME, makeAddr("rentouts.test.impostor")));
    }

    function test_Soulbound() public {
        uint256 tokenId = registry.getTokenId(id);
        address other = makeAddr("rentouts.test.impostor");

        vm.prank(JUDGE_KEY);
        vm.expectRevert(abi.encodeWithSignature("TransferDisallowed(uint256,address)", tokenId, JUDGE_KEY));
        registry.unsafeTransfer(other, tokenId, "");

        vm.prank(JUDGE_KEY);
        vm.expectRevert(bytes4(keccak256("TransferUnsafeUntilRegistryIsEmancipated()")));
        registry.safeTransferFrom(JUDGE_KEY, other, tokenId, 1, "");

        assertEq(_addr(NAME), JUDGE_KEY);
    }

    /// RentoutsSubnames.setProfileText is holder-only: the issuer registered, the judge key wrote its profile.
    function test_OnlyTheJudgeKeySetsItsProfile() public {
        _useState("profile", true);
        script.setSender(DEPLOYER);
        vm.expectRevert(bytes(string.concat("only the holder sets profile texts (RentoutsSubnames.setProfileText): --sender ", vm.toString(JUDGE_KEY))));
        script.judgeProfile();

        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.NotHolder.selector, "judge"));
        sub.setProfileText("judge", "description", "not the judge");

        // Live texts are already set: the judge key's re-run sends nothing.
        script.setSender(JUDGE_KEY);
        uint64 nonce = vm.getNonce(JUDGE_KEY);
        script.judgeProfile();
        assertEq(vm.getNonce(JUDGE_KEY), nonce);
    }

    /// With the relay as AIArbiter.agent(), registerJudge names the relay's judge (never the relay), sends
    /// nothing, and records judgeHolder in the state file, keeping every other key.
    function test_RegisterJudgeRerunRecordsTheRelaysJudge() public {
        _useState("record", false);
        script.setSender(DEPLOYER);
        uint64 nonce = vm.getNonce(DEPLOYER);
        script.registerJudge();
        assertEq(vm.getNonce(DEPLOYER), nonce, "re-run sent a transaction");
        string memory json = vm.readFile(statePath);
        assertEq(json.readAddress(".judgeHolder"), JUDGE_KEY);
        assertEq(json.readString(".judgeName"), NAME);
        assertEq(json.readAddress(".rentoutsSubnames"), address(sub));
        assertEq(json.readAddress(".credentialSync"), vm.readFile("deployments/sepolia.json").readAddress(".credentialSync"));
    }

    function test_NoStateWrittenOnDryRun() public {
        _useState("dryrun", false);
        script.setEnv("BROADCAST", "false");
        script.setSender(DEPLOYER);
        script.registerJudge();
        assertFalse(vm.readFile(statePath).keyExists(".judgeHolder"));
    }

    /// Rollback (the human's setAgent(judge key)): the name still resolves to the agent, nothing to send.
    function test_AfterRollbackTheNameIsTheAgent() public {
        vm.prank(IAIArbiterAdmin(arbiter).human());
        IAIArbiterAdmin(arbiter).setAgent(JUDGE_KEY);
        assertEq(IAIArbiterAgent(arbiter).agent(), JUDGE_KEY);
        assertTrue(script.resolvesTo(NAME, IAIArbiterAgent(arbiter).agent()));

        _useState("rollback", true);
        script.setSender(DEPLOYER);
        uint64 nonce = vm.getNonce(DEPLOYER);
        script.registerJudge();
        assertEq(vm.getNonce(DEPLOYER), nonce);
    }

    /// FORK ONLY (labels are single-use, so the live name is never revoked): revoking judge.rentouts.eth
    /// empties the name and the relay's judge, and the label cannot be issued again.
    function test_RevokeOnForkEmptiesTheNameAndTheRelaysJudge() public {
        vm.prank(DEPLOYER);
        sub.revoke("judge", "fork rehearsal");
        assertTrue(sub.retired(id));
        assertEq(sub.holderOf(id), address(0));
        assertEq(registry.getOwner(id), address(0));
        assertFalse(script.resolvesTo(NAME, JUDGE_KEY));
        assertEq(IJudgeRelayView(RELAY).judge(), address(0), "the relay forwards for nobody");

        _useState("revoked", true);
        script.setSender(DEPLOYER);
        vm.expectRevert(bytes("the relay names no live judge: register the judge EOA first"));
        script.registerJudge();

        vm.prank(DEPLOYER);
        vm.expectRevert();
        sub.register("judge", JUDGE_KEY);
    }

    // ------------------------------------------------------------------ UR helpers

    function _addr(string memory name) internal view returns (address) {
        (bytes memory result,) = ur.resolve(_dns(name), abi.encodeCall(IAddrResolver.addr, (_namehash(name))));
        return abi.decode(result, (address));
    }

    function _text(string memory name, string memory key) internal view returns (string memory) {
        (bytes memory result,) = ur.resolve(_dns(name), abi.encodeCall(ITextResolver.text, (_namehash(name), key)));
        return abi.decode(result, (string));
    }

    /// @dev judge.rentouts.eth only.
    function _dns(string memory) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(5), "judge", uint8(8), "rentouts", uint8(3), "eth", uint8(0));
    }

    function _namehash(string memory) internal pure returns (bytes32 node) {
        node = keccak256(abi.encodePacked(bytes32(0), keccak256("eth")));
        node = keccak256(abi.encodePacked(node, keccak256("rentouts")));
        node = keccak256(abi.encodePacked(node, keccak256("judge")));
    }
}
