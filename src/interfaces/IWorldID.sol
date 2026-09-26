// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IWorldID
/// @notice World ID Router `verifyProof` (v3 / legacy Orb path). Only `groupId == 1` (Orb) is valid on-chain.
/// @dev Ethereum Sepolia router: 0x469449f251692E0779667583026b5A1E99512157 (checked 2026-09-26: contract code present).
interface IWorldID {
    /// @notice Reverts when the proof is invalid.
    function verifyProof(
        uint256 root,
        uint256 groupId,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256 externalNullifierHash,
        uint256[8] calldata proof
    ) external view;
}
