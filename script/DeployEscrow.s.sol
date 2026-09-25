// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";

/// @notice Deploys RentEscrow to Ethereum Sepolia, wired to a LeaseShare1155 (a new one owned by
///         the deployer unless LEASE_SHARE points at an existing one the deployer owns).
///         Signs with a Foundry keystore account (--account); never takes a raw private key.
///
///   Env: SEPOLIA_RPC_URL, ESCROW_ARBITER (required), ESCROW_TOKEN (default: Circle USDC on
///        Sepolia), LEASE_SHARE (optional), BROADCAST=true to record deployments/sepolia.json.
///
///   Dry run (simulation only, records nothing):
///     forge script script/DeployEscrow.s.sol --rpc-url sepolia --sender <deployer>
///   Deploy:
///     BROADCAST=true forge script script/DeployEscrow.s.sol --rpc-url sepolia \
///       --account <keystore-name> --sender <deployer> --broadcast
contract DeployEscrow is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // Circle test USDC
    string internal constant SHARE_URI = "https://rentouts.co/api/lease-share/{id}.json";
    string internal constant DEPLOYMENTS_DIR = "./deployments";
    string internal constant DEPLOYMENTS_FILE = "./deployments/sepolia.json";

    function run() external returns (RentEscrow escrow, LeaseShare1155 shares) {
        require(block.chainid == SEPOLIA_CHAIN_ID, "DeployEscrow: Ethereum Sepolia (11155111) only");
        address token = vm.envOr("ESCROW_TOKEN", SEPOLIA_USDC);
        address arbiter = vm.envAddress("ESCROW_ARBITER");
        address existingShares = vm.envOr("LEASE_SHARE", address(0));
        bool record = vm.envOr("BROADCAST", false);

        address deployer = msg.sender; // the --sender / --account address
        require(deployer != DEFAULT_SENDER, "DeployEscrow: pass --account <keystore> / --sender <address>");
        require(token.code.length > 0, "DeployEscrow: ESCROW_TOKEN has no code on this chain");
        require(arbiter != address(0), "DeployEscrow: ESCROW_ARBITER is zero");
        if (existingShares != address(0)) {
            require(existingShares.code.length > 0, "DeployEscrow: LEASE_SHARE has no code on this chain");
            // The escrow can only mint lease shares if the deployer can make it the minter.
            require(LeaseShare1155(existingShares).owner() == deployer, "DeployEscrow: deployer must own LEASE_SHARE");
        }

        vm.startBroadcast(deployer);
        shares = existingShares == address(0)
            ? new LeaseShare1155(deployer, SHARE_URI) // constructor allowlists the owner
            : LeaseShare1155(existingShares);
        escrow = new RentEscrow(IERC20(token), arbiter, address(shares));
        shares.setMinter(address(escrow));
        if (!shares.allowlisted(deployer)) shares.setAllowlist(deployer, true);
        vm.stopBroadcast();

        console2.log("chainId        ", block.chainid);
        console2.log("deployer       ", deployer);
        console2.log("token          ", token, IERC20Metadata(token).symbol());
        console2.log("token decimals ", IERC20Metadata(token).decimals());
        console2.log("arbiter        ", arbiter);
        console2.log("LeaseShare1155 ", address(shares), existingShares == address(0) ? "(new)" : "(existing)");
        console2.log("RentEscrow     ", address(escrow));

        if (record) {
            string memory key = "sepolia";
            vm.serializeUint(key, "chainId", block.chainid);
            vm.serializeAddress(key, "token", token);
            vm.serializeAddress(key, "arbiter", arbiter);
            vm.serializeAddress(key, "leaseShare1155", address(shares));
            string memory json = vm.serializeAddress(key, "rentEscrow", address(escrow));
            vm.createDir(DEPLOYMENTS_DIR, true);
            vm.writeJson(json, DEPLOYMENTS_FILE);
            console2.log("recorded", DEPLOYMENTS_FILE);
        } else {
            console2.log("BROADCAST!=true: simulation only, deployments/sepolia.json not written");
        }
    }
}
