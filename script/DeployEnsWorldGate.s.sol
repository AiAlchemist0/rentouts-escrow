// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AllOfHumanGate} from "../src/AllOfHumanGate.sol";
import {EnsCredentialGate} from "../src/EnsCredentialGate.sol";
import {IHumanGate} from "../src/interfaces/IHumanGate.sol";
import {ForgeContext, IVmForgeContext} from "./DeployEscrow.s.sol";

/// @dev The two reads this script makes on the live HumanGate (for the printed next step).
interface IHumanGateAdmin {
    function owner() external view returns (address);
    function verifier() external view returns (address);
}

/// @notice Deploys the combined ENS + World human gate for the LIVE Sepolia HumanGate:
///           EnsCredentialGate(RentoutsSubnames)              "holds an active rentouts.eth name"
///           AllOfHumanGate([WorldIdV4Gate, EnsCredentialGate]) "World-verified human AND that"
///         It does NOT touch HumanGate: the gate owner then switches funding over with ONE tx
///         (printed at the end), and rolls back with one more (setVerifier(WorldIdV4Gate) or 0).
///         Neither contract has an owner or any setter. Signs with a Foundry keystore (--account);
///         never takes a raw private key.
///
///   Env (all optional; defaults are the live Sepolia deployment):
///     WORLD_GATE    WorldIdV4Gate      default 0x27052bD69b3d961940bCD093C21ba729b6c1B209
///     ENS_SUBNAMES  RentoutsSubnames   default 0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60
///     HUMAN_GATE    HumanGate (only read, for the printed setVerifier command)
///                                      default 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd
///
///   Dry run (simulation only, records nothing):
///     forge script script/DeployEnsWorldGate.s.sol --rpc-url sepolia --sender <deployer>
///   Deploy (also records the "sepoliaHumanGates" entry of deployments.json):
///     forge script script/DeployEnsWorldGate.s.sol --rpc-url sepolia \
///       --account <keystore-name> --sender <deployer> --broadcast
contract DeployEnsWorldGate is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address public constant DEFAULT_WORLD_GATE = 0x27052bD69b3d961940bCD093C21ba729b6c1B209;
    address public constant DEFAULT_SUBNAMES = 0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60;
    address public constant DEFAULT_HUMAN_GATE = 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd;
    /// @notice alice.rentouts.eth, the demo tenant: printed as a pre-flight check.
    address public constant DEMO_TENANT = 0x484811c8c967809bE644A89d677933c29fb9e936;
    string public constant DEPLOYMENTS_FILE = "./deployments.json";
    string public constant RECORD_KEY = "sepoliaHumanGates";

    function run() external returns (EnsCredentialGate ensGate, AllOfHumanGate composite) {
        address worldGate = vm.envOr("WORLD_GATE", DEFAULT_WORLD_GATE);
        address subnames = vm.envOr("ENS_SUBNAMES", DEFAULT_SUBNAMES);
        address humanGate = vm.envOr("HUMAN_GATE", DEFAULT_HUMAN_GATE);
        address deployer = msg.sender; // the --sender / --account address

        (ensGate, composite) = deploy(deployer, worldGate, subnames, humanGate);

        // Record only when forge really broadcasts (--broadcast / --resume), never in a dry run or a
        // test (same rule as DeployEscrow / DeployAIArbiter).
        IVmForgeContext ctx = IVmForgeContext(address(vm));
        if (ctx.isContext(ForgeContext.ScriptBroadcast) || ctx.isContext(ForgeContext.ScriptResume)) {
            record(DEPLOYMENTS_FILE, deployer, worldGate, subnames, humanGate, ensGate, composite);
            console2.log("recorded", DEPLOYMENTS_FILE, "(sepoliaHumanGates)");
        } else {
            console2.log("no --broadcast: simulation only, deployments.json not written");
        }
        printNextSteps(humanGate, worldGate, address(composite));
    }

    /// @notice Checks the config, then deploys both gates as `deployer`. Separate from run() so the
    ///         fork test can use exactly this code path.
    function deploy(address deployer, address worldGate, address subnames, address humanGate)
        public
        returns (EnsCredentialGate ensGate, AllOfHumanGate composite)
    {
        require(block.chainid == SEPOLIA_CHAIN_ID, "DeployEnsWorldGate: Ethereum Sepolia (11155111) only");
        require(deployer != DEFAULT_SENDER, "DeployEnsWorldGate: pass --account <keystore> / --sender <address>");
        require(worldGate.code.length > 0, "DeployEnsWorldGate: WORLD_GATE has no code");
        require(subnames.code.length > 0, "DeployEnsWorldGate: ENS_SUBNAMES has no code");
        // HumanGate forwards to its verifier: using it as a sub-gate would loop once it is plugged in.
        require(worldGate != humanGate, "DeployEnsWorldGate: WORLD_GATE must not be the HumanGate");

        vm.startBroadcast(deployer);
        ensGate = new EnsCredentialGate(subnames);
        address[] memory list = new address[](2);
        list[0] = worldGate; // cheapest check first
        list[1] = address(ensGate);
        composite = new AllOfHumanGate(list);
        vm.stopBroadcast();

        console2.log("chainId              ", block.chainid);
        console2.log("deployer             ", deployer);
        console2.log("RentoutsSubnames     ", subnames);
        console2.log("ENS registry         ", address(ensGate.registry()));
        console2.log("WorldIdV4Gate        ", worldGate);
        console2.log("EnsCredentialGate    ", address(ensGate));
        console2.log("AllOfHumanGate       ", address(composite));
        console2.log("pre-flight, demo tenant", DEMO_TENANT);
        console2.log("  World verified     ", IHumanGate(worldGate).isVerified(DEMO_TENANT));
        console2.log("  ENS credential     ", ensGate.isVerified(DEMO_TENANT));
        console2.log("  combined           ", composite.isVerified(DEMO_TENANT));
    }

    /// @notice Writes (or replaces) the "sepoliaHumanGates" entry of the deployments file at `path`,
    ///         keeping every other entry. Creates the file if it is missing.
    function record(
        string memory path,
        address deployer,
        address worldGate,
        address subnames,
        address humanGate,
        EnsCredentialGate ensGate,
        AllOfHumanGate composite
    ) public {
        string memory key = RECORD_KEY;
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "deployer", deployer);
        vm.serializeAddress(key, "worldIdV4Gate", worldGate);
        vm.serializeAddress(key, "rentoutsSubnames", subnames);
        vm.serializeAddress(key, "ensRegistry", address(ensGate.registry()));
        vm.serializeAddress(key, "ensCredentialGate", address(ensGate));
        vm.serializeAddress(key, "humanGate", humanGate);
        vm.serializeUint(key, "fromBlock", block.number);
        vm.serializeString(key, "setVerifier", "pending: HumanGate owner calls setVerifier(allOfHumanGate)");
        string memory json = vm.serializeAddress(key, "allOfHumanGate", address(composite));
        if (!vm.exists(path)) vm.writeFile(path, "{}");
        vm.writeJson(json, path, string.concat(".", RECORD_KEY)); // read-modify-write of this one key
        vm.writeFile(path, string.concat(vm.readFile(path), "\n")); // keep the trailing newline
    }

    /// @notice Prints the one owner tx that switches funding to World + ENS, and the rollbacks.
    function printNextSteps(address humanGate, address worldGate, address composite) public view {
        console2.log("");
        if (humanGate.code.length > 0) {
            console2.log("HumanGate            ", humanGate);
            console2.log("  owner              ", IHumanGateAdmin(humanGate).owner());
            console2.log("  current verifier   ", IHumanGateAdmin(humanGate).verifier());
        }
        console2.log("NEXT (HumanGate owner, one tx) - funding then needs World ID AND a rentouts.eth name:");
        console2.log(
            string.concat(
                "  cast send ",
                vm.toString(humanGate),
                " \"setVerifier(address)\" ",
                vm.toString(composite),
                " --account <owner-keystore> --rpc-url sepolia"
            )
        );
        console2.log("ROLLBACK to World ID only:");
        console2.log(
            string.concat(
                "  cast send ",
                vm.toString(humanGate),
                " \"setVerifier(address)\" ",
                vm.toString(worldGate),
                " --account <owner-keystore> --rpc-url sepolia"
            )
        );
        console2.log(
            "ROLLBACK to an open gate (no checks): same command with 0x0000000000000000000000000000000000000000"
        );
    }
}
