// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployEns} from "../script/DeployEns.s.sol";
import {CredentialSync} from "../src/CredentialSync.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {ALL_ROLES, IPermissionedResolver, ResolverRoles} from "../src/interfaces/IENSv2.sol";
import {EnsForkBase} from "./EnsForkBase.sol";

/// @dev Exposes the deploy script's resolver-role helpers (used by subnames() and removeIssuer()).
contract DeployEnsHarness is DeployEns {
    function wireIssuerKeyRoles(IPermissionedResolver r, address issuer) external {
        _wireIssuerKeyRoles(r, issuer);
    }

    function revokeIssuerKeyRoles(IPermissionedResolver r, address account) external {
        _revokeIssuerKeyRoles(r, account);
    }
}

/// @notice The issuer EOA's key-scoped resolver roles, as the deploy script sets them, against live
///         ENSv2 on a Sepolia fork. Nothing is broadcast.
contract DeployEnsRolesForkTest is EnsForkBase {
    DeployEnsHarness script;

    string[3] judged = ["rentouts.onTimeRate", "rentouts.rating", "rentouts.verified"];
    string[5] derived;

    function setUp() public override {
        super.setUp();
        script = new DeployEnsHarness();
        // The harness stands in for the deployer (all root resolver roles), whose calls the script sends.
        vm.prank(deployer);
        resolver.grantRootRoles(ALL_ROLES, address(script));

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

    /// Live state before the fix: the first deploy granted the issuer EOA three escrow-derived keys.
    /// Re-running subnames() must take them away and must not grant any derived key.
    function test_SubnamesGivesIssuerOnlyJudgedKeys() public {
        _claim(alice, "alice");
        bytes memory dns = subnames.dnsName("alice");
        string[3] memory legacy = ["rentouts.leasesCompleted", "rentouts.disputes", "rentouts.escrow"];
        vm.startPrank(deployer);
        for (uint256 i; i < legacy.length; ++i) {
            resolver.grantSetterRoles(abi.encodeCall(IPermissionedResolver.setText, (hex"00", legacy[i], "")), issuer);
        }
        vm.stopPrank();
        vm.prank(issuer);
        resolver.setText(dns, "rentouts.leasesCompleted", "99"); // precondition: the leftover grant works

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
        vm.prank(deployer);
        resolver.grantSetterRoles(
            abi.encodeCall(IPermissionedResolver.setText, (hex"00", "rentouts.escrow", "")), issuer
        );
        script.wireIssuerKeyRoles(resolver, issuer);

        script.revokeIssuerKeyRoles(resolver, issuer);
        script.revokeIssuerKeyRoles(resolver, issuer); // re-run: nothing left to revoke, no revert

        string[3] memory j = judged;
        string[5] memory d = derived;
        for (uint256 i; i < j.length; ++i) {
            vm.prank(issuer);
            vm.expectPartialRevert(EAC_UNAUTHORIZED);
            resolver.setText(dns, j[i], "1");
        }
        _assertIssuerCannotWrite(dns, d);
    }

    function _assertIssuerCannotWrite(bytes memory dns, string[5] memory keys) internal {
        for (uint256 i; i < keys.length; ++i) {
            assertEq(resolver.roles(uint256(keccak256(bytes(keys[i]))), issuer) & ResolverRoles.ROLE_SET_TEXT, 0);
            vm.prank(issuer);
            vm.expectPartialRevert(EAC_UNAUTHORIZED);
            resolver.setText(dns, keys[i], "99");
        }
    }
}
