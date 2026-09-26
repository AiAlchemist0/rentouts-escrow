// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {WorldIdV4Gate} from "../src/WorldIdV4Gate.sol";

/// @notice Deploys WorldIdV4Gate. Does not call HumanGate.setVerifier.
///         WORLD_ID_SIGNER is the RP signer address (not the private key).
///         WORLD_ACTION defaults to fund-lease.
///         forge script script/DeployWorldIdV4Gate.s.sol --rpc-url sepolia --account <funded> --broadcast
contract DeployWorldIdV4Gate is Script {
    function run() external {
        address signer = vm.envAddress("WORLD_ID_SIGNER");
        string memory action = vm.envOr("WORLD_ACTION", string("fund-lease"));
        vm.startBroadcast();
        WorldIdV4Gate gate = new WorldIdV4Gate(signer, action);
        vm.stopBroadcast();
        console2.log("WorldIdV4Gate:", address(gate));
        console2.log("signer:", signer);
        console2.log("Next: the HumanGate owner calls setVerifier(gate) on HumanGate 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd");
    }
}
