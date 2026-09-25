// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice ENSv2 Sepolia beta addresses from ensdomains/contracts-v2 tag
///         `sepolia-deployment-2026-09-15` (contracts/deployments/sepolia/addresses.md).
///         Sepolia v2 is reset every few weeks: if ENS publishes a newer tag, update this file only.
library EnsSepolia {
    uint256 internal constant CHAIN_ID = 11155111;
    string internal constant DEPLOYMENT_TAG = "sepolia-deployment-2026-09-15";

    address internal constant ETH_REGISTRAR = 0xAbe76F6C8DFcEd81AA5A2bB8034202A7136b94ca;
    address internal constant ETH_REGISTRY = 0x657eA849311d3D5823348ddEd7C2AaAFb3EDE09E;
    address internal constant VERIFIABLE_FACTORY = 0x9e726Eb570beb6BCEb495AB8cdA7df517d4e841C;
    address internal constant USER_REGISTRY_IMPL = 0xA80338aAA8D23831cEa25E858D1774534aBb0263;
    address internal constant PERMISSIONED_RESOLVER_IMPL = 0x14F09Fd05d4585759e54844DC9B00147131Cf243;
    address internal constant UNIVERSAL_RESOLVER = 0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe;
    /// @dev ENS's MockUSDC pays ENS fees only. It has an open `nuke(owner)`: never hold escrow funds in it.
    address internal constant ENS_MOCK_USDC = 0x16f95D91DBa7dA3Aca778Ec053dF0FF6C6A8aA8e;
}
