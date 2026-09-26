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
///                      EOA gets key roles on the issuer-judged keys only (escrow-derived ones revoked).
///                      Refuses to re-grant an issuer that removeIssuer() removed (ENS_REINSTATE_ISSUER).
///           profile()  parent records (addr, url, email, com.twitter, description) from env
///           claim()    issuer mints <ENS_DEMO_LABEL>.<parent> to ENS_DEMO_HOLDER (the go/no-go gate)
///           removeIssuer() disables ENS_REMOVE_ISSUER on the contract AND revokes its resolver key roles,
///                      and records it so later runs don't grant it back
///           credentialSync() deploys (or reuses) CredentialSync(ESCROW_ADDRESS, subnames), makes it an
///                      issuer and retires every older one; recorded as pending
///           finalizeCredentialSync() records the pending CredentialSync as active once the chain shows
///                      it deployed and wired (no transactions; ens.sh runs it after credentialSync)
///           sync()     calls CredentialSync.sync(ENS_SYNC_TENANT) (permissionless; for the demo)
///
///         State lives in ens/deployments/sepolia.json (ENS_STATE overrides) and is only written when
///         BROADCAST=true, so dry runs never record addresses that don't exist. Forge runs the script
///         (and writes the file) before it sends anything, so a phase whose transactions matter for
///         security records its work as pending and reconciles on the next run.
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

    /// @dev The state file. The app reads permissionedResolver, userRegistry, rentoutsSubnames,
    ///      universalResolver and, once finalized, credentialSync / escrow.
    struct State {
        address resolver;
        address registry;
        address subnames;
        address issuer; // issuer EOA wired by the last subnames(); cleared by removeIssuer()
        address credentialSync; // confirmed on chain by finalizeCredentialSync()
        address escrow; // the escrow credentialSync reads
        address pendingCredentialSync; // credentialSync()'s result, before the chain confirms it
        address pendingEscrow;
        address[] retiredCredentialSyncs; // superseded syncs; their issuer right is re-checked every run
        address[] removedIssuers; // removeIssuer() targets; subnames() won't grant them again
        address judgeHolder; // holder of judge.<parent> (script/JudgeName.s.sol), once the chain shows it
    }

    string label;
    bool broadcasting;
    address me;

    function _init() internal {
        require(block.chainid == EnsSepolia.CHAIN_ID, "not Ethereum Sepolia");
        label = _envString("ENS_PARENT_LABEL");
        broadcasting = _envOr("BROADCAST", false);
        me = _sender();
        require(me != address(0) && me != DEFAULT_SENDER, "pass --sender <your keystore address>");
        _checkStateParent();
    }

    // ------------------------------------------------------------------------------------ phases

    function run() external {
        status();
    }

    function status() public {
        _init();
        State memory s = _load();
        uint256 labelId = uint256(keccak256(bytes(label)));
        console2.log("parent            :", _parentName());
        console2.log("sender            :", me);
        console2.log("ENS deployment    :", EnsSepolia.DEPLOYMENT_TAG);
        console2.log("parent available  :", REGISTRAR.isAvailable(label));
        console2.log("parent owner      :", ETH_REGISTRY.getOwner(labelId));
        console2.log("parent subregistry:", ETH_REGISTRY.getSubregistry(label));
        console2.log("parent resolver   :", ETH_REGISTRY.getResolver(label));
        console2.log("state resolver    :", s.resolver);
        console2.log("state registry    :", s.registry);
        console2.log("state subnames    :", s.subnames);
        console2.log("state issuer      :", s.issuer);
        console2.log("state credSync    :", s.credentialSync);
        console2.log("state escrow      :", s.escrow);
        if (s.pendingCredentialSync != address(0)) {
            console2.log("PENDING credSync  :", s.pendingCredentialSync, "(run finalize or re-run credentialSync)");
        }
        for (uint256 i; i < s.retiredCredentialSyncs.length; ++i) {
            address r = s.retiredCredentialSyncs[i];
            console2.log("retired credSync  :", r, _isIssuerOnHome(r) ? "STILL AN ISSUER" : "no issuer right");
        }
        bool subDeployed = s.subnames.code.length != 0;
        for (uint256 i; i < s.removedIssuers.length; ++i) {
            address x = s.removedIssuers[i];
            bool still = subDeployed && RentoutsSubnames(s.subnames).isIssuer(x);
            console2.log("removed issuer    :", x, still ? "STILL AN ISSUER" : "disabled");
        }
        if (ETH_REGISTRY.getResolver(label) != address(0)) {
            console2.log("UR text(url)      :", _urText(_parentName(), "url"));
        }
        string memory demo = _envOr("ENS_DEMO_LABEL", string(""));
        if (bytes(demo).length != 0 && s.subnames != address(0)) {
            string memory name = string.concat(demo, ".", _parentName());
            console2.log("demo name         :", name);
            console2.log("UR addr           :", _urAddr(name));
            console2.log("UR credential     :", _urText(name, "rentouts.credential"));
            console2.log("UR status         :", _urText(name, "rentouts.status"));
            if (s.credentialSync != address(0)) _logSynced(name);
        }
    }

    function infra() external {
        _init();
        State memory s = _load();
        IVerifiableFactory factory = IVerifiableFactory(EnsSepolia.VERIFIABLE_FACTORY);
        uint256 version = _envOr("ENS_SALT_VERSION", uint256(1));
        Grant[] memory grants = new Grant[](1);
        grants[0] = Grant(me, ALL_ROLES);

        vm.startBroadcast(me);
        if (s.resolver.code.length == 0) {
            s.resolver = factory.deployProxy(
                EnsSepolia.PERMISSIONED_RESOLVER_IMPL,
                uint256(keccak256(abi.encode("rentouts.resolver", label, version))),
                abi.encodeCall(IPermissionedResolver.initialize, (grants, new bytes[](0)))
            );
            console2.log("deployed PermissionedResolver proxy:", s.resolver);
        } else {
            console2.log("PermissionedResolver exists:", s.resolver);
        }
        if (s.registry.code.length == 0) {
            s.registry = factory.deployProxy(
                EnsSepolia.USER_REGISTRY_IMPL,
                uint256(keccak256(abi.encode("rentouts.registry", label, version))),
                abi.encodeCall(IUserRegistry.initialize, (grants))
            );
            console2.log("deployed UserRegistry proxy:", s.registry);
        } else {
            console2.log("UserRegistry exists:", s.registry);
        }
        vm.stopBroadcast();
        _save(s);
    }

    function commit() external {
        _init();
        if (_parentIsMine()) {
            console2.log("parent already registered to sender; nothing to commit");
            return;
        }
        require(REGISTRAR.isAvailable(label), "parent label is taken: choose another ENS_PARENT_LABEL");
        (address resolver, address registry) = _requireInfra(_load());

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
        (address resolver, address registry) = _requireInfra(_load());
        string memory c = vm.readFile(_commitFile());
        bytes32 secret = c.readBytes32(".secret");
        uint256 committedAt = c.readUint(".committedAt");
        require(block.timestamp >= committedAt + REGISTRAR.MIN_COMMITMENT_AGE(), "commitment too young; wait");
        require(block.timestamp <= committedAt + REGISTRAR.MAX_COMMITMENT_AGE(), "commitment expired; re-run commit()");

        address token = _envOr("ENS_PAYMENT_TOKEN", EnsSepolia.ENS_MOCK_USDC);
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
        console2.log("registered:", _parentName());
    }

    function subnames() external {
        _init();
        State memory s = _load();
        _requireInfra(s);
        require(_parentIsMine(), "register the parent first");
        IPermissionedResolver resolver = IPermissionedResolver(s.resolver);
        IUserRegistry registry = IUserRegistry(s.registry);
        // The issuer must NOT hold root SET_TEXT on the resolver, otherwise ENS can't demonstrate the
        // key-scoped limit (issuer writes rentouts.onTimeRate, reverts on avatar). Use a second account.
        address issuer = _envAddress("ENS_ISSUER");
        require(
            !resolver.hasRootRoles(ResolverRoles.ROLE_SET_TEXT, issuer),
            "ENS_ISSUER holds root SET_TEXT (is it the deployer?): use a separate issuer account"
        );
        // A removed issuer stays removed: re-running subnames/all must not silently grant it back.
        if (_contains(s.removedIssuers, issuer)) {
            require(
                _envOr("ENS_REINSTATE_ISSUER", address(0)) == issuer,
                string.concat(
                    "ENS_ISSUER ",
                    vm.toString(issuer),
                    " was removed by removeIssuer: set a new ENS_ISSUER, or ENS_REINSTATE_ISSUER=<that address> to re-enable it"
                )
            );
            s.removedIssuers = _without(s.removedIssuers, issuer);
            console2.log("reinstating removed issuer (ENS_REINSTATE_ISSUER):", issuer);
        }
        if (s.issuer != address(0) && s.issuer != issuer) {
            console2.log("WARNING: previous issuer is still enabled; run removeIssuer for it:", s.issuer);
        }

        RentoutsSubnames sub = RentoutsSubnames(s.subnames);
        if (address(sub).code.length != 0) _checkSubnamesWiring(sub, s);
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
        s.subnames = address(sub);
        s.issuer = issuer;
        _save(s);
    }

    function profile() external {
        _init();
        (address resolverAddr,) = _requireInfra(_load());
        IPermissionedResolver resolver = IPermissionedResolver(resolverAddr);
        bytes memory dns = abi.encodePacked(uint8(bytes(label).length), label, hex"03", "eth", hex"00");

        vm.startBroadcast(me);
        address a = _envOr("ENS_PROFILE_ADDR", address(0));
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
        RentoutsSubnames sub = _existingSubnames(_load());
        string memory demo = _envString("ENS_DEMO_LABEL");
        address holder = _envAddress("ENS_DEMO_HOLDER");
        if (sub.holderOf(uint256(keccak256(bytes(demo)))) == holder) {
            console2.log("already claimed");
            return;
        }
        vm.startBroadcast(me);
        sub.register(demo, holder);
        vm.stopBroadcast();
        console2.log("claimed:", string.concat(demo, ".", _parentName()));
    }

    function removeIssuer() external {
        _init();
        State memory s = _load();
        _requireInfra(s);
        RentoutsSubnames sub = _existingSubnames(s);
        address x = _envAddress("ENS_REMOVE_ISSUER");
        vm.startBroadcast(me);
        if (sub.isIssuer(x)) sub.setIssuer(x, false);
        _revokeIssuerKeyRoles(IPermissionedResolver(s.resolver), x);
        vm.stopBroadcast();
        // Make the removal stick: subnames() refuses to grant it again, and the state file (read by
        // the app) stops naming it as the issuer. Recording it before the txs land fails closed.
        s.removedIssuers = _addUnique(s.removedIssuers, x);
        if (s.issuer == x) s.issuer = address(0);
        _save(s);
        console2.log("issuer removed:", x);
        if (x == _envOr("ENS_ISSUER", address(0))) {
            console2.log("ENS_ISSUER still names this account: set a new ENS_ISSUER before running subnames/all");
        }
    }

    /// @notice Deploys CredentialSync for ESCROW_ADDRESS (reusing one already deployed for the same
    ///         escrow + subnames) and makes it a RentoutsSubnames issuer. Every other CredentialSync the
    ///         state file has named is retired first: it loses its issuer right on the RentoutsSubnames
    ///         it was built for, so stale stats can't be written.
    ///
    ///         Forge writes the state file before it broadcasts, so the result is recorded as
    ///         `pendingCredentialSync` and the superseded ones stay in `retiredCredentialSyncs`, which is
    ///         reconciled on chain on every run. If the broadcast stops half way, re-running finishes
    ///         the job: it reuses a replacement that did land and still revokes the old one.
    ///         finalizeCredentialSync() makes the pending one active once the chain confirms it.
    function credentialSync() external {
        _init();
        State memory s = _load();
        _requireInfra(s);
        RentoutsSubnames sub = _existingSubnames(s);
        require(sub.admin() == me, "sender is not the RentoutsSubnames admin");
        address escrowAddr = _envAddress("ESCROW_ADDRESS");
        require(escrowAddr.code.length != 0, "ESCROW_ADDRESS has no code on this chain");
        try IRentEscrow(escrowAddr).tenantStats(address(0)) {}
        catch {
            revert("ESCROW_ADDRESS does not answer tenantStats(address)");
        }

        // The newest attempt first: it may have landed without being finalized.
        address keep;
        if (_syncMatches(s.pendingCredentialSync, escrowAddr, address(sub))) keep = s.pendingCredentialSync;
        else if (_syncMatches(s.credentialSync, escrowAddr, address(sub))) keep = s.credentialSync;
        address[] memory retired = _addUnique(s.retiredCredentialSyncs, s.credentialSync);
        retired = _without(_addUnique(retired, s.pendingCredentialSync), keep);

        vm.startBroadcast(me);
        // Revoke before deploying, so the old writer is gone before a new one can write.
        for (uint256 i; i < retired.length; ++i) {
            _retireSync(retired[i]);
        }
        if (keep == address(0)) {
            keep = address(new CredentialSync(IRentEscrow(escrowAddr), sub));
            console2.log("deployed CredentialSync:", keep);
        } else {
            console2.log("CredentialSync exists:", keep);
        }
        if (!sub.isIssuer(keep)) sub.setIssuer(keep, true);
        vm.stopBroadcast();

        if (s.escrow != address(0) && s.escrow != escrowAddr) {
            console2.log("escrow changed: names keep the old escrow's stats until `sync` runs for each tenant");
        }
        s.pendingCredentialSync = keep;
        s.pendingEscrow = escrowAddr;
        // A deploy can reuse the predicted address of an attempt that never landed (same nonce).
        s.retiredCredentialSyncs = _without(retired, keep);
        _save(s);
    }

    /// @notice Sends nothing. Promotes `pendingCredentialSync` to `credentialSync` once the chain shows it
    ///         deployed for the pending escrow, an issuer, and every retired sync without its issuer
    ///         right. Reverts otherwise, so a failed or partial broadcast never becomes the app's address.
    function finalizeCredentialSync() external {
        _init();
        State memory s = _load();
        address p = s.pendingCredentialSync;
        if (p == address(0)) {
            console2.log("no pending CredentialSync; state file is final");
            return;
        }
        RentoutsSubnames sub = _existingSubnames(s);
        require(
            _syncMatches(p, s.pendingEscrow, address(sub)),
            "pending CredentialSync is not on chain (yet): re-run credentialSync"
        );
        require(sub.isIssuer(p), "pending CredentialSync is not an issuer (yet): re-run credentialSync");
        for (uint256 i; i < s.retiredCredentialSyncs.length; ++i) {
            address r = s.retiredCredentialSyncs[i];
            require(
                !_revocableIssuer(r),
                string.concat("retired CredentialSync ", vm.toString(r), " is still an issuer: re-run credentialSync")
            );
            if (_isIssuerOnHome(r)) console2.log("WARNING: retired CredentialSync is still an issuer (not our admin):", r);
        }
        s.credentialSync = p;
        s.escrow = s.pendingEscrow;
        s.pendingCredentialSync = address(0);
        s.pendingEscrow = address(0);
        _save(s);
        console2.log("finalized credentialSync:", p);
    }

    /// @notice Permissionless: anyone may call CredentialSync.sync. The sender here is just who pays gas.
    function sync() external {
        _init();
        CredentialSync cs = CredentialSync(_load().credentialSync);
        require(address(cs).code.length != 0, "run credentialSync() first (it records the contract once confirmed)");
        address tenant = _envAddress("ENS_SYNC_TENANT");
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

    /// @dev True if `cs` is a deployed CredentialSync reading `escrowAddr` and writing through `sub`.
    function _syncMatches(address cs, address escrowAddr, address sub) internal view returns (bool) {
        (bool ok, address e) = _readAddress(cs, abi.encodeWithSignature("escrow()"));
        if (!ok || e != escrowAddr) return false;
        address home;
        (ok, home) = _readAddress(cs, abi.encodeWithSignature("subnames()"));
        return ok && home == sub;
    }

    /// @dev The RentoutsSubnames a CredentialSync was built for (Codex M2: revoke it THERE, which after
    ///      a RentoutsSubnames replacement is not the current one). address(0) if `cs` isn't one.
    function _syncHome(address cs) internal view returns (RentoutsSubnames) {
        (bool ok, address home) = _readAddress(cs, abi.encodeWithSignature("subnames()"));
        return ok && home.code.length != 0 ? RentoutsSubnames(home) : RentoutsSubnames(address(0));
    }

    function _isIssuerOnHome(address cs) internal view returns (bool) {
        RentoutsSubnames home = _syncHome(cs);
        return address(home) != address(0) && home.isIssuer(cs);
    }

    /// @dev Still an issuer on a RentoutsSubnames this sender administers (so we can and must revoke it).
    function _revocableIssuer(address cs) internal view returns (bool) {
        RentoutsSubnames home = _syncHome(cs);
        return address(home) != address(0) && home.isIssuer(cs) && home.admin() == me;
    }

    /// @dev Idempotent. Skips an address with no code (an attempt whose deploy never landed).
    function _retireSync(address cs) internal {
        RentoutsSubnames home = _syncHome(cs);
        if (address(home) == address(0) || !home.isIssuer(cs)) return;
        if (home.admin() != me) {
            console2.log("WARNING: cannot retire CredentialSync (sender is not admin of its RentoutsSubnames):", cs);
            return;
        }
        home.setIssuer(cs, false);
        console2.log("retired CredentialSync (issuer right removed):", cs);
    }

    function _readAddress(address target, bytes memory data) internal view returns (bool ok, address a) {
        if (target.code.length == 0) return (false, address(0));
        bytes memory ret;
        (ok, ret) = target.staticcall(data);
        if (!ok || ret.length != 32) return (false, address(0));
        uint256 v = abi.decode(ret, (uint256));
        if (v >> 160 != 0) return (false, address(0));
        a = address(uint160(v));
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

    function _parentName() internal view returns (string memory) {
        return string.concat(label, ".eth");
    }

    function _requireInfra(State memory s) internal view returns (address resolver, address registry) {
        resolver = s.resolver;
        registry = s.registry;
        require(resolver.code.length != 0 && registry.code.length != 0, "run infra() first");
    }

    function _existingSubnames(State memory s) internal view returns (RentoutsSubnames sub) {
        sub = RentoutsSubnames(s.subnames);
        require(address(sub).code.length != 0, "run subnames() first");
        _checkSubnamesWiring(sub, s);
    }

    /// @dev Codex L3: a RentoutsSubnames serves one parent through one registry + resolver (immutable).
    ///      Reusing it for another parent would keep writing credentials under the old name.
    function _checkSubnamesWiring(RentoutsSubnames sub, State memory s) internal view {
        string memory served = sub.parentName();
        require(
            _eq(served, _parentName()),
            string.concat(
                "RentoutsSubnames ", vm.toString(address(sub)), " serves ", served, ", not ", _parentName()
            )
        );
        require(
            address(sub.registry()) == s.registry && address(sub.resolver()) == s.resolver,
            "RentoutsSubnames is wired to another registry/resolver than the state file"
        );
    }

    /// @dev Codex L3: a state file belongs to one parent name. Refuse it for any other ENS_PARENT_LABEL.
    function _checkStateParent() internal view {
        string memory path = _statePath();
        if (!vm.exists(path)) return;
        string memory json = vm.readFile(path);
        string memory saved = json.keyExists(".ensParentName") ? json.readString(".ensParentName") : "";
        require(
            _eq(saved, _parentName()),
            string.concat(
                path,
                " is for ",
                bytes(saved).length == 0 ? "(no ensParentName)" : saved,
                ", not ",
                _parentName(),
                ": fix ENS_PARENT_LABEL or use a new ENS_STATE file"
            )
        );
    }

    function _duration() internal view returns (uint64) {
        return uint64(_envOr("ENS_REG_DURATION", uint256(YEAR)));
    }

    function _commitFile() internal view returns (string memory) {
        return string.concat("deployments/.commit-", label, ".json");
    }

    /// @dev ENS_STATE lets a local anvil-fork rehearsal write somewhere other than the real state file
    ///      (scripts/ens.sh defaults it to deployments/local.json whenever RPC_OVERRIDE is set).
    function _statePath() internal view virtual returns (string memory) {
        return _envOr("ENS_STATE", string("deployments/sepolia.json"));
    }

    function _load() internal view returns (State memory s) {
        string memory path = _statePath();
        if (!vm.exists(path)) return s;
        string memory json = vm.readFile(path);
        s.resolver = _addrAt(json, "permissionedResolver");
        s.registry = _addrAt(json, "userRegistry");
        s.subnames = _addrAt(json, "rentoutsSubnames");
        s.issuer = _addrAt(json, "issuer");
        s.credentialSync = _addrAt(json, "credentialSync");
        s.escrow = _addrAt(json, "escrow");
        s.pendingCredentialSync = _addrAt(json, "pendingCredentialSync");
        s.pendingEscrow = _addrAt(json, "pendingEscrow");
        s.retiredCredentialSyncs = _addrsAt(json, "retiredCredentialSyncs");
        s.removedIssuers = _addrsAt(json, "removedIssuers");
        s.judgeHolder = _addrAt(json, "judgeHolder");
    }

    function _save(State memory s) internal {
        if (!broadcasting) {
            console2.log("(dry run: state file not written; set BROADCAST=true with --broadcast)");
            return;
        }
        string memory o = "state";
        vm.serializeJson(o, "{}"); // start empty, so keys cleared in `s` disappear from the file
        o.serialize("ensParentName", _parentName());
        o.serialize("ensDeployment", EnsSepolia.DEPLOYMENT_TAG);
        o.serialize("chainId", block.chainid);
        o.serialize("permissionedResolver", s.resolver);
        o.serialize("userRegistry", s.registry);
        o.serialize("rentoutsSubnames", s.subnames);
        if (s.issuer != address(0)) o.serialize("issuer", s.issuer);
        if (s.credentialSync != address(0)) o.serialize("credentialSync", s.credentialSync);
        if (s.escrow != address(0)) o.serialize("escrow", s.escrow);
        if (s.pendingCredentialSync != address(0)) {
            o.serialize("pendingCredentialSync", s.pendingCredentialSync);
            o.serialize("pendingEscrow", s.pendingEscrow);
        }
        if (s.retiredCredentialSyncs.length != 0) o.serialize("retiredCredentialSyncs", s.retiredCredentialSyncs);
        if (s.removedIssuers.length != 0) o.serialize("removedIssuers", s.removedIssuers);
        if (s.judgeHolder != address(0)) {
            o.serialize("judgeName", string.concat("judge.", _parentName()));
            o.serialize("judgeHolder", s.judgeHolder);
        }
        string memory json = o.serialize("universalResolver", EnsSepolia.UNIVERSAL_RESOLVER);
        vm.writeJson(json, _statePath());
    }

    function _addrAt(string memory json, string memory key) internal view returns (address) {
        string memory path = string.concat(".", key);
        return json.keyExists(path) ? json.readAddress(path) : address(0);
    }

    function _addrsAt(string memory json, string memory key) internal view returns (address[] memory) {
        string memory path = string.concat(".", key);
        return json.keyExists(path) ? json.readAddressArray(path) : new address[](0);
    }

    function _contains(address[] memory list, address a) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }

    /// @dev `list` plus `a` (ignores address(0) and duplicates).
    function _addUnique(address[] memory list, address a) internal pure returns (address[] memory out) {
        if (a == address(0) || _contains(list, a)) return list;
        out = new address[](list.length + 1);
        for (uint256 i; i < list.length; ++i) {
            out[i] = list[i];
        }
        out[list.length] = a;
    }

    /// @dev `list` without `a`.
    function _without(address[] memory list, address a) internal pure returns (address[] memory out) {
        if (!_contains(list, a)) return list;
        out = new address[](list.length - 1);
        uint256 n;
        for (uint256 i; i < list.length; ++i) {
            if (list[i] != a) out[n++] = list[i];
        }
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _maybeText(IPermissionedResolver resolver, bytes memory dns, string memory key, string memory envKey)
        internal
    {
        string memory v = _envOr(envKey, string(""));
        if (bytes(v).length != 0) resolver.setText(dns, key, v);
    }

    // Environment and sender. Virtual so the fork tests can inject values per test: vm.setEnv is
    // process-wide and would race between tests that forge runs in parallel.

    function _sender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _envString(string memory key) internal view virtual returns (string memory) {
        return vm.envString(key);
    }

    function _envAddress(string memory key) internal view virtual returns (address) {
        return vm.envAddress(key);
    }

    function _envOr(string memory key, string memory dflt) internal view virtual returns (string memory) {
        return vm.envOr(key, dflt);
    }

    function _envOr(string memory key, address dflt) internal view virtual returns (address) {
        return vm.envOr(key, dflt);
    }

    function _envOr(string memory key, bool dflt) internal view virtual returns (bool) {
        return vm.envOr(key, dflt);
    }

    function _envOr(string memory key, uint256 dflt) internal view virtual returns (uint256) {
        return vm.envOr(key, dflt);
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
