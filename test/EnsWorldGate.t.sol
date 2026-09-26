// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AllOfHumanGate} from "../src/AllOfHumanGate.sol";
import {EnsCredentialGate} from "../src/EnsCredentialGate.sol";
import {HumanGate} from "../src/HumanGate.sol";
import {MockEnsRegistry, MockGate, MockSubnames, Mode} from "./helpers/MockGates.sol";
import {DeployEnsWorldGate} from "../script/DeployEnsWorldGate.s.sol";

/// @notice Unit tests (mocks, no network) for the ENS + World combined gate. The live-Sepolia
///         end-to-end run is test/EnsWorldGate.fork.t.sol.
contract AllOfHumanGateTest is Test {
    address internal who = makeAddr("tenant");

    function _gates(address a) internal pure returns (address[] memory g) {
        g = new address[](1);
        g[0] = a;
    }

    function _gates(address a, address b) internal pure returns (address[] memory g) {
        g = new address[](2);
        g[0] = a;
        g[1] = b;
    }

    // ------------------------------------------------------------------ constructor

    function test_Constructor_RejectsEmpty() public {
        vm.expectRevert(AllOfHumanGate.NoGates.selector);
        new AllOfHumanGate(new address[](0));
    }

    function test_Constructor_RejectsMoreThanFour() public {
        address[] memory g = new address[](5);
        for (uint256 i; i < 5; ++i) {
            g[i] = address(new MockGate(true));
        }
        vm.expectRevert(abi.encodeWithSelector(AllOfHumanGate.TooManyGates.selector, 5));
        new AllOfHumanGate(g);
    }

    function test_Constructor_RejectsZero() public {
        address a = address(new MockGate(true));
        vm.expectRevert(abi.encodeWithSelector(AllOfHumanGate.ZeroGate.selector, 1));
        new AllOfHumanGate(_gates(a, address(0)));
    }

    function test_Constructor_RejectsNonContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(AllOfHumanGate.GateHasNoCode.selector, eoa));
        new AllOfHumanGate(_gates(eoa));
    }

    function test_Constructor_RejectsDuplicate() public {
        address a = address(new MockGate(true));
        vm.expectRevert(abi.encodeWithSelector(AllOfHumanGate.DuplicateGate.selector, a));
        new AllOfHumanGate(_gates(a, a));
    }

    function test_Gates_ListedInOrder() public {
        address a = address(new MockGate(true));
        address b = address(new MockGate(true));
        AllOfHumanGate all = new AllOfHumanGate(_gates(a, b));
        address[] memory list = all.gates();
        assertEq(all.gateCount(), 2);
        assertEq(list.length, 2);
        assertEq(list[0], a);
        assertEq(list[1], b);
        assertEq(address(all.gate(1)), b);
        vm.expectRevert(abi.encodeWithSelector(AllOfHumanGate.IndexOutOfRange.selector, 2));
        all.gate(2);
    }

    // ------------------------------------------------------------------ answers

    function test_IsVerified_AndOfAnswers() public {
        MockGate a = new MockGate(true);
        MockGate b = new MockGate(true);
        AllOfHumanGate all = new AllOfHumanGate(_gates(address(a), address(b)));
        assertTrue(all.isVerified(who));
        b.setAnswer(false);
        assertFalse(all.isVerified(who));
        a.setAnswer(false);
        b.setAnswer(true);
        assertFalse(all.isVerified(who));
    }

    function test_IsVerified_SingleGate() public {
        MockGate a = new MockGate(true);
        AllOfHumanGate all = new AllOfHumanGate(_gates(address(a)));
        assertTrue(all.isVerified(who));
        a.setAnswer(false);
        assertFalse(all.isVerified(who));
    }

    /// @dev Every failure mode of the second gate (the first says yes) must read as `false`, and
    ///      isVerified itself must not revert.
    function test_IsVerified_FailureModesAreFalse() public {
        MockGate yes = new MockGate(true);
        MockGate bad = new MockGate(true);
        AllOfHumanGate all = new AllOfHumanGate(_gates(address(yes), address(bad)));

        Mode[4] memory modes = [Mode.Revert, Mode.Empty, Mode.Short, Mode.GasHog];
        for (uint256 i; i < modes.length; ++i) {
            bad.setMode(modes[i]);
            assertFalse(all.isVerified(who), "failure mode must be false");
        }
        // Not ABI `true`: a bool of 2, a word with high bits, and 31 bytes.
        bad.setRaw(abi.encode(uint256(2)));
        assertFalse(all.isVerified(who), "bool 2");
        bad.setRaw(abi.encode(uint256(1) | (uint256(1) << 255)));
        assertFalse(all.isVerified(who), "dirty bool");
        bad.setRaw(new bytes(31));
        assertFalse(all.isVerified(who), "31 bytes");
        // An exact ABI `true` given as raw bytes is accepted.
        bad.setRaw(abi.encode(true));
        assertTrue(all.isVerified(who), "raw true");
        // A valid `true` with trailing bytes is still `true` (only 32 bytes are ever copied back).
        bad.setMode(Mode.Huge);
        assertTrue(all.isVerified(who), "true + padding");
    }

    /// @dev A gate that burns all its gas costs the caller at most GATE_GAS (+ overhead).
    function test_IsVerified_GasHogIsBounded() public {
        MockGate hog = new MockGate(true);
        hog.setMode(Mode.GasHog);
        AllOfHumanGate all = new AllOfHumanGate(_gates(address(hog)));
        uint256 before = gasleft();
        bool ok = all.isVerified(who);
        uint256 used = before - gasleft();
        assertFalse(ok);
        assertLt(used, all.GATE_GAS() + 30_000, "bounded by the per-gate cap");
        assertGt(used, all.GATE_GAS() - 1, "the hog did get its cap");
    }

    /// @dev Short-circuit: once a gate says no, later gates are not asked (and cannot burn gas).
    function test_IsVerified_ShortCircuits() public {
        MockGate no = new MockGate(false);
        MockGate hog = new MockGate(true);
        hog.setMode(Mode.GasHog);
        AllOfHumanGate all = new AllOfHumanGate(_gates(address(no), address(hog)));
        uint256 before = gasleft();
        assertFalse(all.isVerified(who));
        assertLt(before - gasleft(), 50_000);
    }

    /// @dev Any return data at all from a gate: never reverts, true only for an exact ABI true.
    function testFuzz_IsVerified_NeverRevertsOnArbitraryReturn(bytes calldata ret) public {
        MockGate g = new MockGate(true);
        g.setRaw(ret);
        AllOfHumanGate all = new AllOfHumanGate(_gates(address(g)));
        bool ok = all.isVerified(who);
        bool expected = ret.length >= 32 && uint256(bytes32(ret[:32])) == 1;
        assertEq(ok, expected);
    }

    /// @dev AND semantics over 1..4 gates with arbitrary answers.
    function testFuzz_IsVerified_IsAnd(uint8 n, uint8 answers) public {
        n = uint8(bound(n, 1, 4));
        address[] memory g = new address[](n);
        bool expected = true;
        for (uint256 i; i < n; ++i) {
            bool a = (answers >> i) & 1 == 1;
            expected = expected && a;
            g[i] = address(new MockGate(a));
        }
        AllOfHumanGate all = new AllOfHumanGate(g);
        assertEq(all.isVerified(who), expected);
    }

    /// @dev Plugs into HumanGate like any verifier; rollback is one setVerifier call.
    function test_HumanGate_SetVerifierAndRollback() public {
        address owner = makeAddr("owner");
        MockGate world = new MockGate(true);
        MockGate ens = new MockGate(false);
        AllOfHumanGate all = new AllOfHumanGate(_gates(address(world), address(ens)));
        HumanGate hg = new HumanGate(owner, address(world));
        assertTrue(hg.isVerified(who));

        vm.prank(owner);
        hg.setVerifier(address(all));
        assertFalse(hg.isVerified(who), "no ENS credential: blocked");
        ens.setAnswer(true);
        assertTrue(hg.isVerified(who), "World + ENS: allowed");

        vm.prank(owner);
        hg.setVerifier(address(world)); // rollback to World only
        ens.setAnswer(false);
        assertTrue(hg.isVerified(who));
    }
}

contract EnsCredentialGateTest is Test {
    MockEnsRegistry internal registry;
    MockSubnames internal subnames;
    EnsCredentialGate internal gate;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        registry = new MockEnsRegistry();
        subnames = new MockSubnames(address(registry));
        gate = new EnsCredentialGate(address(subnames));
        subnames.setLabel(alice, "alice");
        registry.setOwner("alice", alice);
    }

    // ------------------------------------------------------------------ constructor

    function test_Constructor_WiresSubnamesAndRegistry() public {
        assertEq(address(gate.subnames()), address(subnames));
        assertEq(address(gate.registry()), address(registry));
    }

    function test_Constructor_RejectsNonContractSubnames() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(EnsCredentialGate.NoCode.selector, eoa));
        new EnsCredentialGate(eoa);
    }

    function test_Constructor_RejectsZeroRegistry() public {
        MockSubnames s = new MockSubnames(address(0));
        vm.expectRevert(abi.encodeWithSelector(EnsCredentialGate.BadRegistry.selector, address(s)));
        new EnsCredentialGate(address(s));
    }

    function test_Constructor_RejectsNonContractRegistry() public {
        address eoa = makeAddr("eoa-registry");
        MockSubnames s = new MockSubnames(eoa);
        vm.expectRevert(abi.encodeWithSelector(EnsCredentialGate.NoCode.selector, eoa));
        new EnsCredentialGate(address(s));
    }

    // ------------------------------------------------------------------ answers

    function test_IsVerified_ActiveCredential() public {
        assertTrue(gate.isVerified(alice));
        assertFalse(gate.isVerified(bob), "no name");
        assertFalse(gate.isVerified(address(0)));
    }

    function test_IsVerified_RevokedLabelIsFalse() public {
        subnames.setLabel(alice, ""); // RentoutsSubnames.revoke deletes the label
        assertFalse(gate.isVerified(alice));
    }

    function test_IsVerified_UnregisteredOrExpiredNameIsFalse() public {
        registry.setOwner("alice", address(0)); // ENS getOwner is 0 once unregistered / expired
        assertFalse(gate.isVerified(alice));
    }

    function test_IsVerified_NameOwnedBySomeoneElseIsFalse() public {
        registry.setOwner("alice", bob);
        assertFalse(gate.isVerified(alice));
        // and bob does not inherit it either: he has no label of his own
        assertFalse(gate.isVerified(bob));
    }

    function test_IsVerified_LabelPointingAtAnotherNameIsFalse() public {
        subnames.setLabel(bob, "alice"); // bob claims a label ENS says alice owns
        assertFalse(gate.isVerified(bob));
        assertTrue(gate.isVerified(alice));
    }

    function test_IsVerified_SubnamesFailuresAreFalse() public {
        Mode[5] memory modes = [Mode.Revert, Mode.Empty, Mode.Short, Mode.Huge, Mode.GasHog];
        for (uint256 i; i < modes.length; ++i) {
            subnames.setMode(modes[i]);
            assertFalse(gate.isVerified(alice), "subnames failure mode must be false");
        }
        // malformed string encodings
        subnames.setRaw(abi.encodePacked(uint256(0x40), uint256(5), bytes32("alice"))); // wrong offset
        assertFalse(gate.isVerified(alice), "offset");
        subnames.setRaw(abi.encodePacked(uint256(0x20), uint256(64), bytes32("alice"))); // len past end
        assertFalse(gate.isVerified(alice), "length overflow");
        subnames.setRaw(abi.encodePacked(uint256(0x20), type(uint256).max, bytes32("alice")));
        assertFalse(gate.isVerified(alice), "huge length");
        subnames.setRaw(abi.encodePacked(uint256(0x20), uint256(0)));
        assertFalse(gate.isVerified(alice), "empty label");
        // the canonical encoding given as raw bytes still works
        subnames.setRaw(abi.encode(string("alice")));
        assertTrue(gate.isVerified(alice), "canonical raw");
        // unpadded (non-canonical but in-bounds) data is accepted: the label bytes are all there
        subnames.setRaw(abi.encodePacked(uint256(0x20), uint256(5), bytes5("alice")));
        assertTrue(gate.isVerified(alice), "unpadded");
    }

    function test_IsVerified_RegistryFailuresAreFalse() public {
        Mode[4] memory modes = [Mode.Revert, Mode.Empty, Mode.Short, Mode.GasHog];
        for (uint256 i; i < modes.length; ++i) {
            registry.setMode(modes[i]);
            assertFalse(gate.isVerified(alice), "registry failure mode must be false");
        }
        registry.setRaw(abi.encode(uint256(uint160(alice)) | (uint256(1) << 200))); // dirty address
        assertFalse(gate.isVerified(alice), "dirty address");
        registry.setRaw(abi.encode(alice));
        assertTrue(gate.isVerified(alice), "canonical raw");
    }

    /// @dev Both dependencies hogging gas: bounded by 2 x CALL_GAS (+ overhead).
    function test_IsVerified_GasHogIsBounded() public {
        registry.setMode(Mode.GasHog);
        uint256 before = gasleft();
        assertFalse(gate.isVerified(alice));
        uint256 used = before - gasleft();
        assertLt(used, 2 * gate.CALL_GAS() + 30_000);

        subnames.setMode(Mode.GasHog); // labelOf fails first: getOwner is never asked
        before = gasleft();
        assertFalse(gate.isVerified(alice));
        used = before - gasleft();
        assertLt(used, gate.CALL_GAS() + 30_000);
    }

    function testFuzz_IsVerified_NeverRevertsOnArbitraryLabelReturn(bytes calldata ret) public {
        subnames.setRaw(ret);
        gate.isVerified(alice); // must not revert, whatever labelOf returns
    }

    function testFuzz_IsVerified_NeverRevertsOnArbitraryOwnerReturn(bytes calldata ret) public {
        registry.setRaw(ret);
        bool ok = gate.isVerified(alice);
        assertEq(ok, ret.length >= 32 && uint256(bytes32(ret[:32])) == uint256(uint160(alice)));
    }

    /// @dev The combined gate: World (mock) AND ENS credential.
    function test_Composite_NeedsWorldAndEns() public {
        MockGate world = new MockGate(false);
        address[] memory g = new address[](2);
        g[0] = address(world);
        g[1] = address(gate);
        AllOfHumanGate all = new AllOfHumanGate(g);

        assertFalse(all.isVerified(alice), "ENS only");
        world.setAnswer(true);
        assertTrue(all.isVerified(alice), "World + ENS");
        assertFalse(all.isVerified(bob), "World only (no name)");
        subnames.setLabel(alice, "");
        assertFalse(all.isVerified(alice), "revoked name");
    }
}

/// @notice script/DeployEnsWorldGate.s.sol: the chain guard and the deployments.json record (on a
///         scratch copy under cache/). The deploy itself runs against live Sepolia in the fork test.
contract DeployEnsWorldGateScriptTest is Test {
    string internal constant SCRATCH_DIR = "./cache/deploy-ens-world-gate-test";
    string internal constant UPSERT_FILE = "./cache/deploy-ens-world-gate-test/upsert.json";

    DeployEnsWorldGate internal script;

    function setUp() public {
        script = new DeployEnsWorldGate();
    }

    function test_Deploy_RefusesNonSepolia() public {
        vm.expectRevert(bytes("DeployEnsWorldGate: Ethereum Sepolia (11155111) only"));
        script.deploy(makeAddr("deployer"), address(1), address(2), address(3));
    }

    function test_Record_AddsSepoliaHumanGatesKeepingOthers() public {
        MockEnsRegistry registry = new MockEnsRegistry();
        EnsCredentialGate ensGate = new EnsCredentialGate(address(new MockSubnames(address(registry))));
        address[] memory g = new address[](2);
        g[0] = address(new MockGate(true));
        g[1] = address(ensGate);
        AllOfHumanGate composite = new AllOfHumanGate(g);

        vm.createDir(SCRATCH_DIR, true);
        vm.copyFile(script.DEPLOYMENTS_FILE(), UPSERT_FILE);
        string memory original = vm.readFile(UPSERT_FILE);
        address escrow = vm.parseJsonAddress(original, ".sepolia.rentEscrow");
        address worldV4 = vm.parseJsonAddress(original, ".sepoliaWorldIdV4.worldIdV4Gate");

        script.record(UPSERT_FILE, makeAddr("deployer"), g[0], makeAddr("subnames"), makeAddr("hg"), ensGate, composite);

        string memory json = vm.readFile(UPSERT_FILE);
        assertEq(vm.parseJsonAddress(json, ".sepolia.rentEscrow"), escrow, "other entries kept");
        assertEq(vm.parseJsonAddress(json, ".sepoliaWorldIdV4.worldIdV4Gate"), worldV4, "other entries kept");
        assertEq(vm.parseJsonAddress(json, ".sepoliaHumanGates.allOfHumanGate"), address(composite));
        assertEq(vm.parseJsonAddress(json, ".sepoliaHumanGates.ensCredentialGate"), address(ensGate));
        assertEq(vm.parseJsonAddress(json, ".sepoliaHumanGates.ensRegistry"), address(registry));
        assertEq(vm.parseJsonAddress(json, ".sepoliaHumanGates.worldIdV4Gate"), g[0]);
        assertEq(vm.parseJsonAddress(json, ".sepoliaHumanGates.humanGate"), makeAddr("hg"));
        vm.removeFile(UPSERT_FILE);
    }
}
