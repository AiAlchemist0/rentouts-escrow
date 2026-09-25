// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";

/// @dev forge-std's VmSafe.ForgeContext and vm.isContext, declared here because the vendored
///      forge-std (under lib/openzeppelin-contracts) predates them. Same order, same selector.
enum ForgeContext {
    TestGroup,
    Test,
    Coverage,
    Snapshot,
    ScriptGroup,
    ScriptDryRun,
    ScriptBroadcast,
    ScriptResume,
    Unknown
}

interface IVmForgeContext {
    function isContext(ForgeContext context) external view returns (bool result);
}

/// @notice Deploys RentEscrow to Ethereum Sepolia, wired to a LeaseShare1155 (a new one owned by
///         the deployer unless LEASE_SHARE points at an unused one the deployer owns). One
///         LeaseShare1155 per RentEscrow: a share contract already wired to an escrow is refused.
///         Signs with a Foundry keystore account (--account); never takes a raw private key.
///
///   Env: SEPOLIA_RPC_URL, ESCROW_ARBITER (required: a separate EOA, never the deployer or a lease
///        party), ESCROW_TOKEN (default: Circle USDC on Sepolia), LEASE_SHARE (optional).
///
///   Dry run (simulation only, records nothing):
///     forge script script/DeployEscrow.s.sol --rpc-url sepolia --sender <deployer>
///   Deploy (also records deployments/sepolia.json):
///     forge script script/DeployEscrow.s.sol --rpc-url sepolia \
///       --account <keystore-name> --sender <deployer> --broadcast
contract DeployEscrow is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // Circle test USDC
    string internal constant SHARE_URI = "https://rentouts.co/api/lease-share/{id}.json";
    string internal constant DEPLOYMENTS_DIR = "./deployments";
    string internal constant DEPLOYMENTS_FILE = "./deployments/sepolia.json";

    function run() external returns (RentEscrow escrow, LeaseShare1155 shares) {
        address token = vm.envOr("ESCROW_TOKEN", SEPOLIA_USDC);
        address arbiter = vm.envAddress("ESCROW_ARBITER");
        address existingShares = vm.envOr("LEASE_SHARE", address(0));

        (escrow, shares) = deploy(msg.sender, token, arbiter, existingShares); // the --sender / --account address

        // Record only when forge really broadcasts (--broadcast, or --resume), never in a dry run or a
        // test. forge runs the script before it sends the transactions, so if the broadcast does not
        // complete, check the addresses against broadcast/DeployEscrow.s.sol/11155111/run-latest.json.
        IVmForgeContext ctx = IVmForgeContext(address(vm));
        if (ctx.isContext(ForgeContext.ScriptBroadcast) || ctx.isContext(ForgeContext.ScriptResume)) {
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
            console2.log("no --broadcast: simulation only, deployments/sepolia.json not written");
        }
    }

    /// @notice Checks the config, then deploys and wires the contracts as `deployer`. Separate from
    ///         run() so test/DeployEscrow.t.sol can exercise every check without env vars.
    function deploy(address deployer, address token, address arbiter, address existingShares)
        public
        returns (RentEscrow escrow, LeaseShare1155 shares)
    {
        require(block.chainid == SEPOLIA_CHAIN_ID, "DeployEscrow: Ethereum Sepolia (11155111) only");
        require(deployer != DEFAULT_SENDER, "DeployEscrow: pass --account <keystore> / --sender <address>");
        require(token.code.length > 0, "DeployEscrow: ESCROW_TOKEN has no code on this chain");
        require(arbiter != address(0), "DeployEscrow: ESCROW_ARBITER is zero");
        // The deployer is allowlisted below as the demo landlord, and RentEscrow refuses any lease
        // whose landlord or tenant is the arbiter: the arbiter must be a separate EOA.
        require(arbiter != deployer, "DeployEscrow: ESCROW_ARBITER must not be the deployer (the demo landlord)");
        if (existingShares != address(0)) {
            require(existingShares.code.length > 0, "DeployEscrow: LEASE_SHARE has no code on this chain");
            LeaseShare1155 existing = LeaseShare1155(existingShares);
            // The escrow can only mint lease shares if the deployer can make it the minter.
            require(existing.owner() == deployer, "DeployEscrow: deployer must own LEASE_SHARE");
            // One LeaseShare1155 per RentEscrow: lease ids restart at 1 in every escrow and
            // tokenId == leaseId, so re-wiring a share contract would put two escrows' leases under
            // the same tokenId (and stop the old escrow from listing).
            require(existing.minter() == address(0), "DeployEscrow: LEASE_SHARE already wired to an escrow");
            require(existing.totalSupply(1) == 0, "DeployEscrow: LEASE_SHARE already has shares of tokenId 1");
        }

        vm.startBroadcast(deployer);
        shares = existingShares == address(0)
            ? new LeaseShare1155(deployer, SHARE_URI)  // constructor allowlists the owner
            : LeaseShare1155(existingShares);
        escrow = new RentEscrow(IERC20(token), arbiter, address(shares), address(0)); // human gate: next commit
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
    }
}
