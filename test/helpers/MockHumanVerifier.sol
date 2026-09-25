// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHumanGate} from "../../src/interfaces/IHumanGate.sol";

/// @notice TEST-ONLY stand-in for a World ID verifier: anyone can mark addresses verified, and it
///         can be told to revert (a verifier that is down).
contract MockHumanVerifier is IHumanGate {
    mapping(address account => bool) public verified;
    bool public down;

    function setVerified(address account, bool ok) external {
        verified[account] = ok;
    }

    function setDown(bool down_) external {
        down = down_;
    }

    function isVerified(address account) external view returns (bool) {
        require(!down, "MockHumanVerifier: down");
        return verified[account];
    }
}
