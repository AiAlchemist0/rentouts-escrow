// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RentoutsSubnames} from "../src/RentoutsSubnames.sol";
import {
    ALL_ROLES,
    Grant,
    IAddrResolver,
    IETHRegistrar,
    IMintableERC20,
    IPermissionedResolver,
    ITextResolver,
    IUniversalResolver,
    IUserRegistry,
    IVerifiableFactory,
    RegistryRoles,
    ResolverRoles
} from "../src/interfaces/IENSv2.sol";
import {EnsSepolia} from "../script/EnsSepolia.sol";

/// @notice Runs against the live ENSv2 Sepolia beta on a local fork: real implementations, real
///         factory, real registrar and Universal Resolver. Nothing is broadcast.
///         Run: forge test --match-path test/RentoutsSubnames.fork.t.sol -vv
contract RentoutsSubnamesForkTest is Test {
    string constant PARENT = "rentoutsforktest";
    uint64 constant YEAR = 365 days;

    IETHRegistrar registrar = IETHRegistrar(EnsSepolia.ETH_REGISTRAR);
    IUniversalResolver ur = IUniversalResolver(EnsSepolia.UNIVERSAL_RESOLVER);

    IUserRegistry registry;
    IPermissionedResolver resolver;
    RentoutsSubnames subnames;

    address deployer = makeAddr("rentouts.test.deployer");
    address issuer = makeAddr("rentouts.test.issuer");
    address alice = makeAddr("rentouts.test.alice");
    address bob = makeAddr("rentouts.test.bob");
    address mallory = makeAddr("rentouts.test.mallory");

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")));
        require(registrar.isAvailable(PARENT), "fork: parent label taken on Sepolia; pick another");

        vm.startPrank(deployer);

        // 1. Our shared PermissionedResolver + UserRegistry proxies via ENS's VerifiableFactory.
        Grant[] memory grants = new Grant[](1);
        grants[0] = Grant(deployer, ALL_ROLES);
        IVerifiableFactory factory = IVerifiableFactory(EnsSepolia.VERIFIABLE_FACTORY);
        resolver = IPermissionedResolver(
            factory.deployProxy(
                EnsSepolia.PERMISSIONED_RESOLVER_IMPL,
                uint256(keccak256("rentouts.test.resolver")),
                abi.encodeCall(IPermissionedResolver.initialize, (grants, new bytes[](0)))
            )
        );
        registry = IUserRegistry(
            factory.deployProxy(
                EnsSepolia.USER_REGISTRY_IMPL,
                uint256(keccak256("rentouts.test.registry")),
                abi.encodeCall(IUserRegistry.initialize, (grants))
            )
        );

        // 2. Register the parent with commit/reveal, pointing it at our registry + resolver.
        (uint256 base, uint256 premium) = registrar.getRegisterPrice(PARENT, YEAR, EnsSepolia.ENS_MOCK_USDC);
        IMintableERC20(EnsSepolia.ENS_MOCK_USDC).mint(deployer, base + premium);
        IMintableERC20(EnsSepolia.ENS_MOCK_USDC).approve(EnsSepolia.ETH_REGISTRAR, base + premium);
        bytes32 secret = keccak256("fork-secret");
        registrar.commit(
            registrar.makeCommitment(PARENT, deployer, secret, address(registry), address(resolver), YEAR, bytes32(0))
        );
        vm.warp(block.timestamp + registrar.MIN_COMMITMENT_AGE() + 1);
        registrar.register(
            PARENT, deployer, secret, address(registry), address(resolver), YEAR, EnsSepolia.ENS_MOCK_USDC, bytes32(0)
        );

        // 3. RentoutsSubnames + role wiring (same as script/DeployEns.s.sol).
        subnames = new RentoutsSubnames(registry, resolver, PARENT, YEAR, deployer);
        registry.grantRootRoles(
            RegistryRoles.ROLE_REGISTRAR | RegistryRoles.ROLE_UNREGISTER | RegistryRoles.ROLE_RENEW, address(subnames)
        );
        resolver.grantRootRoles(ResolverRoles.ROLE_SET_ADDRESS | ResolverRoles.ROLE_SET_TEXT, address(subnames));
        subnames.setIssuer(issuer, true);
        // ENS-native, key-scoped issuer right: the issuer EOA may write this key and nothing else.
        resolver.grantSetterRoles(
            abi.encodeCall(IPermissionedResolver.setText, (hex"00", "rentouts.onTimeRate", "")), issuer
        );
        resolver.setText(subnames.parentDns(), "url", "https://rentouts.co");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ resolution

    function test_ParentResolvesThroughUniversalResolver() public view {
        assertEq(_text(string.concat(PARENT, ".eth"), "url"), "https://rentouts.co");
    }

    function test_ClaimResolvesAddrAndCredential() public {
        uint256 tokenId = _claim(alice, "alice");
        string memory name = string.concat("alice.", PARENT, ".eth");

        assertEq(_addr(name), alice, "addr");
        assertEq(_text(name, "rentouts.credential"), "tenant/v1");
        assertEq(_text(name, "rentouts.status"), "active");
        assertEq(subnames.nameOf(alice), name);
        assertEq(subnames.labelOf(alice), "alice");
        assertEq(registry.getOwner(_id("alice")), alice);
        assertEq(registry.ownerOf(tokenId), alice);
        assertEq(registry.getResolver("alice"), address(resolver));
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
        vm.expectRevert(); // ENS: LabelAlreadyRegistered("alice")
        subnames.register("alice", bob);
    }

    function test_OnlySelfOrIssuerCanRegister() public {
        vm.prank(mallory);
        vm.expectRevert(RentoutsSubnames.NotAuthorized.selector);
        subnames.register("bob", bob);

        vm.prank(issuer);
        subnames.register("bob", bob);
        assertEq(_addr(string.concat("bob.", PARENT, ".eth")), bob);
    }

    function test_LabelValidation() public {
        string[6] memory bad = ["ab", "Alice", "-abc", "abc-", "a_bc", "abcdefghijklmnopqrstuvwxyz0123456"];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.InvalidLabel.selector, bad[i]));
            subnames.register(bad[i], alice);
        }
    }

    // ------------------------------------------------------------------ soulbound

    function test_SoulboundTransferReverts() public {
        uint256 tokenId = _claim(alice, "alice");
        vm.prank(alice);
        vm.expectRevert(); // ENS: TransferDisallowed(tokenId, alice)
        registry.safeTransferFrom(alice, bob, tokenId, 1, "");
        assertEq(registry.getOwner(_id("alice")), alice);
    }

    function test_HolderCannotDetachOrBurnCredential() public {
        _claim(alice, "alice");
        vm.startPrank(alice);
        vm.expectRevert();
        registry.setResolver(_id("alice"), mallory);
        vm.expectRevert();
        registry.unregister(_id("alice"));
        vm.stopPrank();
        assertEq(registry.getResolver("alice"), address(resolver));
    }

    // ------------------------------------------------------------------ credentials (EAC)

    function test_IssuerKeyScopedRoleIsEnforcedByENS() public {
        _claim(alice, "alice");
        bytes memory dns = subnames.dnsName("alice");
        string memory name = string.concat("alice.", PARENT, ".eth");

        vm.prank(issuer);
        resolver.setText(dns, "rentouts.onTimeRate", "100");
        assertEq(_text(name, "rentouts.onTimeRate"), "100");

        vm.prank(issuer); // same issuer, key it was not granted
        vm.expectRevert();
        resolver.setText(dns, "avatar", "https://evil.example/x.png");

        vm.prank(alice); // the holder cannot forge her own credential
        vm.expectRevert();
        resolver.setText(dns, "rentouts.onTimeRate", "100");
    }

    function test_SetCredentialViaContract() public {
        _claim(alice, "alice");
        vm.prank(issuer);
        subnames.setCredential("alice", "rentouts.leasesCompleted", "3");
        assertEq(_text(string.concat("alice.", PARENT, ".eth"), "rentouts.leasesCompleted"), "3");

        vm.prank(mallory);
        vm.expectRevert(RentoutsSubnames.NotIssuer.selector);
        subnames.setCredential("alice", "rentouts.leasesCompleted", "99");

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.NotCredentialKey.selector, "avatar"));
        subnames.setCredential("alice", "avatar", "x");

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.UnknownLabel.selector, "nobody"));
        subnames.setCredential("nobody", "rentouts.leasesCompleted", "1");
    }

    function test_ProfileTextOwnerOnlyAllowlisted() public {
        _claim(alice, "alice");
        _claim(bob, "bob");

        vm.prank(alice);
        subnames.setProfileText("alice", "description", "Tokyo renter");
        assertEq(_text(string.concat("alice.", PARENT, ".eth"), "description"), "Tokyo renter");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.ProfileKeyNotAllowed.selector, "rentouts.rating"));
        subnames.setProfileText("alice", "rentouts.rating", "5");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.NotHolder.selector, "alice"));
        subnames.setProfileText("alice", "description", "hacked");
    }

    // ------------------------------------------------------------------ revoke

    function test_RevokeBurnsClearsAndRetires() public {
        uint256 tokenId = _claim(alice, "alice");
        string memory name = string.concat("alice.", PARENT, ".eth");

        vm.prank(mallory);
        vm.expectRevert(RentoutsSubnames.NotIssuer.selector);
        subnames.revoke("alice", "nope");

        vm.prank(issuer);
        subnames.revoke("alice", "fraudulent lease");

        assertEq(registry.getOwner(_id("alice")), address(0), "token burned");
        assertEq(registry.ownerOf(tokenId), address(0));
        // Resolution now falls back to the parent's (shared) resolver, which returns the cleared records.
        assertEq(_addr(name), address(0), "addr cleared");
        assertEq(_text(name, "rentouts.status"), "revoked");
        assertEq(subnames.labelOf(alice), "");
        assertTrue(subnames.retired(_id("alice")));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.LabelRetired.selector, "alice"));
        subnames.register("alice", bob);

        _claim(alice, "alice-2"); // the person can still get a fresh credential
        assertEq(_addr(string.concat("alice-2.", PARENT, ".eth")), alice);
    }

    // ------------------------------------------------------------------ handoff §10.1: wildcard shortcut

    /// Records written on the parent's resolver for an UNREGISTERED subname: does the UR find them
    /// via the closest ancestor's resolver? (Fallback path if subname registration ever breaks.)
    function test_WildcardRecordsResolveWithoutRegistration() public {
        bytes memory dns = subnames.dnsName("ghost");
        vm.prank(deployer);
        resolver.setText(dns, "url", "https://rentouts.co/ghost");
        assertEq(_text(string.concat("ghost.", PARENT, ".eth"), "url"), "https://rentouts.co/ghost");
    }

    // ------------------------------------------------------------------ helpers

    function _claim(address who, string memory label) internal returns (uint256 tokenId) {
        vm.prank(who);
        tokenId = subnames.register(label, who);
    }

    function _id(string memory label) internal pure returns (uint256) {
        return uint256(keccak256(bytes(label)));
    }

    function _addr(string memory name) internal view returns (address) {
        (bytes memory result,) = ur.resolve(_dns(name), abi.encodeCall(IAddrResolver.addr, (_namehash(name))));
        return abi.decode(result, (address));
    }

    function _text(string memory name, string memory key) internal view returns (string memory) {
        (bytes memory result,) = ur.resolve(_dns(name), abi.encodeCall(ITextResolver.text, (_namehash(name), key)));
        return abi.decode(result, (string));
    }

    /// @dev "a.b.eth" -> \x01a\x01b\x03eth\x00
    function _dns(string memory name) internal pure returns (bytes memory out) {
        bytes memory b = bytes(name);
        uint256 start;
        for (uint256 i; i <= b.length; ++i) {
            if (i == b.length || b[i] == ".") {
                bytes memory label = new bytes(i - start);
                for (uint256 j; j < label.length; ++j) {
                    label[j] = b[start + j];
                }
                out = abi.encodePacked(out, uint8(label.length), label);
                start = i + 1;
            }
        }
        out = abi.encodePacked(out, hex"00");
    }

    function _namehash(string memory name) internal pure returns (bytes32 node) {
        bytes memory b = bytes(name);
        uint256 end = b.length;
        for (uint256 i = b.length; i > 0; --i) {
            if (b[i - 1] == ".") {
                node = keccak256(abi.encodePacked(node, _labelhash(b, i, end)));
                end = i - 1;
            }
        }
        node = keccak256(abi.encodePacked(node, _labelhash(b, 0, end)));
    }

    function _labelhash(bytes memory b, uint256 from, uint256 to) private pure returns (bytes32) {
        bytes memory label = new bytes(to - from);
        for (uint256 j; j < label.length; ++j) {
            label[j] = b[from + j];
        }
        return keccak256(label);
    }
}
