// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";

/// @notice Deploys LeaseShare1155 to Base Sepolia.
/// Usage:
///   forge script script/DeployLeaseShare.s.sol \
///     --rpc-url base_sepolia --broadcast --verify
contract DeployLeaseShare is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);
        LeaseShare1155 shares =
            new LeaseShare1155(owner, "https://rentouts.co/api/lease-share/{id}.json");
        vm.stopBroadcast();

        console2.log("LeaseShare1155 deployed:", address(shares));
        console2.log("owner / issuer:", owner);
    }
}
