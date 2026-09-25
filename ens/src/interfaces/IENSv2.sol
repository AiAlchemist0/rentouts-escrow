// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Minimal interfaces for the ENSv2 Sepolia beta, written against
// ensdomains/contracts-v2 @ tag `sepolia-deployment-2026-09-15` (commit f2f0a05).
// We only need to call ENS's deployed implementations, so we vendor the
// signatures we use instead of compiling the whole contracts-v2 tree.

/// @dev `IEACGrantInitializable.Grant`: roles granted on ROOT_RESOURCE at init.
struct Grant {
    address account;
    uint256 roleBitmap;
}

/// @dev `contracts/src/registry/libraries/RegistryRolesLib.sol`
library RegistryRoles {
    uint256 internal constant ROLE_REGISTRAR = 1 << 0;
    uint256 internal constant ROLE_UNREGISTER = 1 << 12;
    uint256 internal constant ROLE_RENEW = 1 << 16;
    uint256 internal constant ROLE_SET_SUBREGISTRY = 1 << 20;
    uint256 internal constant ROLE_SET_RESOLVER = 1 << 24;
    uint256 internal constant ROLE_CAN_TRANSFER_ADMIN = (1 << 28) << 128;
    uint256 internal constant ROLE_UPGRADE = 1 << 124;
}

/// @dev `contracts/src/resolver/libraries/PermissionedResolverLib.sol`
library ResolverRoles {
    uint256 internal constant ROLE_SET_ADDRESS = 1 << 0;
    uint256 internal constant ROLE_SET_TEXT = 1 << 4;
    uint256 internal constant ROLE_SET_CONTENTHASH = 1 << 8;
    uint256 internal constant ROLE_SET_DATA = 1 << 24;
    uint256 internal constant ROLE_UPGRADE = 1 << 124;
}

/// @dev `EACBaseRolesLib.ALL_ROLES`: bit 0 of every nybble (roles and their admins).
uint256 constant ALL_ROLES = 0x1111111111111111111111111111111111111111111111111111111111111111;

/// @dev `ensdomains/verifiable-factory` @ 5ef7b1a: CREATE2 salt = keccak256(abi.encode(msg.sender, salt)).
interface IVerifiableFactory {
    event ProxyDeployed(address indexed sender, address indexed proxyAddress, uint256 salt, address implementation);

    function deployProxy(address implementation, uint256 salt, bytes memory data) external returns (address proxy);
}

/// @dev Subset of `PermissionedRegistry` + `UserRegistry` (ERC1155Singleton + EnhancedAccessControl).
interface IUserRegistry {
    function initialize(Grant[] calldata grants) external;

    function register(
        string memory label,
        address owner,
        address registry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    ) external returns (uint256 tokenId);

    function unregister(uint256 anyId) external;
    function setSubregistry(uint256 anyId, address registry) external;
    function setResolver(uint256 anyId, address resolver) external;
    function grantRootRoles(uint256 roleBitmap, address account) external returns (bool);
    function hasRootRoles(uint256 roleBitmap, address account) external view returns (bool);
    function roles(uint256 anyId, address account) external view returns (uint256);

    function getOwner(uint256 anyId) external view returns (address);
    function getExpiry(uint256 anyId) external view returns (uint64);
    function getTokenId(uint256 anyId) external view returns (uint256);
    function getResolver(string calldata label) external view returns (address);
    function getSubregistry(string calldata label) external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function isEmancipated() external view returns (bool);

    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data)
        external;
}

/// @dev Subset of `PermissionedResolver`. Setters take the DNS-encoded name, not a namehash.
interface IPermissionedResolver {
    function initialize(Grant[] calldata grants, bytes[] calldata calls) external;

    function setText(bytes calldata name, string calldata key, string calldata value) external;
    function setAddress(bytes calldata name, uint256 coinType, bytes calldata addressBytes) external;
    function setData(bytes calldata name, string calldata key, bytes calldata value) external;

    /// @dev e.g. setter = abi.encodeCall(setText, (hex"00", key, "")) grants ROLE_SET_TEXT for `key` only.
    function grantSetterRoles(bytes calldata setter, address account) external returns (bool);
    function grantRootRoles(uint256 roleBitmap, address account) external returns (bool);
    function hasRootRoles(uint256 roleBitmap, address account) external view returns (bool);

    /// @dev ENSIP-10 extended resolution (name-based; falls back to the default record).
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory);
}

/// @dev Subset of `ETHRegistrar` (commit/reveal, pays in an accepted ERC-20).
interface IETHRegistrar {
    function MIN_COMMITMENT_AGE() external view returns (uint256);
    function MAX_COMMITMENT_AGE() external view returns (uint256);
    function isAvailable(string calldata label) external view returns (bool);
    function getRegisterPrice(string calldata label, uint64 duration, address paymentToken)
        external
        view
        returns (uint256 base, uint256 premium);

    function makeCommitment(
        string calldata label,
        address owner,
        bytes32 secret,
        address subregistry,
        address resolver,
        uint64 duration,
        bytes32 referrer
    ) external pure returns (bytes32);

    function commit(bytes32 commitment) external;

    function register(
        string calldata label,
        address owner,
        bytes32 secret,
        address subregistry,
        address resolver,
        uint64 duration,
        address paymentToken,
        bytes32 referrer
    ) external returns (uint256 tokenId);
}

/// @dev ENSv2 UniversalResolver (proxy 0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe on Sepolia).
interface IUniversalResolver {
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory, address);
    function findResolver(bytes calldata name) external view returns (address, bytes32, uint256);
}

interface IAddrResolver {
    function addr(bytes32 node) external view returns (address payable);
}

interface ITextResolver {
    function text(bytes32 node, string calldata key) external view returns (string memory);
}

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
