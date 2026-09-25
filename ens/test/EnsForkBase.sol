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

/// @notice Shared fork setup against the live ENSv2 Sepolia beta: real implementations, real
///         factory, real registrar and Universal Resolver. Nothing is broadcast.
///         Fresh resolver/registry proxies, the parent registered with commit/reveal, and
///         RentoutsSubnames wired the same way script/DeployEns.s.sol subnames() does it.
abstract contract EnsForkBase is Test {
    string constant PARENT = "rentoutsforktest";
    uint64 constant YEAR = 365 days;

    // ENS errors (contracts-v2 @ sepolia-deployment-2026-09-15)
    bytes4 constant EAC_UNAUTHORIZED = bytes4(keccak256("EACUnauthorizedAccountRoles(uint256,uint256,address)"));

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

    function setUp() public virtual {
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
