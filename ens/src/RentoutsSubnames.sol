// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUserRegistry, IPermissionedResolver} from "./interfaces/IENSv2.sol";

/// @title RentoutsSubnames
/// @notice Issues `<label>.<parent>.eth` ENSv2 subnames that act as a portable, non-transferable
///         rental identity + credential for RentOuts tenants.
///
///         Built on ENSv2 primitives rather than a custom NFT:
///         - the subname lives in a `UserRegistry` proxy (our subregistry for the parent name);
///         - it is registered with an EMPTY token role bitmap, so the holder never gets
///           `ROLE_CAN_TRANSFER_ADMIN`: ENS reverts `unsafeTransfer` with `TransferDisallowed`, and
///           ERC-1155 safe transfers revert because the registry is not emancipated (soulbound);
///         - it never expires (the parent's expiry already bounds resolution), so revocation is the
///           only way a credential ends: ENS `unregister`, which works because this contract holds
///           the root `ROLE_UNREGISTER` on the registry (names are deliberately not emancipated);
///         - records live in ONE shared `PermissionedResolver`. Resolver roles are scoped per record
///           key, not per name, so holders never get raw resolver roles; this contract enforces
///           who may write what, and issuers can additionally hold ENS-native key-scoped roles.
contract RentoutsSubnames {
    // ---------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------

    uint256 internal constant COIN_TYPE_ETH = 60;
    /// @dev ENSIP-19 default EVM address: one record answers coin 60 and every EVM chain (e.g. Base).
    uint256 internal constant COIN_TYPE_DEFAULT = 1 << 31;
    uint64 internal constant NO_EXPIRY = type(uint64).max;
    string public constant CREDENTIAL_KEY = "rentouts.credential";
    string public constant STATUS_KEY = "rentouts.status";
    string public constant CREDENTIAL_VERSION = "tenant/v1";

    // ---------------------------------------------------------------------------------------
    // Immutable wiring
    // ---------------------------------------------------------------------------------------

    IUserRegistry public immutable registry;
    IPermissionedResolver public immutable resolver;
    /// @notice DNS-encoded parent name, e.g. `\x08rentouts\x03eth\x00`.
    bytes public parentDns;
    /// @notice Human-readable parent name, e.g. `rentouts.eth`.
    string public parentName;

    // ---------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------

    address public admin;
    mapping(address account => bool) public isIssuer;
    /// @notice Owner-editable profile keys (e.g. avatar, description). Keyed by keccak256(key).
    mapping(bytes32 keyHash => bool) public profileKeyAllowed;

    mapping(address holder => string) internal _labelOf;
    /// @notice Current holder of a label, keyed by labelId = uint256(keccak256(label)).
    mapping(uint256 labelId => address) public holderOf;
    /// @notice Revoked labels are retired for good (labels are single-use in this registry).
    mapping(uint256 labelId => bool) public retired;

    // ---------------------------------------------------------------------------------------
    // Events / errors
    // ---------------------------------------------------------------------------------------

    event Claimed(string label, address indexed holder, uint256 tokenId);
    event CredentialSet(string label, address indexed holder, string key, string value);
    event ProfileTextSet(string label, address indexed holder, string key, string value);
    event Revoked(string label, address indexed holder, string reason);
    event IssuerSet(address indexed account, bool enabled);
    event ProfileKeySet(string key, bool allowed);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error NotAdmin();
    error NotIssuer();
    error NotAuthorized();
    error NotHolder(string label);
    error InvalidLabel(string label);
    error AlreadyHasName(address holder);
    error LabelRetired(string label);
    error LabelTaken(string label);
    error UnknownLabel(string label);
    error NotCredentialKey(string key);
    error ProfileKeyNotAllowed(string key);
    error ZeroAddress();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyIssuer() {
        if (!isIssuer[msg.sender]) revert NotIssuer();
        _;
    }

    constructor(
        IUserRegistry registry_,
        IPermissionedResolver resolver_,
        string memory parentLabel,
        address admin_
    ) {
        if (address(registry_) == address(0) || address(resolver_) == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        resolver = resolver_;
        admin = admin_;
        isIssuer[admin_] = true;
        parentDns = abi.encodePacked(_dnsLabel(parentLabel), hex"03", "eth", hex"00");
        parentName = string.concat(parentLabel, ".eth");

        string[5] memory keys = ["avatar", "description", "url", "com.twitter", "com.github"];
        for (uint256 i; i < keys.length; ++i) {
            profileKeyAllowed[keccak256(bytes(keys[i]))] = true;
        }
        emit AdminTransferred(address(0), admin_);
        emit IssuerSet(admin_, true);
    }

    // ---------------------------------------------------------------------------------------
    // Claim / credential / revoke
    // ---------------------------------------------------------------------------------------

    /// @notice Mint `<label>.<parent>` to `holder`. Self-serve (`msg.sender == holder`) or by an issuer.
    ///         One name per address. The token is soulbound: ENS refuses transfers.
    function register(string calldata label, address holder) external returns (uint256 tokenId) {
        if (holder == address(0)) revert ZeroAddress();
        if (msg.sender != holder && !isIssuer[msg.sender]) revert NotAuthorized();
        _validateLabel(label);
        if (bytes(_labelOf[holder]).length != 0) revert AlreadyHasName(holder);
        uint256 labelId = _labelId(label);
        if (retired[labelId]) revert LabelRetired(label);
        // Labels are single-use for the life of the registry: ENS never resets expiry to 0 once a
        // label has been registered, so this also blocks labels revoked by a previous deployment of
        // this contract (whose `retired` map we can't see) from inheriting old records.
        if (registry.getExpiry(labelId) != 0) revert LabelTaken(label);

        // Effects before the external calls: ENS mints an ERC-1155 token, which calls
        // onERC1155Received on contract holders.
        _labelOf[holder] = label;
        holderOf[labelId] = holder;

        // roleBitmap = 0: no ROLE_CAN_TRANSFER_ADMIN (soulbound) and no SET_RESOLVER /
        // SET_SUBREGISTRY / UNREGISTER for the holder, so the credential can't be detached.
        tokenId = registry.register(label, holder, address(0), address(resolver), 0, NO_EXPIRY);

        bytes memory dns = dnsName(label);
        // EOAs have the same address on every EVM chain: write the ENSIP-19 default once. Contract
        // wallets may not, so they only get the Ethereum (coin 60) record.
        uint256 coinType = holder.code.length == 0 ? COIN_TYPE_DEFAULT : COIN_TYPE_ETH;
        resolver.setAddress(dns, coinType, abi.encodePacked(holder));
        resolver.setText(dns, CREDENTIAL_KEY, CREDENTIAL_VERSION);
        resolver.setText(dns, STATUS_KEY, "active");
        emit Claimed(label, holder, tokenId);
    }

    /// @notice Issuer-written credential record, e.g. `rentouts.leasesCompleted = 3`.
    ///         Only `rentouts.*` keys. Issuers can also write directly on the resolver with ENS-native
    ///         key-scoped roles (granted in the deploy script); this function is the spec'd entry point.
    function setCredential(string calldata label, string calldata key, string calldata value) external onlyIssuer {
        address holder = _activeHolder(label);
        if (!_isCredentialKey(key)) revert NotCredentialKey(key);
        resolver.setText(dnsName(label), key, value);
        emit CredentialSet(label, holder, key, value);
    }

    /// @notice Holder-editable profile text (allowlisted keys only, never `rentouts.*`).
    function setProfileText(string calldata label, string calldata key, string calldata value) external {
        uint256 labelId = _labelId(label);
        address holder = holderOf[labelId];
        if (holder == address(0) || holder != msg.sender || registry.getOwner(labelId) != msg.sender) {
            revert NotHolder(label);
        }
        if (!profileKeyAllowed[keccak256(bytes(key))]) revert ProfileKeyNotAllowed(key);
        resolver.setText(dnsName(label), key, value);
        emit ProfileTextSet(label, holder, key, value);
    }

    /// @notice Revoke a credential: wipe its records, mark it revoked, burn the ENS token and retire
    ///         the label. Wiping matters: the subname shares the parent's resolver, so after
    ///         `unregister` the Universal Resolver still finds this name's record via the parent.
    ///         `linkToRecord(name, 0)` detaches the old record (addresses, credential, issuer stats,
    ///         profile) and the status write then allocates a fresh record holding only `revoked`.
    function revoke(string calldata label, string calldata reason) external onlyIssuer {
        address holder = _activeHolder(label);
        uint256 labelId = _labelId(label);

        retired[labelId] = true;
        delete holderOf[labelId];
        delete _labelOf[holder];

        bytes memory dns = dnsName(label);
        resolver.linkToRecord(dns, 0);
        resolver.setText(dns, STATUS_KEY, "revoked");
        // Skip if the name was already removed out of band (unregister reverts on expired labels).
        if (registry.getOwner(labelId) != address(0)) registry.unregister(labelId);
        emit Revoked(label, holder, reason);
    }

    // ---------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------

    /// @dev Gates only this contract's issuer paths. ENS-native key-scoped resolver roles granted to
    ///      an issuer EOA must be revoked on the resolver too (script phase `removeIssuer`).
    function setIssuer(address account, bool enabled) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        isIssuer[account] = enabled;
        emit IssuerSet(account, enabled);
    }

    function setProfileKey(string calldata key, bool allowed) external onlyAdmin {
        if (_isCredentialKey(key)) revert NotCredentialKey(key); // credential keys are issuer-only
        profileKeyAllowed[keccak256(bytes(key))] = allowed;
        emit ProfileKeySet(key, allowed);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    function labelOf(address holder) external view returns (string memory) {
        return _labelOf[holder];
    }

    /// @notice Full name for a holder, e.g. `alice.rentouts.eth`, or "" if none.
    function nameOf(address holder) external view returns (string memory) {
        string memory label = _labelOf[holder];
        return bytes(label).length == 0 ? "" : string.concat(label, ".", parentName);
    }

    /// @notice DNS-encoded `<label>.<parent>`, the form ENSv2 resolver setters take.
    function dnsName(string memory label) public view returns (bytes memory) {
        return abi.encodePacked(_dnsLabel(label), parentDns);
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    function _activeHolder(string calldata label) internal view returns (address holder) {
        holder = holderOf[_labelId(label)];
        if (holder == address(0)) revert UnknownLabel(label);
    }

    function _labelId(string memory label) internal pure returns (uint256) {
        return uint256(keccak256(bytes(label)));
    }

    function _dnsLabel(string memory label) internal pure returns (bytes memory) {
        uint256 len = bytes(label).length;
        if (len == 0 || len > 255) revert InvalidLabel(label); // DNS wire format: 1-byte length
        // forge-lint: disable-next-line(unsafe-typecast)
        return abi.encodePacked(uint8(len), label);
    }

    function _isCredentialKey(string calldata key) internal pure returns (bool) {
        bytes memory k = bytes(key);
        bytes memory prefix = "rentouts.";
        if (k.length <= prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (k[i] != prefix[i]) return false;
        }
        return true;
    }

    /// @dev 3-32 chars of [a-z0-9-], no leading/trailing hyphen, no "--" at positions 3-4 (ENSIP-15
    ///      label extension). A strict subset of ENSIP-15-normalized labels, so no on-chain normalizer.
    function _validateLabel(string calldata label) internal pure {
        bytes memory b = bytes(label);
        if (b.length < 3 || b.length > 32 || b[0] == "-" || b[b.length - 1] == "-") {
            revert InvalidLabel(label);
        }
        if (b.length >= 4 && b[2] == "-" && b[3] == "-") revert InvalidLabel(label);
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-";
            if (!ok) revert InvalidLabel(label);
        }
    }
}
