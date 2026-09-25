// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AIArbiter} from "../src/AIArbiter.sol";
import {ForgeContext, IVmForgeContext} from "./DeployEscrow.s.sol";

/// @notice Deploys AIArbiter to Ethereum Sepolia. RentEscrow's arbiter is immutable, so this runs
///         FIRST; then DeployEscrow with ESCROW_ARBITER = the AIArbiter address; then the human
///         arbiter binds the escrow once:
///           cast send <aiArbiter> "bindEscrow(address)" <rentEscrow> --account <human keystore> --rpc-url sepolia
///         Signs with a Foundry keystore account (--account); never takes a raw private key.
///
///   Env: SEPOLIA_RPC_URL
///        AI_AGENT             required. The AI judge service address (judge/, keystore JUDGE_KEYSTORE).
///                             It can only propose rulings.
///        AI_HUMAN             optional. Human arbiter (EOA or Safe): resolves directly, overrides,
///                             handles appeals, sets the agent / window. Default: the team's human
///                             arbiter EOA 0x798b01Cef62b889943Ce1D3C5011a755B297e486.
///        AI_CHALLENGE_WINDOW  optional. Seconds a proposal stays appealable (60 .. 30 days).
///                             Default 120 (live demo); use days in production.
///
///   Dry run (simulation only, records nothing):
///     forge script script/DeployAIArbiter.s.sol --rpc-url sepolia --sender <deployer>
///   Deploy (also records the "sepoliaAIArbiter" entry of deployments.json):
///     forge script script/DeployAIArbiter.s.sol --rpc-url sepolia \
///       --account <keystore-name> --sender <deployer> --broadcast
contract DeployAIArbiter is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address public constant DEFAULT_HUMAN = 0x798b01Cef62b889943Ce1D3C5011a755B297e486;
    uint256 public constant DEFAULT_CHALLENGE_WINDOW = 120;
    /// @dev Same repo-wide record as DeployEscrow ("baseSepolia", "sepolia"). A top-level key of its
    ///      own, because DeployEscrow rewrites the whole "sepolia" entry and runs AFTER this script.
    string public constant DEPLOYMENTS_FILE = "./deployments.json";
    string public constant RECORD_KEY = "sepoliaAIArbiter";

    function run() external returns (AIArbiter arbiter) {
        address human = vm.envOr("AI_HUMAN", DEFAULT_HUMAN);
        address agent = vm.envAddress("AI_AGENT");
        uint256 window = vm.envOr("AI_CHALLENGE_WINDOW", DEFAULT_CHALLENGE_WINDOW);

        address deployer = msg.sender; // the --sender / --account address
        arbiter = deploy(deployer, human, agent, window);

        // Record only when forge really broadcasts (--broadcast / --resume), never in a dry run or a
        // test (same rule as DeployEscrow; a BROADCAST env var alone does nothing).
        IVmForgeContext ctx = IVmForgeContext(address(vm));
        if (ctx.isContext(ForgeContext.ScriptBroadcast) || ctx.isContext(ForgeContext.ScriptResume)) {
            record(DEPLOYMENTS_FILE, deployer, human, agent, window, address(arbiter));
            console2.log("recorded", DEPLOYMENTS_FILE, "(sepoliaAIArbiter)");
        } else {
            console2.log("no --broadcast: simulation only, deployments.json not written");
        }
    }

    /// @notice Writes (or replaces) the "sepoliaAIArbiter" entry of the deployments file at `path`,
    ///         keeping every other entry. Creates the file if it is missing.
    function record(
        string memory path,
        address deployer,
        address human,
        address agent,
        uint256 challengeWindow,
        address aiArbiter
    ) public {
        string memory key = RECORD_KEY;
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "deployer", deployer);
        vm.serializeAddress(key, "human", human);
        vm.serializeAddress(key, "agent", agent);
        vm.serializeUint(key, "challengeWindow", challengeWindow);
        // A block at or before the deploy: where judge/ starts scanning for Evidence / DisputeOpened.
        vm.serializeUint(key, "fromBlock", block.number);
        string memory json = vm.serializeAddress(key, "aiArbiter", aiArbiter);
        if (!vm.exists(path)) vm.writeFile(path, "{}");
        vm.writeJson(json, path, string.concat(".", RECORD_KEY)); // read-modify-write of this one key
        vm.writeFile(path, string.concat(vm.readFile(path), "\n")); // keep the trailing newline
    }

    /// @notice Checks the config, then deploys as `deployer`. Separate from run() so
    ///         test/DeployAIArbiter.t.sol can exercise every check without env vars.
    function deploy(address deployer, address human, address agent, uint256 challengeWindow)
        public
        returns (AIArbiter arbiter)
    {
        require(block.chainid == SEPOLIA_CHAIN_ID, "DeployAIArbiter: Ethereum Sepolia (11155111) only");
        require(deployer != DEFAULT_SENDER, "DeployAIArbiter: pass --account <keystore> / --sender <address>");
        require(human != address(0), "DeployAIArbiter: AI_HUMAN is zero");
        require(agent != address(0), "DeployAIArbiter: AI_AGENT is required (the judge service address)");
        require(agent != human, "DeployAIArbiter: AI_AGENT must not be AI_HUMAN");
        // The deployer is the demo landlord (DeployEscrow allowlists it), and AIArbiter refuses to let
        // the agent or the human rule on its own lease: keep both roles off the deployer.
        require(human != deployer, "DeployAIArbiter: AI_HUMAN must not be the deployer (the demo landlord)");
        require(agent != deployer, "DeployAIArbiter: AI_AGENT must not be the deployer (the demo landlord)");
        require(
            challengeWindow >= 60 && challengeWindow <= 30 days,
            "DeployAIArbiter: AI_CHALLENGE_WINDOW must be 60 s .. 30 days"
        );

        vm.startBroadcast(deployer);
        // casting to 'uint32' is safe because challengeWindow <= 30 days (checked above)
        // forge-lint: disable-next-line(unsafe-typecast)
        arbiter = new AIArbiter(human, agent, uint32(challengeWindow));
        vm.stopBroadcast();

        console2.log("chainId          ", block.chainid);
        console2.log("deployer         ", deployer);
        console2.log("human arbiter    ", human, human.code.length > 0 ? "(contract)" : "(EOA)");
        console2.log("agent (AI judge) ", agent);
        console2.log("challenge window ", challengeWindow, "s");
        console2.log("AIArbiter        ", address(arbiter));
        console2.log("next: deploy RentEscrow with ESCROW_ARBITER =", address(arbiter));
        console2.log("then (human):    cast send <aiArbiter> 'bindEscrow(address)' <rentEscrow>");
    }
}
