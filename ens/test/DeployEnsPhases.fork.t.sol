// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {stdJson} from "forge-std/StdJson.sol";
import {CredentialSync} from "../src/CredentialSync.sol";
import {RentoutsSubnames} from "../src/RentoutsSubnames.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {IPermissionedResolver, ResolverRoles} from "../src/interfaces/IENSv2.sol";
import {DeployEnsHarness} from "./DeployEnsHarness.sol";
import {EnsForkBase} from "./EnsForkBase.sol";

/// @dev Stands in for RentEscrow: the credentialSync phase only checks that tenantStats answers.
contract StubEscrow {
    function tenantStats(address) external pure returns (IRentEscrow.TenantStats memory s) {}
}

/// @notice The deploy script's phases, run end to end against live ENSv2 on a Sepolia fork. The script
///         sends from `deployer` (as `--sender` does) and reads and writes its own state file,
///         deployments/test-<name>.json, which starts like the live one: infra, parent, RentoutsSubnames
///         and issuer. Nothing is broadcast.
///         Run: forge test --match-path test/DeployEnsPhases.fork.t.sol -vv
contract DeployEnsPhasesForkTest is EnsForkBase {
    using stdJson for string;

    DeployEnsHarness script;
    StubEscrow escrow1;
    StubEscrow escrow2;
    string statePath;
    string[] judged;
    string[] derived;

    function setUp() public override {
        super.setUp();
        script = new DeployEnsHarness();
        script.setSender(deployer);
        script.setEnv("ENS_PARENT_LABEL", PARENT);
        script.setEnv("BROADCAST", "true");
        script.setEnv("ENS_ISSUER", vm.toString(issuer));
        escrow1 = new StubEscrow();
        escrow2 = new StubEscrow();

        judged = ["rentouts.onTimeRate", "rentouts.rating", "rentouts.verified"];
        CredentialSync cs = new CredentialSync(IRentEscrow(address(1)), subnames);
        derived = [
            cs.LEASES_COMPLETED_KEY(),
            cs.DISPUTES_KEY(),
            cs.RENT_PAID_KEY(),
            cs.DEPOSIT_RETURN_RATE_KEY(),
            cs.ESCROW_KEY()
        ];
    }

    // ------------------------------------------------------------------ credentialSync

    function test_CredentialSyncFreshThenReuse() public {
        _useState("cs-fresh");
        script.setEnv("ESCROW_ADDRESS", vm.toString(address(escrow1)));
        script.credentialSync();

        address cs = _state("pendingCredentialSync");
        assertTrue(cs.code.length != 0);
        assertEq(address(CredentialSync(cs).escrow()), address(escrow1));
        assertEq(address(CredentialSync(cs).subnames()), address(subnames));
        assertTrue(subnames.isIssuer(cs));
        assertEq(_state("credentialSync"), address(0), "not the app's address before it is confirmed");

        script.finalizeCredentialSync();
        assertEq(_state("credentialSync"), cs);
        assertEq(_state("escrow"), address(escrow1));
        assertEq(_state("pendingCredentialSync"), address(0));
        assertEq(_stateList("retiredCredentialSyncs").length, 0);

        // Same escrow again: reused, zero transactions (each broadcast call bumps the sender's nonce).
        uint64 nonce = vm.getNonce(deployer);
        script.credentialSync();
        assertEq(vm.getNonce(deployer), nonce);
        assertEq(_state("pendingCredentialSync"), cs);
        script.finalizeCredentialSync();
        assertEq(_state("credentialSync"), cs);
        assertTrue(subnames.isIssuer(cs));
        _cleanup();
    }

    function test_CredentialSyncReplaceRevokesOldIssuer() public {
        _useState("cs-replace");
        address cs1 = _deploySyncFinal(escrow1);
        _claim(alice, "alice");

        script.setEnv("ESCROW_ADDRESS", vm.toString(address(escrow2)));
        script.credentialSync();
        address cs2 = _state("pendingCredentialSync");
        assertTrue(cs2 != cs1);
        assertEq(address(CredentialSync(cs2).escrow()), address(escrow2));
        assertFalse(subnames.isIssuer(cs1));
        assertTrue(subnames.isIssuer(cs2));
        address[] memory retired = _stateList("retiredCredentialSyncs");
        assertEq(retired.length, 1);
        assertEq(retired[0], cs1);
        assertEq(_state("credentialSync"), cs1, "active stays the confirmed one until finalize");

        script.finalizeCredentialSync();
        assertEq(_state("credentialSync"), cs2);
        assertEq(_state("escrow"), address(escrow2));

        // The old sync can't write stale stats any more; the new one can.
        vm.expectRevert(RentoutsSubnames.NotIssuer.selector);
        CredentialSync(cs1).sync(alice);
        CredentialSync(cs2).sync(alice);
        assertEq(_text(_name("alice"), "rentouts.leasesCompleted"), "0");
        _cleanup();
    }

    /// Codex M1. Forge writes the state file before it broadcasts. Here the broadcast stops after the
    /// replacement is deployed: the old sync was never revoked and the new one never enabled.
    function test_CredentialSyncInterruptedReplaceIsReconciledOnRetry() public {
        _useState("cs-interrupted");
        address cs1 = _deploySyncFinal(escrow1);
        script.setEnv("ESCROW_ADDRESS", vm.toString(address(escrow2)));

        uint64 nonce = vm.getNonce(deployer);
        uint256 snap = vm.snapshotState();
        script.credentialSync(); // state written: cs2 pending, cs1 retired
        address cs2 = _state("pendingCredentialSync");
        vm.revertToState(snap); // ...and none of its transactions landed

        // Only the deploy lands: the run sends setIssuer(cs1, false) at `nonce` and the deploy at nonce + 1.
        vm.setNonce(deployer, nonce + 1);
        vm.prank(deployer);
        address landed = address(new CredentialSync(IRentEscrow(address(escrow2)), subnames));
        assertEq(landed, cs2);
        assertTrue(subnames.isIssuer(cs1));
        assertFalse(subnames.isIssuer(cs2));

        // Finalize refuses, so the app never gets an address the chain doesn't back.
        vm.expectRevert(bytes("pending CredentialSync is not an issuer (yet): re-run credentialSync"));
        script.finalizeCredentialSync();
        assertEq(_state("credentialSync"), cs1);

        // Retry: reuses the landed replacement, revokes the old writer, enables the new one.
        script.credentialSync();
        assertEq(_state("pendingCredentialSync"), cs2);
        assertFalse(subnames.isIssuer(cs1));
        assertTrue(subnames.isIssuer(cs2));
        script.finalizeCredentialSync();
        assertEq(_state("credentialSync"), cs2);
        _cleanup();
    }

    /// Nothing landed at all: the retry deploys at the same address and revokes the old sync.
    function test_CredentialSyncBroadcastThatNeverLandedIsRetried() public {
        _useState("cs-never-landed");
        address cs1 = _deploySyncFinal(escrow1);
        script.setEnv("ESCROW_ADDRESS", vm.toString(address(escrow2)));
        uint256 snap = vm.snapshotState();
        script.credentialSync();
        address cs2 = _state("pendingCredentialSync");
        vm.revertToState(snap);
        assertEq(cs2.code.length, 0);

        vm.expectRevert(bytes("pending CredentialSync is not on chain (yet): re-run credentialSync"));
        script.finalizeCredentialSync();

        script.credentialSync();
        assertEq(_state("pendingCredentialSync"), cs2, "same nonce, same address");
        assertFalse(subnames.isIssuer(cs1));
        assertTrue(subnames.isIssuer(cs2));
        address[] memory retired = _stateList("retiredCredentialSyncs");
        assertEq(retired.length, 1);
        assertEq(retired[0], cs1);
        script.finalizeCredentialSync();
        assertEq(_state("credentialSync"), cs2);
        _cleanup();
    }

    /// Every run re-checks every sync ever retired, not only the one it replaces: a retired sync that
    /// regained its issuer right (a mistaken setIssuer, or an older generation) is revoked again.
    function test_CredentialSyncReconcilesRetiredOnEveryRun() public {
        _useState("cs-reconcile");
        address cs1 = _deploySyncFinal(escrow1);
        address cs2 = _deploySyncFinal(escrow2); // cs1 retired
        address cs3 = _deploySyncFinal(escrow1); // cs2 retired; cs1 is two generations back
        assertTrue(cs3 != cs1 && cs3 != cs2);
        assertEq(_stateList("retiredCredentialSyncs").length, 2);

        vm.prank(deployer);
        subnames.setIssuer(cs1, true); // out of band

        uint64 nonce = vm.getNonce(deployer);
        script.credentialSync(); // same escrow: cs3 reused
        assertEq(vm.getNonce(deployer), nonce + 1, "one tx: revoke cs1");
        assertFalse(subnames.isIssuer(cs1));
        assertFalse(subnames.isIssuer(cs2));
        assertTrue(subnames.isIssuer(cs3));
        script.finalizeCredentialSync();
        assertEq(_state("credentialSync"), cs3);
        _cleanup();
    }

    /// Codex M2. After RentoutsSubnames is replaced, the old sync must lose its issuer right on the
    /// RentoutsSubnames it writes through (the old one), not on the new one where it never had it.
    function test_CredentialSyncRevokesOldSyncOnItsOwnSubnames() public {
        _useState("cs-new-subnames");
        address cs1 = _deploySyncFinal(escrow1);
        vm.startPrank(deployer);
        RentoutsSubnames next = _deploySubnames();
        vm.stopPrank();
        _setStateKey("rentoutsSubnames", address(next));

        script.credentialSync(); // same ESCROW_ADDRESS, new RentoutsSubnames
        address cs2 = _state("pendingCredentialSync");
        assertTrue(cs2 != cs1);
        assertEq(address(CredentialSync(cs2).subnames()), address(next));
        assertFalse(subnames.isIssuer(cs1), "old sync still an issuer on its own RentoutsSubnames");
        assertFalse(next.isIssuer(cs1));
        assertTrue(next.isIssuer(cs2));
        script.finalizeCredentialSync();
        assertEq(_state("credentialSync"), cs2);
        _cleanup();
    }

    // ------------------------------------------------------------------ state / wiring checks (Codex L3)

    function test_RefusesStateFileOfAnotherParent() public {
        statePath = "deployments/test-other-parent.json";
        script.setEnv("ENS_STATE", statePath);
        _writeState("someoneelse.eth", address(subnames));
        bytes memory err = bytes(
            string.concat(
                statePath,
                " is for someoneelse.eth, not ",
                PARENT,
                ".eth: fix ENS_PARENT_LABEL or use a new ENS_STATE file"
            )
        );
        vm.expectRevert(err);
        script.subnames();
        vm.expectRevert(err);
        script.status();
        _cleanup();
    }

    function test_RefusesRentoutsSubnamesOfAnotherParent() public {
        _useState("other-subnames");
        RentoutsSubnames other = new RentoutsSubnames(registry, resolver, "someoneelse", deployer);
        _setStateKey("rentoutsSubnames", address(other));
        bytes memory err = bytes(
            string.concat("RentoutsSubnames ", vm.toString(address(other)), " serves someoneelse.eth, not ", PARENT, ".eth")
        );
        vm.expectRevert(err);
        script.subnames();
        script.setEnv("ESCROW_ADDRESS", vm.toString(address(escrow1)));
        vm.expectRevert(err);
        script.credentialSync();
        script.setEnv("ENS_REMOVE_ISSUER", vm.toString(issuer));
        vm.expectRevert(err);
        script.removeIssuer();
        _cleanup();
    }

    // ------------------------------------------------------------------ issuer (Fable ops M)

    function test_RemoveIssuerSticks() public {
        _useState("remove-issuer");
        script.subnames(); // wires the issuer, as in the live state
        assertTrue(subnames.isIssuer(issuer));
        assertEq(_state("issuer"), issuer);

        script.setEnv("ENS_REMOVE_ISSUER", vm.toString(issuer));
        script.removeIssuer();
        assertFalse(subnames.isIssuer(issuer));
        _assertNoKeyRoles(issuer, judged);
        _assertNoKeyRoles(issuer, derived);
        assertEq(_state("issuer"), address(0), "state file still names the removed issuer");
        address[] memory removed = _stateList("removedIssuers");
        assertEq(removed.length, 1);
        assertEq(removed[0], issuer);

        // ENS_ISSUER still names it: a later subnames/all run refuses instead of granting it back.
        vm.expectRevert(
            bytes(
                string.concat(
                    "ENS_ISSUER ",
                    vm.toString(issuer),
                    " was removed by removeIssuer: set a new ENS_ISSUER, or ENS_REINSTATE_ISSUER=<that address> to re-enable it"
                )
            )
        );
        script.subnames();
        assertFalse(subnames.isIssuer(issuer));

        // A new issuer is wired; the removed one stays removed.
        address issuer2 = makeAddr("rentouts.test.issuer2");
        script.setEnv("ENS_ISSUER", vm.toString(issuer2));
        script.subnames();
        assertTrue(subnames.isIssuer(issuer2));
        assertFalse(subnames.isIssuer(issuer));
        _assertNoKeyRoles(issuer, judged);
        assertEq(_state("issuer"), issuer2);
        assertEq(_stateList("removedIssuers").length, 1);

        // Re-enabling the removed account takes an explicit override that names it.
        script.setEnv("ENS_ISSUER", vm.toString(issuer));
        script.setEnv("ENS_REINSTATE_ISSUER", vm.toString(issuer));
        script.subnames();
        assertTrue(subnames.isIssuer(issuer));
        assertEq(_stateList("removedIssuers").length, 0);
        assertEq(_state("issuer"), issuer);
        _cleanup();
    }

    /// The pending live cleanup: re-running subnames on the deployed RentoutsSubnames revokes the issuer
    /// EOA's roles on escrow-derived keys (seeded on all five), keeps the judged keys and changes
    /// nothing else. A second run sends nothing.
    function test_SubnamesRerunRevokesDerivedKeyRoles() public {
        _useState("subnames-rerun");
        vm.startPrank(deployer);
        for (uint256 i; i < derived.length; ++i) {
            resolver.grantSetterRoles(abi.encodeCall(IPermissionedResolver.setText, (hex"00", derived[i], "")), issuer);
        }
        vm.stopPrank();

        uint64 nonce = vm.getNonce(deployer);
        script.subnames();
        // 2 grants (rating, verified; setUp granted onTimeRate) + 5 revokes. No deploy, no other change.
        assertEq(vm.getNonce(deployer), nonce + 7);
        assertEq(_state("rentoutsSubnames"), address(subnames));
        _assertNoKeyRoles(issuer, derived);
        for (uint256 i; i < judged.length; ++i) {
            assertTrue(resolver.roles(uint256(keccak256(bytes(judged[i]))), issuer) & ResolverRoles.ROLE_SET_TEXT != 0);
        }

        nonce = vm.getNonce(deployer);
        script.subnames();
        assertEq(vm.getNonce(deployer), nonce, "re-run sent transactions");

        _claim(alice, "alice");
        bytes memory dns = subnames.dnsName("alice");
        vm.prank(issuer);
        resolver.setText(dns, "rentouts.rating", "5");
        vm.prank(issuer);
        vm.expectPartialRevert(EAC_UNAUTHORIZED);
        resolver.setText(dns, "rentouts.leasesCompleted", "99");
        _cleanup();
    }

    function test_DryRunLeavesStateFileUntouched() public {
        _useState("dry-run");
        string memory before = vm.readFile(statePath);
        script.setEnv("BROADCAST", "false");
        script.setEnv("ESCROW_ADDRESS", vm.toString(address(escrow1)));
        script.credentialSync();
        script.setEnv("ENS_REMOVE_ISSUER", vm.toString(issuer));
        script.removeIssuer();
        assertEq(vm.readFile(statePath), before);
        _cleanup();
    }

    // ------------------------------------------------------------------ helpers

    /// @dev A state file like the live one: infra, parent, RentoutsSubnames and issuer.
    function _useState(string memory name) internal {
        statePath = string.concat("deployments/test-", name, ".json");
        script.setEnv("ENS_STATE", statePath);
        _writeState(string.concat(PARENT, ".eth"), address(subnames));
    }

    function _writeState(string memory parentName, address sub) internal {
        string memory o = string.concat("teststate:", statePath);
        vm.serializeJson(o, "{}");
        o.serialize("ensParentName", parentName);
        o.serialize("chainId", block.chainid);
        o.serialize("permissionedResolver", address(resolver));
        o.serialize("userRegistry", address(registry));
        o.serialize("rentoutsSubnames", sub);
        vm.writeJson(o.serialize("issuer", issuer), statePath);
    }

    function _setStateKey(string memory key, address value) internal {
        vm.writeJson(string.concat('"', vm.toString(value), '"'), statePath, string.concat(".", key));
        assertEq(_state(key), value);
    }

    function _deploySyncFinal(StubEscrow e) internal returns (address cs) {
        script.setEnv("ESCROW_ADDRESS", vm.toString(address(e)));
        script.credentialSync();
        cs = _state("pendingCredentialSync");
        script.finalizeCredentialSync();
        assertEq(_state("credentialSync"), cs);
        assertTrue(subnames.isIssuer(cs));
    }

    function _state(string memory key) internal view returns (address) {
        string memory json = vm.readFile(statePath);
        string memory path = string.concat(".", key);
        return json.keyExists(path) ? json.readAddress(path) : address(0);
    }

    function _stateList(string memory key) internal view returns (address[] memory) {
        string memory json = vm.readFile(statePath);
        string memory path = string.concat(".", key);
        return json.keyExists(path) ? json.readAddressArray(path) : new address[](0);
    }

    function _assertNoKeyRoles(address who, string[] memory keys) internal view {
        for (uint256 i; i < keys.length; ++i) {
            assertEq(resolver.roles(uint256(keccak256(bytes(keys[i]))), who) & ResolverRoles.ROLE_SET_TEXT, 0, keys[i]);
        }
    }

    function _cleanup() internal {
        vm.removeFile(statePath);
    }
}
