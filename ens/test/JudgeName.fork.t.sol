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

/// @notice judge.rentouts.eth against the LIVE Sepolia deployment on a fork: the real RentoutsSubnames,
///         registry, resolver, AIArbiter and Universal Resolver. The script's phases run as the deployer
///         (issuer) and then as the judge key, exactly as sign-judge-name.sh sends them. Nothing is broadcast.
///         Run: forge test --match-path test/JudgeName.fork.t.sol -vv
contract JudgeNameForkTest is Test {
    using stdJson for string;

    string constant NAME = "judge.rentouts.eth";
    address constant DEPLOYER = 0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE; // RentoutsSubnames admin + issuer

    IUniversalResolver ur = IUniversalResolver(EnsSepolia.UNIVERSAL_RESOLVER);
    JudgeNameHarness script;
    RentoutsSubnames sub;
    IUserRegistry registry;
    address agent;
    string statePath;

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")));
        string memory live = vm.readFile("deployments/sepolia.json");
        sub = RentoutsSubnames(live.readAddress(".rentoutsSubnames"));
        registry = IUserRegistry(address(sub.registry()));
        script = new JudgeNameHarness();
        agent = IAIArbiterAgent(script.SEPOLIA_AI_ARBITER()).agent();

        // The live preconditions this whole feature rests on.
        uint256 id = uint256(keccak256("judge"));
        require(registry.getExpiry(id) == 0 && !sub.retired(id), "fork: judge label already taken on Sepolia");
        require(bytes(sub.labelOf(agent)).length == 0, "fork: the agent already has a name");
        require(sub.isIssuer(DEPLOYER), "fork: deployer is no longer an issuer");

        script.setEnv("ENS_PARENT_LABEL", "rentouts");
        script.setEnv("BROADCAST", "true");
    }

    /// @dev Each test gets its own copy of the live state file (forge runs tests in parallel).
    function _useState(string memory name) internal {
        statePath = string.concat("deployments/test-judge-", name, ".json");
        vm.writeFile(statePath, vm.readFile("deployments/sepolia.json"));
        script.setEnv("ENS_STATE", statePath);
    }

    function _registerAndProfile() internal {
        script.setSender(DEPLOYER);
        script.registerJudge();
        script.setSender(agent);
        script.judgeProfile();
    }

    function test_AgentIsAPlainEoa() public view {
        assertTrue(agent != address(0));
        assertEq(agent.code.length, 0, "agent has code (EIP-7702?): the ENSIP-19 default addr would not be written");
    }

    function test_JudgeNameResolvesToAIArbiterAgent() public {
        _useState("resolve");
        _registerAndProfile();

        assertEq(_addr(NAME), agent, "UR addr(judge.rentouts.eth)");
        assertEq(_addr(NAME), IAIArbiterAgent(script.SEPOLIA_AI_ARBITER()).agent(), "== AIArbiter.agent()");
        assertEq(sub.nameOf(agent), NAME);
        assertEq(registry.getOwner(uint256(keccak256("judge"))), agent);
        assertEq(registry.getExpiry(uint256(keccak256("judge"))), type(uint64).max);

        assertEq(_text(NAME, "description"), script.judgeDescription(script.SEPOLIA_AI_ARBITER()));
        assertEq(
            _text(NAME, "description"),
            "RentOuts AI dispute judge: proposes rulings on AIArbiter 0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5; humans can appeal and override"
        );
        assertEq(_text(NAME, "url"), "https://github.com/AiAlchemist0/rentouts-escrow");
        assertEq(_text(NAME, "rentouts.status"), "active");
        assertEq(_text(NAME, "rentouts.credential"), "tenant/v1");
    }

    /// The mismatch check the judge and the app rely on: true only for the name's own address.
    function test_ResolvesToRejectsAnyOtherAddress() public {
        _useState("mismatch");
        assertFalse(script.resolvesTo(NAME, agent), "unregistered name resolves to nothing");
        _registerAndProfile();
        assertTrue(script.resolvesTo(NAME, agent));
        assertFalse(script.resolvesTo(NAME, DEPLOYER));
        assertFalse(script.resolvesTo(NAME, address(0)));
        assertFalse(script.resolvesTo(NAME, makeAddr("rentouts.test.impostor")));
    }

    function test_Soulbound() public {
        _useState("soulbound");
        _registerAndProfile();
        uint256 tokenId = registry.getTokenId(uint256(keccak256("judge")));
        address other = makeAddr("rentouts.test.impostor");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSignature("TransferDisallowed(uint256,address)", tokenId, agent));
        registry.unsafeTransfer(other, tokenId, "");

        vm.prank(agent);
        vm.expectRevert(bytes4(keccak256("TransferUnsafeUntilRegistryIsEmancipated()")));
        registry.safeTransferFrom(agent, other, tokenId, 1, "");

        assertEq(_addr(NAME), agent);
    }

    /// RentoutsSubnames.setProfileText is holder-only: the issuer registers, the judge key writes its profile.
    function test_OnlyTheJudgeKeySetsItsProfile() public {
        _useState("profile");
        script.setSender(DEPLOYER);
        script.registerJudge();
        vm.expectRevert(bytes(string.concat("only the holder sets profile texts (RentoutsSubnames.setProfileText): --sender ", vm.toString(agent))));
        script.judgeProfile();

        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.NotHolder.selector, "judge"));
        sub.setProfileText("judge", "description", "not the judge");

        script.setSender(agent);
        script.judgeProfile();
        // Re-run: already set, sends nothing.
        uint64 nonce = vm.getNonce(agent);
        script.judgeProfile();
        assertEq(vm.getNonce(agent), nonce);
    }

    /// The state file names the judge only once the chain shows it: the registering run records nothing,
    /// the re-run (no transactions) records it.
    function test_StateRecordedOnlyOnceOnChain() public {
        _useState("record");
        script.setSender(DEPLOYER);
        script.registerJudge();
        assertFalse(vm.readFile(statePath).keyExists(".judgeHolder"), "recorded before the chain showed it");

        uint64 nonce = vm.getNonce(DEPLOYER);
        script.registerJudge();
        assertEq(vm.getNonce(DEPLOYER), nonce, "re-run sent a transaction");
        string memory json = vm.readFile(statePath);
        assertEq(json.readAddress(".judgeHolder"), agent);
        assertEq(json.readString(".judgeName"), NAME);
        // Everything else the live file holds survives.
        assertEq(json.readAddress(".rentoutsSubnames"), address(sub));
        assertEq(json.readAddress(".credentialSync"), vm.readFile("deployments/sepolia.json").readAddress(".credentialSync"));
    }

    function test_NoStateWrittenOnDryRun() public {
        _useState("dryrun");
        script.setEnv("BROADCAST", "false");
        script.setSender(DEPLOYER);
        script.registerJudge();
        script.registerJudge();
        assertFalse(vm.readFile(statePath).keyExists(".judgeHolder"));
    }

    function test_OnlyAnIssuerRegisters() public {
        _useState("issuer");
        script.setSender(makeAddr("rentouts.test.mallory"));
        vm.expectRevert(bytes("sender is not a RentoutsSubnames issuer"));
        script.registerJudge();
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
