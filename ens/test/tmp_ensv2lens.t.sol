// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// TEMPORARY review test. Delete before returning.
import {RentoutsSubnamesForkTest} from "./RentoutsSubnames.fork.t.sol";
import {RentoutsSubnames} from "../src/RentoutsSubnames.sol";
import {IPermissionedResolver, IUserRegistry, RegistryRoles, ResolverRoles} from "../src/interfaces/IENSv2.sol";

interface IUnsafeT {
    function unsafeTransfer(address to, uint256 tokenId, bytes calldata data) external;
}

interface IAddressResolverT {
    function addr(bytes32 node, uint256 coinType) external view returns (bytes memory);
}

interface IURT {
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory, address);
}

contract TmpEnsv2LensTest is RentoutsSubnamesForkTest {
    // A) safeTransferFrom reverts for a reason unrelated to soulbound; the fork test is vacuous.
    function test_tmp_SafeTransferRevertReason() public {
        uint256 tokenId = _claim(alice, "alice");
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("TransferUnsafeUntilRegistryIsEmancipated()")));
        registry.safeTransferFrom(alice, bob, tokenId, 1, "");

        // A TRANSFERABLE token (ROLE_CAN_TRANSFER_ADMIN granted) also reverts on safeTransferFrom.
        address carol = makeAddr("carol");
        vm.prank(deployer);
        uint256 carolTok = registry.register(
            "carol", carol, address(0), address(resolver), RegistryRoles.ROLE_CAN_TRANSFER_ADMIN, uint64(block.timestamp + 30 days)
        );
        vm.prank(carol);
        vm.expectRevert(bytes4(keccak256("TransferUnsafeUntilRegistryIsEmancipated()")));
        registry.safeTransferFrom(carol, bob, carolTok, 1, "");
        // ...but it moves with unsafeTransfer
        vm.prank(carol);
        IUnsafeT(address(registry)).unsafeTransfer(bob, carolTok, "");
        assertEq(registry.getOwner(_id("carol")), bob);

        // Our roleBitmap-0 token: unsafeTransfer is where TransferDisallowed actually fires.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("TransferDisallowed(uint256,address)", tokenId, alice));
        IUnsafeT(address(registry)).unsafeTransfer(bob, tokenId, "");
    }

    // B) Subname expiry: credential keeps resolving as active, revoke bricks, label can be taken over.
    function test_tmp_ExpiryBreaksRevokeAndRetire() public {
        vm.startPrank(deployer);
        RentoutsSubnames short = new RentoutsSubnames(registry, resolver, PARENT, 30 days, deployer);
        registry.grantRootRoles(
            RegistryRoles.ROLE_REGISTRAR | RegistryRoles.ROLE_UNREGISTER | RegistryRoles.ROLE_RENEW, address(short)
        );
        resolver.grantRootRoles(ResolverRoles.ROLE_SET_ADDRESS | ResolverRoles.ROLE_SET_TEXT, address(short));
        short.setIssuer(issuer, true);
        vm.stopPrank();

        vm.prank(alice);
        uint256 tokenId = short.register("alice", alice);
        vm.prank(issuer);
        short.setCredential("alice", "rentouts.leasesCompleted", "3");
        string memory name = string.concat("alice.", PARENT, ".eth");

        vm.warp(block.timestamp + 31 days);
        assertEq(registry.getOwner(_id("alice")), address(0), "expired in registry");
        assertEq(registry.getResolver("alice"), address(0), "leaf resolver hidden");
        // UR falls back to the parent's resolver == the same shared resolver
        assertEq(_addr(name), alice, "expired name still resolves addr");
        assertEq(_text(name, "rentouts.status"), "active", "expired name still active");

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSignature("LabelExpired(uint256)", tokenId));
        short.revoke("alice", "fraud");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.AlreadyHasName.selector, alice));
        short.register("alice-new", alice);

        vm.prank(bob);
        short.register("alice", bob); // takeover of the expired label
        assertEq(short.holderOf(_id("alice")), bob);
        assertEq(short.labelOf(alice), "alice", "stale mapping for alice");
        assertEq(short.nameOf(alice), name, "alice's nameOf now points to bob's name");
        assertEq(_addr(name), bob);
        assertEq(_text(name, "rentouts.leasesCompleted"), "3", "bob inherits alice's credential");
    }

    // C) revoke leaves the credential marker and issuer-written keys resolvable through the UR.
    function test_tmp_RevokeLeavesCredentials() public {
        _claim(alice, "alice");
        vm.prank(issuer);
        subnames.setCredential("alice", "rentouts.leasesCompleted", "3");
        bytes memory dnsA = subnames.dnsName("alice");
        vm.prank(issuer);
        resolver.setText(dnsA, "rentouts.onTimeRate", "100");
        vm.prank(issuer);
        subnames.revoke("alice", "fraud");
        string memory name = string.concat("alice.", PARENT, ".eth");
        assertEq(_text(name, "rentouts.credential"), "tenant/v1");
        assertEq(_text(name, "rentouts.leasesCompleted"), "3");
        assertEq(_text(name, "rentouts.onTimeRate"), "100");
    }

    // D) setIssuer(false) does not remove ENS-native key-scoped resolver rights.
    function test_tmp_RemovedIssuerStillWrites() public {
        _claim(alice, "alice");
        vm.prank(deployer);
        subnames.setIssuer(issuer, false);
        vm.prank(issuer);
        vm.expectRevert(RentoutsSubnames.NotIssuer.selector);
        subnames.setCredential("alice", "rentouts.onTimeRate", "0");
        bytes memory dnsA = subnames.dnsName("alice");
        vm.prank(issuer);
        resolver.setText(dnsA, "rentouts.onTimeRate", "0");
        assertEq(_text(string.concat("alice.", PARENT, ".eth"), "rentouts.onTimeRate"), "0");
    }

    // E) issuer == deployer (DeployEns default) defeats the key-scoped showcase.
    function test_tmp_DeployerAsIssuerCanWriteAnyKey() public {
        _claim(alice, "alice");
        bytes memory dnsA = subnames.dnsName("alice");
        vm.prank(deployer);
        resolver.setText(dnsA, "avatar", "https://evil.example/x.png");
        assertEq(_text(string.concat("alice.", PARENT, ".eth"), "avatar"), "https://evil.example/x.png");
    }

    // F) non-ENSIP-15 label accepted
    function test_tmp_LabelExtensionAccepted() public {
        vm.prank(alice);
        subnames.register("ab--cd", alice);
        assertEq(subnames.labelOf(alice), "ab--cd");
    }

    // G) ENSIP-19 chain-specific coin type (Base Sepolia) is empty
    function test_tmp_BaseCoinTypeEmpty() public {
        _claim(alice, "alice");
        string memory name = string.concat("alice.", PARENT, ".eth");
        uint256 baseSepoliaCoin = 0x80000000 | 84532;
        (bytes memory r,) = IURT(address(ur)).resolve(
            _dns(name), abi.encodeCall(IAddressResolverT.addr, (_namehash(name), baseSepoliaCoin))
        );
        assertEq(abi.decode(r, (bytes)).length, 0, "no address for Base Sepolia coin type");
        (r,) = IURT(address(ur)).resolve(_dns(name), abi.encodeCall(IAddressResolverT.addr, (_namehash(name), 60)));
        assertEq(abi.decode(r, (bytes)).length, 20);
    }
}
