// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRentEscrow} from "./interfaces/IRentEscrow.sol";
import {RentoutsSubnames} from "./RentoutsSubnames.sol";

/// @title CredentialSync
/// @notice Derives a tenant's `rentouts.*` ENS credential from RentEscrow state, on-chain.
///
///         `sync(tenant)` is permissionless: it reads `escrow.tenantStats(tenant)` and writes the
///         records through `RentoutsSubnames.setCredential`. No relayer or RentOuts server decides
///         the values, and anyone (the tenant, a landlord, a keeper) can refresh them. If an issuer
///         ever overwrites one of these keys by hand, the next `sync` restores the escrow-derived
///         value.
///
///         This contract must be an issuer on RentoutsSubnames (script phase `credentialSync`).
///         It only writes the five keys below; issuer-judged keys (`rentouts.rating`,
///         `rentouts.onTimeRate`, `rentouts.verified`) stay with the issuer EOA.
contract CredentialSync {
    string public constant LEASES_COMPLETED_KEY = "rentouts.leasesCompleted";
    string public constant DISPUTES_KEY = "rentouts.disputes";
    string public constant RENT_PAID_KEY = "rentouts.rentPaid";
    string public constant DEPOSIT_RETURN_RATE_KEY = "rentouts.depositReturnRate";
    string public constant ESCROW_KEY = "rentouts.escrow";

    /// @dev Escrow token is Circle USDC (6 decimals). rentPaid is written with 2 decimals, truncated.
    uint256 internal constant TOKEN_UNIT = 1e6;
    uint256 internal constant CENT = 1e4;

    IRentEscrow public immutable escrow;
    RentoutsSubnames public immutable subnames;

    event Synced(address indexed tenant, string label, uint32 leasesCompleted, uint32 disputes);

    error NoName(address tenant);
    error ZeroAddress();

    constructor(IRentEscrow escrow_, RentoutsSubnames subnames_) {
        if (address(escrow_) == address(0) || address(subnames_) == address(0)) revert ZeroAddress();
        escrow = escrow_;
        subnames = subnames_;
    }

    /// @notice Rewrite `tenant`'s escrow-derived records from `escrow.tenantStats(tenant)`.
    ///         Reverts with `NoName` if the tenant has no active rentouts name, and with
    ///         `RentoutsSubnames.NotIssuer` if this contract is not (or no longer) an issuer.
    function sync(address tenant) external {
        string memory label = subnames.labelOf(tenant);
        if (bytes(label).length == 0) revert NoName(tenant);
        IRentEscrow.TenantStats memory s = escrow.tenantStats(tenant);

        subnames.setCredential(label, LEASES_COMPLETED_KEY, _toString(s.leasesCompleted));
        subnames.setCredential(label, DISPUTES_KEY, _toString(s.leasesDisputed));
        subnames.setCredential(label, RENT_PAID_KEY, _usdc(s.rentPaid));
        subnames.setCredential(label, DEPOSIT_RETURN_RATE_KEY, _rate(s.depositsReturned, s.depositsPosted));
        subnames.setCredential(label, ESCROW_KEY, escrowAccountId());
        emit Synced(tenant, label, s.leasesCompleted, s.leasesDisputed);
    }

    /// @notice CAIP-10 account id of the escrow, e.g. `eip155:11155111:0xabc...` (lowercase hex).
    function escrowAccountId() public view returns (string memory) {
        return string.concat("eip155:", _toString(block.chainid), ":", _lowerHex(address(escrow)));
    }

    // ---------------------------------------------------------------------------------------
    // String helpers (the ens package has no OpenZeppelin)
    // ---------------------------------------------------------------------------------------

    /// @dev Token units -> "whole.cc", truncated to cents: 0 -> "0.00", 1 -> "0.00", 1234567 -> "1.23".
    function _usdc(uint256 units) internal pure returns (string memory) {
        uint256 cents = (units % TOKEN_UNIT) / CENT;
        return string.concat(_toString(units / TOKEN_UNIT), cents < 10 ? ".0" : ".", _toString(cents));
    }

    /// @dev Whole percent of the deposit returned, rounded down and capped at 100. "n/a" before any
    ///      deposit has been posted on an ended lease.
    function _rate(uint256 returned, uint256 posted) internal pure returns (string memory) {
        if (posted == 0) return "n/a";
        uint256 pct = (returned * 100) / posted;
        return _toString(pct > 100 ? 100 : pct);
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len = 0;
        for (uint256 t = v; t != 0; t /= 10) {
            ++len;
        }
        bytes memory b = new bytes(len);
        for (; v != 0; v /= 10) {
            // forge-lint: disable-next-line(unsafe-typecast)
            b[--len] = bytes1(uint8(48 + (v % 10)));
        }
        return string(b);
    }

    function _lowerHex(address a) internal pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        bytes memory b = new bytes(42);
        b[0] = "0";
        b[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 41; i > 1; --i) {
            b[i] = digits[v & 0xf];
            v >>= 4;
        }
        return string(b);
    }
}
