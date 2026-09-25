// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RentoutsSubnames} from "../src/RentoutsSubnames.sol";
import {
    ALL_ROLES,
    Grant,
    IAddrResolver,
    IAddressResolver,
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
    uint256 constant COIN_TYPE_BASE_SEPOLIA = (1 << 31) | 84532; // ENSIP-11

    // ENS errors (contracts-v2 @ sepolia-deployment-2026-09-15)
    bytes4 constant EAC_UNAUTHORIZED = bytes4(keccak256("EACUnauthorizedAccountRoles(uint256,uint256,address)"));
    bytes4 constant TRANSFER_UNSAFE = bytes4(keccak256("TransferUnsafeUntilRegistryIsEmancipated()"));

    IETHRegistrar registrar = IETHRegistrar(EnsSepolia.ETH_REGISTRAR);
    IUniversalResolver ur = IUniversalResolver(EnsSepolia.UNIVERSAL_RESOLVER);

    IUserRegistry registry;
    IPermissionedResolver resolver;
    RentoutsSubnames subnames;

    // Unique names: well-known test addresses (e.g. makeAddr("alice")) have EIP-7702 code on Sepolia.
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

        // 3. RentoutsSubnames + role wiring (same as script/DeployEns.s.sol subnames()).
        subnames = _deploySubnames();
        subnames.setIssuer(issuer, true);
        // ENS-native, key-scoped issuer right: the issuer EOA may write this key and nothing else.
        resolver.grantSetterRoles(
            abi.encodeCall(IPermissionedResolver.setText, (hex"00", "rentouts.onTimeRate", "")), issuer
        );
        resolver.setText(subnames.parentDns(), "url", "https://rentouts.co");
        vm.stopPrank();
    }

    function _deploySubnames() internal returns (RentoutsSubnames s) {
        s = new RentoutsSubnames(registry, resolver, PARENT, deployer);
        registry.grantRootRoles(
            RegistryRoles.ROLE_REGISTRAR | RegistryRoles.ROLE_UNREGISTER | RegistryRoles.ROLE_RENEW, address(s)
        );
        resolver.grantRootRoles(
            ResolverRoles.ROLE_SET_ADDRESS | ResolverRoles.ROLE_SET_TEXT | ResolverRoles.ROLE_LINK, address(s)
        );
    }

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

    // ------------------------------------------------------------------ helpers

    function _claim(address who, string memory label) internal returns (uint256 tokenId) {
        vm.prank(who);
        tokenId = subnames.register(label, who);
    }

    function _name(string memory label) internal pure returns (string memory) {
        return string.concat(label, ".", PARENT, ".eth");
    }

    function _id(string memory label) internal pure returns (uint256) {
        return uint256(keccak256(bytes(label)));
    }

    function _addr(string memory name) internal view returns (address) {
        (bytes memory result,) = ur.resolve(_dns(name), abi.encodeCall(IAddrResolver.addr, (_namehash(name))));
        return abi.decode(result, (address));
    }

    function _addrOn(string memory name, uint256 coinType) internal view returns (bytes memory) {
        (bytes memory result,) =
            ur.resolve(_dns(name), abi.encodeCall(IAddressResolver.addr, (_namehash(name), coinType)));
        return abi.decode(result, (bytes));
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
