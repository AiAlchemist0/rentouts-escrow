// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {RentoutsSubnames} from "../src/RentoutsSubnames.sol";
import {CredentialSync} from "../src/CredentialSync.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
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
import {EnsSepolia} from "./EnsSepolia.sol";

/// @notice Phased, re-runnable ENSv2 setup for RentOuts on Ethereum Sepolia.
///         Run through scripts/ens.sh, which passes --sig "<phase>()" and the keystore account.
///
///         Phases (each safe to re-run; each skips what is already done):
///           status()   read-only report (default)
///           infra()    PermissionedResolver + UserRegistry proxies via ENS VerifiableFactory
///           commit()   commit/reveal step 1 for <ENS_PARENT_LABEL>.eth (writes a gitignored secret)
///           register() step 2, >= MIN_COMMITMENT_AGE later: pays + registers the parent
///           subnames() deploys RentoutsSubnames and wires registry/resolver roles + issuer; the issuer
///                      EOA gets key roles on the issuer-judged keys only (escrow-derived ones revoked)
///           profile()  parent records (addr, url, email, com.twitter, description) from env
///           claim()    issuer mints <ENS_DEMO_LABEL>.<parent> to ENS_DEMO_HOLDER (the go/no-go gate)
///           removeIssuer() disables ENS_REMOVE_ISSUER on the contract AND revokes its resolver key roles
///           credentialSync() deploys CredentialSync(ESCROW_ADDRESS, subnames) and makes it an issuer
///           sync()     calls CredentialSync.sync(ENS_SYNC_TENANT) (permissionless; for the demo)
///
///         State lives in ens/deployments/sepolia.json and is only written when BROADCAST=true,
///         so dry runs never record addresses that don't exist.
contract DeployEns is Script {
    using stdJson for string;

    uint64 constant YEAR = 365 days;

    IETHRegistrar constant REGISTRAR = IETHRegistrar(EnsSepolia.ETH_REGISTRAR);
    IUserRegistry constant ETH_REGISTRY = IUserRegistry(EnsSepolia.ETH_REGISTRY);
    IUniversalResolver constant UR = IUniversalResolver(EnsSepolia.UNIVERSAL_RESOLVER);

    // Issuer-judged keys the issuer EOA may write directly on the resolver (ENS-enforced, key-scoped).
    string[3] ISSUER_KEYS = ["rentouts.onTimeRate", "rentouts.rating", "rentouts.verified"];
    // Escrow-derived keys (CredentialSync). The issuer EOA must hold no resolver role on these. The
    // first deploy granted it leasesCompleted, disputes and escrow; subnames() revokes such grants.
    string[5] DERIVED_KEYS = [
        "rentouts.leasesCompleted",
        "rentouts.disputes",
        "rentouts.rentPaid",
        "rentouts.depositReturnRate",
        "rentouts.escrow"
    ];

    string label;
    bool broadcasting;
    address me;

    function _init() internal {
        require(block.chainid == EnsSepolia.CHAIN_ID, "not Ethereum Sepolia");
        label = vm.envString("ENS_PARENT_LABEL");
        broadcasting = vm.envOr("BROADCAST", false);
        me = msg.sender;
        require(me != address(0) && me != DEFAULT_SENDER, "pass --sender <your keystore address>");
    }

    // ------------------------------------------------------------------------------------ phases

    function run() external {
        status();
    }

    function status() public {
        _init();
        uint256 labelId = uint256(keccak256(bytes(label)));
        console2.log("parent            :", string.concat(label, ".eth"));
        console2.log("sender            :", me);
        console2.log("ENS deployment    :", EnsSepolia.DEPLOYMENT_TAG);
        console2.log("parent available  :", REGISTRAR.isAvailable(label));
        console2.log("parent owner      :", ETH_REGISTRY.getOwner(labelId));
        console2.log("parent subregistry:", ETH_REGISTRY.getSubregistry(label));
        console2.log("parent resolver   :", ETH_REGISTRY.getResolver(label));
        console2.log("state resolver    :", _get("permissionedResolver"));
        console2.log("state registry    :", _get("userRegistry"));
        console2.log("state subnames    :", _get("rentoutsSubnames"));
        console2.log("state issuer      :", _get("issuer"));
        console2.log("state credSync    :", _get("credentialSync"));
        console2.log("state escrow      :", _get("escrow"));
        if (ETH_REGISTRY.getResolver(label) != address(0)) {
            console2.log("UR text(url)      :", _urText(string.concat(label, ".eth"), "url"));
        }
        string memory demo = vm.envOr("ENS_DEMO_LABEL", string(""));
        if (bytes(demo).length != 0 && _get("rentoutsSubnames") != address(0)) {
            string memory name = string.concat(demo, ".", label, ".eth");
            console2.log("demo name         :", name);
            console2.log("UR addr           :", _urAddr(name));
            console2.log("UR credential     :", _urText(name, "rentouts.credential"));
            console2.log("UR status         :", _urText(name, "rentouts.status"));
            if (_get("credentialSync") != address(0)) _logSynced(name);
        }
    }

    function infra() external {
        _init();
        IVerifiableFactory factory = IVerifiableFactory(EnsSepolia.VERIFIABLE_FACTORY);
        uint256 version = vm.envOr("ENS_SALT_VERSION", uint256(1));
        Grant[] memory grants = new Grant[](1);
        grants[0] = Grant(me, ALL_ROLES);

        address resolver = _get("permissionedResolver");
        address registry = _get("userRegistry");
        vm.startBroadcast(me);
        if (resolver.code.length == 0) {
            resolver = factory.deployProxy(
                EnsSepolia.PERMISSIONED_RESOLVER_IMPL,
                uint256(keccak256(abi.encode("rentouts.resolver", label, version))),
                abi.encodeCall(IPermissionedResolver.initialize, (grants, new bytes[](0)))
            );
            console2.log("deployed PermissionedResolver proxy:", resolver);
        } else {
            console2.log("PermissionedResolver exists:", resolver);
        }
        if (registry.code.length == 0) {
            registry = factory.deployProxy(
                EnsSepolia.USER_REGISTRY_IMPL,
                uint256(keccak256(abi.encode("rentouts.registry", label, version))),
                abi.encodeCall(IUserRegistry.initialize, (grants))
            );
            console2.log("deployed UserRegistry proxy:", registry);
        } else {
            console2.log("UserRegistry exists:", registry);
        }
        vm.stopBroadcast();
        _save(resolver, registry, _get("rentoutsSubnames"), _get("issuer"));
    }

    function commit() external {
        _init();
        if (_parentIsMine()) {
            console2.log("parent already registered to sender; nothing to commit");
            return;
        }
        require(REGISTRAR.isAvailable(label), "parent label is taken: choose another ENS_PARENT_LABEL");
        (address resolver, address registry) = _requireInfra();

        bytes32 secret = keccak256(abi.encode(vm.randomUint(), label, me, block.timestamp));
        bytes32 commitment = REGISTRAR.makeCommitment(
            label, me, secret, registry, resolver, _duration(), bytes32(0)
        );
        vm.startBroadcast(me);
        REGISTRAR.commit(commitment);
        vm.stopBroadcast();

        if (broadcasting) {
            string memory o = "commit";
            o.serialize("secret", secret);
            o.serialize("commitment", commitment);
            string memory json = o.serialize("committedAt", block.timestamp);
            vm.writeJson(json, _commitFile());
        }
        console2.log("committed; wait >= seconds before register():", REGISTRAR.MIN_COMMITMENT_AGE());
    }

    function register() external {
        _init();
        if (_parentIsMine()) {
            console2.log("parent already registered to sender");
            return;
        }
        (address resolver, address registry) = _requireInfra();
        string memory c = vm.readFile(_commitFile());
        bytes32 secret = c.readBytes32(".secret");
        uint256 committedAt = c.readUint(".committedAt");
        require(block.timestamp >= committedAt + REGISTRAR.MIN_COMMITMENT_AGE(), "commitment too young; wait");
        require(block.timestamp <= committedAt + REGISTRAR.MAX_COMMITMENT_AGE(), "commitment expired; re-run commit()");

        address token = vm.envOr("ENS_PAYMENT_TOKEN", EnsSepolia.ENS_MOCK_USDC);
        (uint256 base, uint256 premium) = REGISTRAR.getRegisterPrice(label, _duration(), token);
        uint256 price = base + premium;
        console2.log("price (token units):", price);

        vm.startBroadcast(me);
        if (token == EnsSepolia.ENS_MOCK_USDC && IMintableERC20(token).balanceOf(me) < price) {
            IMintableERC20(token).mint(me, price); // ENS test token; spend it in the same run
        }
        IMintableERC20(token).approve(address(REGISTRAR), price);
        REGISTRAR.register(label, me, secret, registry, resolver, _duration(), token, bytes32(0));
        vm.stopBroadcast();
        console2.log("registered:", string.concat(label, ".eth"));
    }

    function subnames() external {
        _init();
        (address resolverAddr, address registryAddr) = _requireInfra();
        require(_parentIsMine(), "register the parent first");
        IPermissionedResolver resolver = IPermissionedResolver(resolverAddr);
        IUserRegistry registry = IUserRegistry(registryAddr);
        // The issuer must NOT hold root SET_TEXT on the resolver, otherwise ENS can't demonstrate the
        // key-scoped limit (issuer writes rentouts.onTimeRate, reverts on avatar). Use a second account.
        address issuer = vm.envAddress("ENS_ISSUER");
        require(
            !resolver.hasRootRoles(ResolverRoles.ROLE_SET_TEXT, issuer),
            "ENS_ISSUER holds root SET_TEXT (is it the deployer?): use a separate issuer account"
        );

        RentoutsSubnames sub = RentoutsSubnames(_get("rentoutsSubnames"));
        vm.startBroadcast(me);
        if (address(sub).code.length == 0) {
            sub = new RentoutsSubnames(registry, resolver, label, me);
            console2.log("deployed RentoutsSubnames:", address(sub));
        }
        uint256 regRoles = RegistryRoles.ROLE_REGISTRAR | RegistryRoles.ROLE_UNREGISTER | RegistryRoles.ROLE_RENEW;
        if (!registry.hasRootRoles(regRoles, address(sub))) registry.grantRootRoles(regRoles, address(sub));
        uint256 resRoles = ResolverRoles.ROLE_SET_ADDRESS | ResolverRoles.ROLE_SET_TEXT | ResolverRoles.ROLE_LINK;
        if (!resolver.hasRootRoles(resRoles, address(sub))) resolver.grantRootRoles(resRoles, address(sub));
        if (!sub.isIssuer(issuer)) sub.setIssuer(issuer, true);
        _wireIssuerKeyRoles(resolver, issuer);
        vm.stopBroadcast();
        _save(resolverAddr, registryAddr, address(sub), issuer);
    }

    function profile() external {
        _init();
        (address resolverAddr,) = _requireInfra();
        IPermissionedResolver resolver = IPermissionedResolver(resolverAddr);
        bytes memory dns = abi.encodePacked(uint8(bytes(label).length), label, hex"03", "eth", hex"00");

        vm.startBroadcast(me);
        address a = vm.envOr("ENS_PROFILE_ADDR", address(0));
        if (a != address(0)) resolver.setAddress(dns, 60, abi.encodePacked(a));
        _maybeText(resolver, dns, "url", "ENS_PROFILE_URL");
        _maybeText(resolver, dns, "email", "ENS_PROFILE_EMAIL");
        _maybeText(resolver, dns, "com.twitter", "ENS_PROFILE_TWITTER");
        _maybeText(resolver, dns, "description", "ENS_PROFILE_DESCRIPTION");
        _maybeText(resolver, dns, "avatar", "ENS_PROFILE_AVATAR");
        vm.stopBroadcast();
    }

    function claim() external {
        _init();
        RentoutsSubnames sub = RentoutsSubnames(_get("rentoutsSubnames"));
        require(address(sub).code.length != 0, "run subnames() first");
        string memory demo = vm.envString("ENS_DEMO_LABEL");
        address holder = vm.envAddress("ENS_DEMO_HOLDER");
        if (sub.holderOf(uint256(keccak256(bytes(demo)))) == holder) {
            console2.log("already claimed");
            return;
        }
        vm.startBroadcast(me);
        sub.register(demo, holder);
        vm.stopBroadcast();
        console2.log("claimed:", string.concat(demo, ".", label, ".eth"));
    }

    function removeIssuer() external {
        _init();
        (address resolverAddr,) = _requireInfra();
        RentoutsSubnames sub = RentoutsSubnames(_get("rentoutsSubnames"));
        address x = vm.envAddress("ENS_REMOVE_ISSUER");
        vm.startBroadcast(me);
        if (sub.isIssuer(x)) sub.setIssuer(x, false);
        _revokeIssuerKeyRoles(IPermissionedResolver(resolverAddr), x);
        vm.stopBroadcast();
        console2.log("issuer removed:", x);
    }

    /// @notice Deploys CredentialSync for ESCROW_ADDRESS (reused if already deployed for the same
    ///         escrow + subnames) and makes it a RentoutsSubnames issuer. A previous CredentialSync
    ///         for a different escrow loses its issuer right, so stale stats can't be written.
    function credentialSync() external {
        _init();
        (address resolverAddr, address registryAddr) = _requireInfra();
        RentoutsSubnames sub = RentoutsSubnames(_get("rentoutsSubnames"));
        require(address(sub).code.length != 0, "run subnames() first");
        require(sub.admin() == me, "sender is not the RentoutsSubnames admin");
        address escrowAddr = vm.envAddress("ESCROW_ADDRESS");
        require(escrowAddr.code.length != 0, "ESCROW_ADDRESS has no code on this chain");
        try IRentEscrow(escrowAddr).tenantStats(address(0)) {}
        catch {
            revert("ESCROW_ADDRESS does not answer tenantStats(address)");
        }

        CredentialSync cs = CredentialSync(_get("credentialSync"));
        bool reuse = address(cs).code.length != 0 && address(cs.escrow()) == escrowAddr
            && address(cs.subnames()) == address(sub);
        vm.startBroadcast(me);
        if (reuse) {
            console2.log("CredentialSync exists:", address(cs));
        } else {
            address old = address(cs);
            cs = new CredentialSync(IRentEscrow(escrowAddr), sub);
            console2.log("deployed CredentialSync:", address(cs));
            if (old.code.length != 0 && sub.isIssuer(old)) sub.setIssuer(old, false);
        }
        if (!sub.isIssuer(address(cs))) sub.setIssuer(address(cs), true);
        vm.stopBroadcast();
        _save(resolverAddr, registryAddr, address(sub), _get("issuer"), address(cs), escrowAddr);
    }

    /// @notice Permissionless: anyone may call CredentialSync.sync. The sender here is just who pays gas.
    function sync() external {
        _init();
        CredentialSync cs = CredentialSync(_get("credentialSync"));
        require(address(cs).code.length != 0, "run credentialSync() first");
        address tenant = vm.envAddress("ENS_SYNC_TENANT");
        string memory name = cs.subnames().nameOf(tenant);
        require(bytes(name).length != 0, "ENS_SYNC_TENANT has no rentouts name");
        vm.startBroadcast(me);
        cs.sync(tenant);
        vm.stopBroadcast();
        console2.log("synced            :", name);
        _logSynced(name);
    }

    // ------------------------------------------------------------------------------------ helpers

    /// @dev ENS-native key-scoped rights for the issuer EOA (the EAC showcase): grants the
    ///      issuer-judged keys and revokes any role on an escrow-derived key. Idempotent.
    function _wireIssuerKeyRoles(IPermissionedResolver resolver, address issuer) internal {
        for (uint256 i; i < ISSUER_KEYS.length; ++i) {
            if (!_hasKeyRole(resolver, ISSUER_KEYS[i], issuer)) {
                resolver.grantSetterRoles(
                    abi.encodeCall(IPermissionedResolver.setText, (hex"00", ISSUER_KEYS[i], "")), issuer
                );
            }
        }
        for (uint256 i; i < DERIVED_KEYS.length; ++i) {
            _revokeKeyRole(resolver, DERIVED_KEYS[i], issuer);
        }
    }

    /// @dev Revokes every rentouts.* key role `account` holds (issuer-judged and escrow-derived).
    function _revokeIssuerKeyRoles(IPermissionedResolver resolver, address account) internal {
        for (uint256 i; i < ISSUER_KEYS.length; ++i) {
            _revokeKeyRole(resolver, ISSUER_KEYS[i], account);
        }
        for (uint256 i; i < DERIVED_KEYS.length; ++i) {
            _revokeKeyRole(resolver, DERIVED_KEYS[i], account);
        }
    }

    function _revokeKeyRole(IPermissionedResolver resolver, string memory key, address account) internal {
        if (_hasKeyRole(resolver, key, account)) {
            resolver.revokeRoles(uint256(keccak256(bytes(key))), ResolverRoles.ROLE_SET_TEXT, account);
            console2.log("revoked resolver SET_TEXT role:", key);
        }
    }

    function _hasKeyRole(IPermissionedResolver resolver, string memory key, address account)
        internal
        view
        returns (bool)
    {
        return resolver.roles(uint256(keccak256(bytes(key))), account) & ResolverRoles.ROLE_SET_TEXT != 0;
    }

    function _logSynced(string memory name) internal view {
        console2.log("UR leasesCompleted:", _urText(name, "rentouts.leasesCompleted"));
        console2.log("UR disputes       :", _urText(name, "rentouts.disputes"));
        console2.log("UR rentPaid (USDC):", _urText(name, "rentouts.rentPaid"));
        console2.log("UR depositReturn %:", _urText(name, "rentouts.depositReturnRate"));
        console2.log("UR escrow         :", _urText(name, "rentouts.escrow"));
    }

    function _parentIsMine() internal view returns (bool) {
        return ETH_REGISTRY.getOwner(uint256(keccak256(bytes(label)))) == me;
    }

    function _requireInfra() internal view returns (address resolver, address registry) {
        resolver = _get("permissionedResolver");
        registry = _get("userRegistry");
        require(resolver.code.length != 0 && registry.code.length != 0, "run infra() first");
    }

    function _duration() internal view returns (uint64) {
        return uint64(vm.envOr("ENS_REG_DURATION", uint256(YEAR)));
    }

    function _commitFile() internal view returns (string memory) {
        return string.concat("deployments/.commit-", label, ".json");
    }

    /// @dev ENS_STATE lets a local anvil-fork rehearsal write somewhere other than the real state file.
    function _statePath() internal view returns (string memory) {
        return vm.envOr("ENS_STATE", string("deployments/sepolia.json"));
    }

    function _get(string memory key) internal view returns (address) {
        if (!vm.exists(_statePath())) return address(0);
        string memory json = vm.readFile(_statePath());
        string memory path = string.concat(".", key);
        return json.keyExists(path) ? json.readAddress(path) : address(0);
    }

    function _save(address resolver, address registry, address sub, address issuer) internal {
        _save(resolver, registry, sub, issuer, _get("credentialSync"), _get("escrow"));
    }

    function _save(address resolver, address registry, address sub, address issuer, address cs, address escrow)
        internal
    {
        if (!broadcasting) {
            console2.log("(dry run: state file not written; set BROADCAST=true with --broadcast)");
            return;
        }
        string memory o = "state";
        o.serialize("ensParentName", string.concat(label, ".eth"));
        o.serialize("ensDeployment", EnsSepolia.DEPLOYMENT_TAG);
        o.serialize("chainId", block.chainid);
        o.serialize("permissionedResolver", resolver);
        o.serialize("userRegistry", registry);
        o.serialize("rentoutsSubnames", sub);
        o.serialize("issuer", issuer);
        if (cs != address(0)) o.serialize("credentialSync", cs);
        if (escrow != address(0)) o.serialize("escrow", escrow);
        string memory json = o.serialize("universalResolver", EnsSepolia.UNIVERSAL_RESOLVER);
        vm.writeJson(json, _statePath());
    }

    function _maybeText(IPermissionedResolver resolver, bytes memory dns, string memory key, string memory envKey)
        internal
    {
        string memory v = vm.envOr(envKey, string(""));
        if (bytes(v).length != 0) resolver.setText(dns, key, v);
    }

    function _urAddr(string memory name) internal view returns (address) {
        try UR.resolve(_dns(name), abi.encodeCall(IAddrResolver.addr, (_namehash(name)))) returns (bytes memory r, address) {
            return abi.decode(r, (address));
        } catch {
            return address(0);
        }
    }

    function _urText(string memory name, string memory key) internal view returns (string memory) {
        try UR.resolve(_dns(name), abi.encodeCall(ITextResolver.text, (_namehash(name), key))) returns (bytes memory r, address) {
            return abi.decode(r, (string));
        } catch {
            return "(unresolved)";
        }
    }

    /// @dev "a.b.eth" -> \x01a\x01b\x03eth\x00
    function _dns(string memory name) internal pure returns (bytes memory out) {
        bytes memory b = bytes(name);
        uint256 start;
        for (uint256 i; i <= b.length; ++i) {
            if (i == b.length || b[i] == ".") {
                bytes memory part = new bytes(i - start);
                for (uint256 j; j < part.length; ++j) {
                    part[j] = b[start + j];
                }
                out = abi.encodePacked(out, uint8(part.length), part);
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
        bytes memory part = new bytes(to - from);
        for (uint256 j; j < part.length; ++j) {
            part[j] = b[from + j];
        }
        return keccak256(part);
    }
}
