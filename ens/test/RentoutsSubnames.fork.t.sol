// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RentoutsSubnames} from "../src/RentoutsSubnames.sol";
import {ITextResolver, RegistryRoles, ResolverRoles} from "../src/interfaces/IENSv2.sol";
import {EnsForkBase} from "./EnsForkBase.sol";

/// @notice Runs against the live ENSv2 Sepolia beta on a local fork: real implementations, real
///         factory, real registrar and Universal Resolver. Nothing is broadcast. Setup: EnsForkBase.
///         Run: forge test --match-path test/RentoutsSubnames.fork.t.sol -vv
contract RentoutsSubnamesForkTest is EnsForkBase {
    uint256 constant COIN_TYPE_BASE_SEPOLIA = (1 << 31) | 84532; // ENSIP-11

    // ENS errors (contracts-v2 @ sepolia-deployment-2026-09-15)
    bytes4 constant TRANSFER_UNSAFE = bytes4(keccak256("TransferUnsafeUntilRegistryIsEmancipated()"));

    // ------------------------------------------------------------------ resolution

    function test_ParentResolvesThroughUniversalResolver() public view {
        assertEq(_text(string.concat(PARENT, ".eth"), "url"), "https://rentouts.co");
    }

    function test_ClaimResolvesAddrAndCredential() public {
        uint256 tokenId = _claim(alice, "alice");
        string memory name = _name("alice");

        assertEq(_addr(name), alice, "addr (coin 60)");
        assertEq(_addrOn(name, COIN_TYPE_BASE_SEPOLIA), abi.encodePacked(alice), "addr on Base Sepolia (ENSIP-19 default)");
        assertEq(_text(name, "rentouts.credential"), "tenant/v1");
        assertEq(_text(name, "rentouts.status"), "active");
        assertEq(subnames.nameOf(alice), name);
        assertEq(subnames.labelOf(alice), "alice");
        assertEq(registry.getOwner(_id("alice")), alice);
        assertEq(registry.ownerOf(tokenId), alice);
        assertEq(registry.getResolver("alice"), address(resolver));
    }

    function test_CredentialNeverExpires() public {
        _claim(alice, "alice");
        assertEq(registry.getExpiry(_id("alice")), type(uint64).max);
        // Past the parent's own 1-year expiry the UR stops resolving the whole subtree (the intended
        // bound), but the credential itself never lapses: it is still owned and still revocable.
        vm.warp(block.timestamp + 10 * YEAR);
        assertEq(registry.getOwner(_id("alice")), alice);
        vm.prank(issuer);
        subnames.revoke("alice", "still revocable later");
        bytes memory status = resolver.resolve(
            subnames.dnsName("alice"), abi.encodeCall(ITextResolver.text, (bytes32(0), "rentouts.status"))
        );
        assertEq(abi.decode(status, (string)), "revoked");
    }

    // ------------------------------------------------------------------ claim rules

    function test_OneNamePerHolder() public {
        _claim(alice, "alice");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.AlreadyHasName.selector, alice));
        subnames.register("alice2", alice);
    }

    function test_DuplicateLabelReverts() public {
        _claim(alice, "alice");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.LabelTaken.selector, "alice"));
        subnames.register("alice", bob);
    }

    function test_OnlySelfOrIssuerCanRegister() public {
        vm.prank(mallory);
        vm.expectRevert(RentoutsSubnames.NotAuthorized.selector);
        subnames.register("bob", bob);

        vm.prank(issuer);
        subnames.register("bob", bob);
        assertEq(_addr(_name("bob")), bob);
    }

    function test_LabelValidation() public {
        string[8] memory bad =
            ["ab", "Alice", "-abc", "abc-", "a_bc", "abcdefghijklmnopqrstuvwxyz0123456", "ab--cd", "xn--abc"];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.InvalidLabel.selector, bad[i]));
            subnames.register(bad[i], alice);
        }
        // Accepted edge cases (all ENSIP-15 normalized).
        string[4] memory good = ["a-b", "abc--d", "123", "abcdefghijklmnopqrstuvwxyz012345"];
        for (uint256 i; i < good.length; ++i) {
            address who = makeAddr(string.concat("rentouts.test.good.", good[i]));
            vm.prank(who);
            subnames.register(good[i], who);
            assertEq(_addr(_name(good[i])), who);
        }
    }

    // ------------------------------------------------------------------ soulbound

    function test_SoulboundTransferReverts() public {
        uint256 tokenId = _claim(alice, "alice");
        assertFalse(registry.isEmancipated(), "registry root keeps UNREGISTER => revocable");

        // The real soulbound gate: no ROLE_CAN_TRANSFER_ADMIN on the token.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("TransferDisallowed(uint256,address)", tokenId, alice));
        registry.unsafeTransfer(bob, tokenId, "");

        // ERC-1155 safe transfers are refused outright while the registry is not emancipated.
        vm.prank(alice);
        vm.expectRevert(TRANSFER_UNSAFE);
        registry.safeTransferFrom(alice, bob, tokenId, 1, "");

        assertEq(registry.getOwner(_id("alice")), alice);
    }

    /// Positive control: the same registry DOES move a token that was granted ROLE_CAN_TRANSFER_ADMIN,
    /// so test_SoulboundTransferReverts would fail if RentoutsSubnames ever granted it.
    function test_TransferableControlProvesTheGate() public {
        vm.prank(deployer);
        uint256 tokenId = registry.register(
            "movable", alice, address(0), address(resolver), RegistryRoles.ROLE_CAN_TRANSFER_ADMIN, type(uint64).max
        );
        vm.prank(alice);
        registry.unsafeTransfer(bob, tokenId, "");
        assertEq(registry.getOwner(_id("movable")), bob);
    }

    function test_HolderCannotDetachOrBurnCredential() public {
        _claim(alice, "alice");
        vm.startPrank(alice);
        vm.expectPartialRevert(EAC_UNAUTHORIZED);
        registry.setResolver(_id("alice"), mallory);
        vm.expectPartialRevert(EAC_UNAUTHORIZED);
        registry.unregister(_id("alice"));
        vm.stopPrank();
        assertEq(registry.getResolver("alice"), address(resolver));
    }

    // ------------------------------------------------------------------ credentials (EAC)

    function test_IssuerKeyScopedRoleIsEnforcedByENS() public {
        _claim(alice, "alice");
        bytes memory dns = subnames.dnsName("alice");

        vm.prank(issuer);
        resolver.setText(dns, "rentouts.onTimeRate", "100");
        assertEq(_text(_name("alice"), "rentouts.onTimeRate"), "100");

        vm.prank(issuer); // same issuer, key it was not granted
        vm.expectPartialRevert(EAC_UNAUTHORIZED);
        resolver.setText(dns, "avatar", "https://evil.example/x.png");

        vm.prank(alice); // the holder cannot forge her own credential
        vm.expectPartialRevert(EAC_UNAUTHORIZED);
        resolver.setText(dns, "rentouts.onTimeRate", "100");
    }

    function test_RemovingIssuerRevokesResolverRole() public {
        _claim(alice, "alice");
        bytes memory dns = subnames.dnsName("alice");
        vm.startPrank(deployer); // what script phase removeIssuer() does
        subnames.setIssuer(issuer, false);
        resolver.revokeRoles(uint256(keccak256("rentouts.onTimeRate")), ResolverRoles.ROLE_SET_TEXT, issuer);
        vm.stopPrank();

        vm.prank(issuer);
        vm.expectPartialRevert(EAC_UNAUTHORIZED);
        resolver.setText(dns, "rentouts.onTimeRate", "0");
        vm.prank(issuer);
        vm.expectRevert(RentoutsSubnames.NotIssuer.selector);
        subnames.setCredential("alice", "rentouts.onTimeRate", "0");
    }

    function test_SetCredentialViaContract() public {
        _claim(alice, "alice");
        vm.prank(issuer);
        subnames.setCredential("alice", "rentouts.leasesCompleted", "3");
        assertEq(_text(_name("alice"), "rentouts.leasesCompleted"), "3");

        vm.prank(mallory);
        vm.expectRevert(RentoutsSubnames.NotIssuer.selector);
        subnames.setCredential("alice", "rentouts.leasesCompleted", "99");

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.NotCredentialKey.selector, "avatar"));
        subnames.setCredential("alice", "avatar", "x");

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.NotCredentialKey.selector, "rentouts."));
        subnames.setCredential("alice", "rentouts.", "x");

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.UnknownLabel.selector, "nobody"));
        subnames.setCredential("nobody", "rentouts.leasesCompleted", "1");
    }

    function test_ProfileTextOwnerOnlyAllowlisted() public {
        _claim(alice, "alice");
        _claim(bob, "bob");

        vm.prank(alice);
        subnames.setProfileText("alice", "description", "Tokyo renter");
        assertEq(_text(_name("alice"), "description"), "Tokyo renter");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.ProfileKeyNotAllowed.selector, "rentouts.rating"));
        subnames.setProfileText("alice", "rentouts.rating", "5");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.NotHolder.selector, "alice"));
        subnames.setProfileText("alice", "description", "hacked");
    }

    // ------------------------------------------------------------------ revoke

    function test_RevokeWipesRecordsBurnsAndRetires() public {
        uint256 tokenId = _claim(alice, "alice");
        string memory name = _name("alice");
        vm.prank(issuer);
        subnames.setCredential("alice", "rentouts.leasesCompleted", "3");
        bytes memory dns = subnames.dnsName("alice"); // compute before vm.prank (prank hits the next call)
        vm.prank(issuer);
        resolver.setText(dns, "rentouts.onTimeRate", "100");
        vm.prank(alice);
        subnames.setProfileText("alice", "description", "Tokyo renter");

        vm.prank(mallory);
        vm.expectRevert(RentoutsSubnames.NotIssuer.selector);
        subnames.revoke("alice", "nope");

        vm.prank(issuer);
        subnames.revoke("alice", "fraudulent lease");

        assertEq(registry.getOwner(_id("alice")), address(0), "token burned");
        assertEq(registry.ownerOf(tokenId), address(0));
        // Resolution now falls back to the parent's (shared) resolver: every old record must be gone.
        assertEq(_addr(name), address(0), "addr wiped");
        assertEq(_addrOn(name, COIN_TYPE_BASE_SEPOLIA).length, 0, "base addr wiped");
        assertEq(_text(name, "rentouts.status"), "revoked");
        assertEq(_text(name, "rentouts.credential"), "", "credential wiped");
        assertEq(_text(name, "rentouts.leasesCompleted"), "", "contract-written stat wiped");
        assertEq(_text(name, "rentouts.onTimeRate"), "", "issuer-written stat wiped");
        assertEq(_text(name, "description"), "", "profile wiped");
        // The parent's own records are untouched.
        assertEq(_text(string.concat(PARENT, ".eth"), "url"), "https://rentouts.co");
        assertEq(subnames.labelOf(alice), "");
        assertTrue(subnames.retired(_id("alice")));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.LabelRetired.selector, "alice"));
        subnames.register("alice", bob);

        _claim(alice, "alice-2"); // the person can still get a fresh credential
        assertEq(_addr(_name("alice-2")), alice);
    }

    /// A redeployed RentoutsSubnames on the same registry can't see the old `retired` map, but must
    /// still refuse labels the previous deployment revoked (they'd inherit nothing, but it's single-use).
    function test_RevokedLabelBlockedAcrossRedeploy() public {
        _claim(alice, "alice");
        vm.prank(issuer);
        subnames.revoke("alice", "fraud");

        vm.startPrank(deployer);
        RentoutsSubnames v2 = _deploySubnames();
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.LabelTaken.selector, "alice"));
        v2.register("alice", bob);
    }

    // ------------------------------------------------------------------ admin

    function test_AdminFunctions() public {
        vm.prank(mallory);
        vm.expectRevert(RentoutsSubnames.NotAdmin.selector);
        subnames.setIssuer(mallory, true);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.NotCredentialKey.selector, "rentouts.rating"));
        subnames.setProfileKey("rentouts.rating", true);

        vm.prank(deployer);
        subnames.transferAdmin(bob);
        assertEq(subnames.admin(), bob);
        vm.prank(deployer);
        vm.expectRevert(RentoutsSubnames.NotAdmin.selector);
        subnames.setIssuer(deployer, false);
    }

    // ------------------------------------------------------------------ handoff §10.1: wildcard shortcut

    /// Records written on the parent's resolver for an UNREGISTERED subname: does the UR find them
    /// via the closest ancestor's resolver? (Fallback path if subname registration ever breaks.)
    function test_WildcardRecordsResolveWithoutRegistration() public {
        bytes memory dns = subnames.dnsName("ghost");
        vm.prank(deployer);
        resolver.setText(dns, "url", "https://rentouts.co/ghost");
        assertEq(_text(_name("ghost"), "url"), "https://rentouts.co/ghost");
    }
}
