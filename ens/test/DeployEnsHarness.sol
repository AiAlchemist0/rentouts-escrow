// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployEns} from "../script/DeployEns.s.sol";
import {IPermissionedResolver} from "../src/interfaces/IENSv2.sol";

/// @dev The deploy script with test seams. Environment values and the sender are injected per
///      instance instead of through vm.setEnv, which is process-wide and would race between tests that
///      forge runs in parallel. The phases themselves run unchanged.
contract DeployEnsHarness is DeployEns {
    mapping(string key => string) internal env;
    mapping(string key => bool) internal envSet;
    address internal senderOverride;

    function setEnv(string memory key, string memory value) external {
        env[key] = value;
        envSet[key] = true;
    }

    function unsetEnv(string memory key) external {
        delete env[key];
        delete envSet[key];
    }

    /// @dev The address the phases broadcast from (forge's --sender).
    function setSender(address a) external {
        senderOverride = a;
    }

    // Role helpers used by subnames() and removeIssuer().

    function wireIssuerKeyRoles(IPermissionedResolver r, address issuer) external {
        _wireIssuerKeyRoles(r, issuer);
    }

    function revokeIssuerKeyRoles(IPermissionedResolver r, address account) external {
        _revokeIssuerKeyRoles(r, account);
    }

    function issuerKeys() external view returns (string[] memory k) {
        k = new string[](ISSUER_KEYS.length);
        for (uint256 i; i < k.length; ++i) {
            k[i] = ISSUER_KEYS[i];
        }
    }

    function derivedKeys() external view returns (string[] memory k) {
        k = new string[](DERIVED_KEYS.length);
        for (uint256 i; i < k.length; ++i) {
            k[i] = DERIVED_KEYS[i];
        }
    }

    // Seams.

    function _sender() internal view override returns (address) {
        return senderOverride == address(0) ? msg.sender : senderOverride;
    }

    /// @dev Never falls back to deployments/sepolia.json: a test must name its own state file.
    function _statePath() internal view override returns (string memory) {
        require(envSet["ENS_STATE"], "harness: set ENS_STATE to a test file");
        return env["ENS_STATE"];
    }

    function _envString(string memory key) internal view override returns (string memory) {
        require(envSet[key], string.concat("harness: env ", key, " not set"));
        return env[key];
    }

    function _envAddress(string memory key) internal view override returns (address) {
        return vm.parseAddress(_envString(key));
    }

    function _envOr(string memory key, string memory dflt) internal view override returns (string memory) {
        return envSet[key] ? env[key] : dflt;
    }

    function _envOr(string memory key, address dflt) internal view override returns (address) {
        return envSet[key] ? vm.parseAddress(env[key]) : dflt;
    }

    function _envOr(string memory key, bool dflt) internal view override returns (bool) {
        return envSet[key] ? vm.parseBool(env[key]) : dflt;
    }

    function _envOr(string memory key, uint256 dflt) internal view override returns (uint256) {
        return envSet[key] ? vm.parseUint(env[key]) : dflt;
    }
}
