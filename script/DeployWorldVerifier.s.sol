// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";
import {WorldHumanVerifier} from "../src/WorldHumanVerifier.sol";

/// @custom:deprecated Deploys the World ID 3.0 verifier, which cannot verify World App 4.0 proofs.
///         Use script/DeployWorldIdV4Gate.s.sol; the live HumanGate verifier is a WorldIdV4Gate.
/// @notice Deploys WorldHumanVerifier. Does not call HumanGate.setVerifier — the gate owner does
///         that after this address exists, which is what turns the open gate on.
/// @dev    Ethereum Sepolia World ID Router (Orb verifyProof): 0x469449f251692E0779667583026b5A1E99512157
///         Env (optional): WORLD_APP_ID (default app_staging_rentouts), WORLD_ACTION (default fund-lease),
///         WORLD_ID_ROUTER (default the Sepolia router above).
///         forge script script/DeployWorldVerifier.s.sol --rpc-url sepolia --account rentouts-deployer --broadcast
contract DeployWorldVerifier is Script {
    address internal constant SEPOLIA_ROUTER = 0x469449f251692E0779667583026b5A1E99512157;

    function run() external {
        address router = vm.envOr("WORLD_ID_ROUTER", SEPOLIA_ROUTER);
        string memory appId = vm.envOr("WORLD_APP_ID", string("app_staging_rentouts"));
        string memory action = vm.envOr("WORLD_ACTION", string("fund-lease"));

        vm.startBroadcast();
        WorldHumanVerifier verifier = new WorldHumanVerifier(IWorldID(router), appId, action);
        vm.stopBroadcast();

        console2.log("WorldHumanVerifier:", address(verifier));
        console2.log("router:", router);
        console2.log("Next: HumanGate.setVerifier(this) from the gate owner. Do not redeploy RentEscrow.");
    }
}
