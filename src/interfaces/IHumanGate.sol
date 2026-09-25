// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHumanGate
/// @notice Proof-of-personhood check RentEscrow runs before a tenant funds a lease. Implemented by
///         {HumanGate} (a configurable seam) and by whatever verifier it points at, e.g. a World ID
///         adapter that records which addresses have proved they are unique humans.
interface IHumanGate {
    /// @notice True if `account` may fund a new lease.
    function isVerified(address account) external view returns (bool);
}
