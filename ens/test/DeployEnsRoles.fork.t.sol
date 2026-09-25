// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CredentialSync} from "../src/CredentialSync.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {ALL_ROLES, IPermissionedResolver, ResolverRoles} from "../src/interfaces/IENSv2.sol";
import {DeployEnsHarness} from "./DeployEnsHarness.sol";
import {EnsForkBase} from "./EnsForkBase.sol";

/// @notice The issuer EOA's key-scoped resolver roles, as the deploy script sets them, against live
///         ENSv2 on a Sepolia fork. Nothing is broadcast.
///         The expected keys are derived independently of the script: the escrow-derived set is read
///         from CredentialSync's constants and the judged set is listed here. The issuer is seeded with a
///         role on every derived key first, so a key dropped from the script's DERIVED_KEYS leaves a role
///         behind and fails these tests instead of passing vacuously.
contract DeployEnsRolesForkTest is EnsForkBase {
    DeployEnsHarness script;

    string[] judged;
    string[] derived;

    function setUp() public override {
        super.setUp();
        script = new DeployEnsHarness();
        // The harness stands in for the deployer (all root resolver roles), whose calls the script sends.
        vm.prank(deployer);
        resolver.grantRootRoles(ALL_ROLES, address(script));

        judged = ["rentouts.onTimeRate", "rentouts.rating", "rentouts.verified"];
        // The keys CredentialSync writes are the escrow-derived keys.
        CredentialSync cs = new CredentialSync(IRentEscrow(address(1)), subnames);
        derived = [
            cs.LEASES_COMPLETED_KEY(),
            cs.DISPUTES_KEY(),
            cs.RENT_PAID_KEY(),
            cs.DEPOSIT_RETURN_RATE_KEY(),
            cs.ESCROW_KEY()
        ];
    }

    /// The script's key lists are exactly the independent sets: drift either way fails.
    function test_ScriptKeyListsMatchCredentialSync() public view {
        _assertSameSet(script.derivedKeys(), derived);
        _assertSameSet(script.issuerKeys(), judged);
    }

    /// Live state before the fix: the first deploy granted the issuer EOA escrow-derived keys (three of
    /// them; seeded here with all five). Re-running subnames() must take every one away and grant none.
    function test_SubnamesGivesIssuerOnlyJudgedKeys() public {
        _claim(alice, "alice");
        bytes memory dns = subnames.dnsName("alice");
        _grantIssuer(derived);
        for (uint256 i; i < derived.length; ++i) {
            vm.prank(issuer);
            resolver.setText(dns, derived[i], "99"); // precondition: each leftover grant works
        }

        script.wireIssuerKeyRoles(resolver, issuer);
        script.wireIssuerKeyRoles(resolver, issuer); // re-run: no-op, grants nothing back

        for (uint256 i; i < judged.length; ++i) {
            vm.prank(issuer);
            resolver.setText(dns, judged[i], "1");
            assertEq(_text(_name("alice"), judged[i]), "1");
        }
        _assertIssuerCannotWrite(dns, derived);
    }

    function test_RemoveIssuerRevokesEveryKeyRole() public {
        _claim(alice, "alice");
        bytes memory dns = subnames.dnsName("alice");
        script.wireIssuerKeyRoles(resolver, issuer);
        _grantIssuer(derived); // worst case: a role on every key, judged and derived

        script.revokeIssuerKeyRoles(resolver, issuer);
        script.revokeIssuerKeyRoles(resolver, issuer); // re-run: nothing left to revoke, no revert

        _assertIssuerCannotWrite(dns, judged);
        _assertIssuerCannotWrite(dns, derived);
    }

    function _grantIssuer(string[] memory keys) internal {
        vm.startPrank(deployer);
        for (uint256 i; i < keys.length; ++i) {
            resolver.grantSetterRoles(abi.encodeCall(IPermissionedResolver.setText, (hex"00", keys[i], "")), issuer);
        }
        vm.stopPrank();
    }

    function _assertIssuerCannotWrite(bytes memory dns, string[] memory keys) internal {
        for (uint256 i; i < keys.length; ++i) {
            assertEq(resolver.roles(uint256(keccak256(bytes(keys[i]))), issuer) & ResolverRoles.ROLE_SET_TEXT, 0, keys[i]);
            vm.prank(issuer);
            vm.expectPartialRevert(EAC_UNAUTHORIZED);
            resolver.setText(dns, keys[i], "99");
        }
    }

    function _assertSameSet(string[] memory got, string[] memory want) internal pure {
        assertEq(got.length, want.length, "key count");
        for (uint256 i; i < want.length; ++i) {
            bool found;
            for (uint256 j; j < got.length; ++j) {
                if (keccak256(bytes(got[j])) == keccak256(bytes(want[i]))) found = true;
            }
            assertTrue(found, want[i]);
        }
    }
}
