// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";
import {HumanGate} from "../src/HumanGate.sol";
import {IHumanGate} from "../src/interfaces/IHumanGate.sol";

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

/// @notice What the deploy does about RentEscrow's (immutable) human gate. From env ESCROW_HUMAN_GATE:
///         unset, "" or "new" -> DeployNew; "none" or the zero address -> None; any other address -> Existing.
enum GateChoice {
    DeployNew, // a new HumanGate owned by the deployer, open (verifier 0) until World ID is plugged in
    None, // humanGate = address(0): funding is never gated, and never can be on this escrow
    Existing // an IHumanGate that is already deployed
}

/// @notice Deploys RentEscrow to Ethereum Sepolia, wired to a LeaseShare1155 (a new one owned by
///         the deployer unless LEASE_SHARE points at an unused one the deployer owns) and to a human
///         gate (by default a new HumanGate owned by the deployer, open until World ID is plugged in
///         with HumanGate.setVerifier; no escrow redeploy needed). One LeaseShare1155 per
///         RentEscrow: a share contract already wired to an escrow is refused.
///         Signs with a Foundry keystore account (--account); never takes a raw private key.
///
///   Env: SEPOLIA_RPC_URL
///        ESCROW_ARBITER    required. An EOA or a contract (e.g. a Safe multisig, or an arbiter
///                          contract deployed separately beforehand). Never the deployer and never a
///                          lease party. Immutable in RentEscrow: choose it before deploying.
///        ESCROW_HUMAN_GATE optional. Unset / "new": deploy a HumanGate (owner = deployer, verifier 0
///                          = open). "none" or 0x0: no gating at all (can never be added to this
///                          escrow). An address: an existing IHumanGate.
///        ESCROW_TOKEN      optional. Default: Circle test USDC on Sepolia.
///        LEASE_SHARE       optional. An unused LeaseShare1155 the deployer owns.
///
///   Dry run (simulation only, records nothing):
///     forge script script/DeployEscrow.s.sol --rpc-url sepolia --sender <deployer>
///   Deploy (also records the "sepolia" entry of deployments.json):
///     forge script script/DeployEscrow.s.sol --rpc-url sepolia \
///       --account <keystore-name> --sender <deployer> --broadcast
contract DeployEscrow is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // Circle test USDC
    string internal constant SHARE_URI = "https://rentouts.co/api/lease-share/{id}.json";
    /// @dev The repo-wide deployments record (Dean's "baseSepolia" entry lives there too).
    string public constant DEPLOYMENTS_FILE = "./deployments.json";

    function run() external returns (RentEscrow escrow, LeaseShare1155 shares, address humanGate) {
        address token = vm.envOr("ESCROW_TOKEN", SEPOLIA_USDC);
        address arbiter = vm.envAddress("ESCROW_ARBITER");
        address existingShares = vm.envOr("LEASE_SHARE", address(0));
        (GateChoice gateChoice, address existingGate) = gateFromEnv(vm.envOr("ESCROW_HUMAN_GATE", string("")));

        address deployer = msg.sender; // the --sender / --account address
        (escrow, shares, humanGate) = deploy(deployer, token, arbiter, existingShares, gateChoice, existingGate);

        // Record only when forge really broadcasts (--broadcast, or --resume), never in a dry run or a
        // test. forge runs the script before it sends the transactions, so if the broadcast does not
        // complete, check the addresses against broadcast/DeployEscrow.s.sol/11155111/run-latest.json
        // (which also holds the deploy transaction hashes; they do not exist yet at this point).
        IVmForgeContext ctx = IVmForgeContext(address(vm));
        if (ctx.isContext(ForgeContext.ScriptBroadcast) || ctx.isContext(ForgeContext.ScriptResume)) {
            record(DEPLOYMENTS_FILE, deployer, token, arbiter, humanGate, address(escrow), address(shares));
            console2.log("recorded", DEPLOYMENTS_FILE, "(sepolia)");
        } else {
            console2.log("no --broadcast: simulation only, deployments.json not written");
        }
    }

    /// @notice Parses ESCROW_HUMAN_GATE (see the contract NatSpec).
    function gateFromEnv(string memory raw) public pure returns (GateChoice choice, address existingGate) {
        bytes32 h = keccak256(bytes(raw));
        if (h == keccak256("") || h == keccak256("new")) return (GateChoice.DeployNew, address(0));
        if (h == keccak256("none")) return (GateChoice.None, address(0));
        existingGate = vm.parseAddress(raw);
        choice = existingGate == address(0) ? GateChoice.None : GateChoice.Existing;
    }

    /// @notice Writes (or replaces) the "sepolia" entry of the deployments file at `path`, keeping
    ///         every other entry (e.g. "baseSepolia") as it is. Creates the file if it is missing.
    function record(
        string memory path,
        address deployer,
        address token,
        address arbiter,
        address humanGate,
        address rentEscrow,
        address leaseShare1155
    ) public {
        string memory key = "sepolia";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "deployer", deployer);
        vm.serializeAddress(key, "token", token);
        vm.serializeAddress(key, "arbiter", arbiter);
        vm.serializeAddress(key, "humanGate", humanGate);
        vm.serializeAddress(key, "leaseShare1155", leaseShare1155);
        string memory json = vm.serializeAddress(key, "rentEscrow", rentEscrow);
        if (!vm.exists(path)) vm.writeFile(path, "{}");
        vm.writeJson(json, path, ".sepolia"); // read-modify-write of this one key
        vm.writeFile(path, string.concat(vm.readFile(path), "\n")); // keep the trailing newline
    }

    /// @notice Checks the config, then deploys and wires the contracts as `deployer`. Separate from
    ///         run() so test/DeployEscrow.t.sol can exercise every check without env vars.
    /// @param existingGate the IHumanGate to use when gateChoice == Existing (ignored otherwise)
    function deploy(
        address deployer,
        address token,
        address arbiter,
        address existingShares,
        GateChoice gateChoice,
        address existingGate
    ) public returns (RentEscrow escrow, LeaseShare1155 shares, address humanGate) {
        require(block.chainid == SEPOLIA_CHAIN_ID, "DeployEscrow: Ethereum Sepolia (11155111) only");
        require(deployer != DEFAULT_SENDER, "DeployEscrow: pass --account <keystore> / --sender <address>");
        require(token.code.length > 0, "DeployEscrow: ESCROW_TOKEN has no code on this chain");
        require(arbiter != address(0), "DeployEscrow: ESCROW_ARBITER is zero");
        // The arbiter may be an EOA or a contract (a Safe, an arbiter contract). The deployer is
        // allowlisted below as the demo landlord, and RentEscrow refuses any lease whose landlord or
        // tenant is the arbiter: the arbiter must be someone else.
        require(arbiter != deployer, "DeployEscrow: ESCROW_ARBITER must not be the deployer (the demo landlord)");
        if (gateChoice == GateChoice.Existing) {
            require(existingGate.code.length > 0, "DeployEscrow: ESCROW_HUMAN_GATE has no code on this chain");
            // RentEscrow will call isVerified(tenant) in every fundLease: make sure the gate answers.
            try IHumanGate(existingGate).isVerified(deployer) returns (bool) {}
            catch {
                revert("DeployEscrow: ESCROW_HUMAN_GATE does not answer isVerified(address)");
            }
        }
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
        if (gateChoice == GateChoice.DeployNew) {
            humanGate = address(new HumanGate(deployer, address(0))); // open until setVerifier(World)
        } else if (gateChoice == GateChoice.Existing) {
            humanGate = existingGate;
        } // GateChoice.None: humanGate stays address(0)
        escrow = new RentEscrow(IERC20(token), arbiter, address(shares), humanGate);
        shares.setMinter(address(escrow));
        if (!shares.allowlisted(deployer)) shares.setAllowlist(deployer, true);
        vm.stopBroadcast();

        console2.log("chainId        ", block.chainid);
        console2.log("deployer       ", deployer);
        console2.log("token          ", token, IERC20Metadata(token).symbol());
        console2.log("token decimals ", IERC20Metadata(token).decimals());
        console2.log("arbiter        ", arbiter, arbiter.code.length > 0 ? "(contract)" : "(EOA)");
        console2.log("LeaseShare1155 ", address(shares), existingShares == address(0) ? "(new)" : "(existing)");
        console2.log(
            "HumanGate      ",
            humanGate,
            gateChoice == GateChoice.DeployNew
                ? "(new, owner = deployer, open)"
                : gateChoice == GateChoice.Existing ? "(existing)" : "(none: funding not gated)"
        );
        console2.log("RentEscrow     ", address(escrow));
    }
}
