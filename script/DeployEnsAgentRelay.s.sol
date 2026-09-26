// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {EnsAgentRelay, IJudgeArbiter, IJudgeSubnames} from "../src/EnsAgentRelay.sol";
import {ForgeContext, IVmForgeContext} from "./DeployEscrow.s.sol";

/// @notice Deploys EnsAgentRelay on Ethereum Sepolia: the contract that, once the human arbiter makes it
///         AIArbiter's agent, forwards proposals only from the holder of judge.rentouts.eth.
///         Deploying changes nothing by itself. Switching it on is the human's call, a separate tx:
///           cast send <aiArbiter> "setAgent(address)" <relay> --account rentouts-arbiter --rpc-url <rpc>
///         and rolling back is the same call with the judge EOA (0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA).
///         Signs with a Foundry keystore account (--account); never takes a raw private key.
///
///   Env: RELAY_AI_ARBITER  optional, default the live AIArbiter 0xC3D5...bdCb5
///        RELAY_SUBNAMES    optional, default the live RentoutsSubnames 0xd7bD...DFf60
///        RELAY_LABEL       optional, default "judge"
///
///   Dry run:  forge script script/DeployEnsAgentRelay.s.sol --rpc-url <rpc> --sender <deployer>
///   Deploy (also records the "sepoliaEnsAgentRelay" entry of deployments.json):
///             forge script script/DeployEnsAgentRelay.s.sol --rpc-url <rpc> \
///               --account rentouts-deployer --sender <deployer> --broadcast
contract DeployEnsAgentRelay is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address public constant DEFAULT_AI_ARBITER = 0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5;
    address public constant DEFAULT_SUBNAMES = 0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60;
    string public constant DEFAULT_LABEL = "judge";
    string public constant DEPLOYMENTS_FILE = "./deployments.json";
    string public constant RECORD_KEY = "sepoliaEnsAgentRelay";

    function run() external returns (EnsAgentRelay relay) {
        address arbiter = vm.envOr("RELAY_AI_ARBITER", DEFAULT_AI_ARBITER);
        address subnames = vm.envOr("RELAY_SUBNAMES", DEFAULT_SUBNAMES);
        string memory label = vm.envOr("RELAY_LABEL", DEFAULT_LABEL);
        address deployer = msg.sender;
        relay = deploy(deployer, arbiter, subnames, label);

        IVmForgeContext ctx = IVmForgeContext(address(vm));
        if (ctx.isContext(ForgeContext.ScriptBroadcast) || ctx.isContext(ForgeContext.ScriptResume)) {
            record(DEPLOYMENTS_FILE, deployer, relay);
            console2.log("recorded", DEPLOYMENTS_FILE, "(sepoliaEnsAgentRelay)");
        } else {
            console2.log("no --broadcast: simulation only, deployments.json not written");
        }
    }

    function deploy(address deployer, address arbiter, address subnames, string memory label)
        public
        returns (EnsAgentRelay relay)
    {
        require(block.chainid == SEPOLIA_CHAIN_ID, "DeployEnsAgentRelay: Ethereum Sepolia (11155111) only");
        require(deployer != DEFAULT_SENDER, "DeployEnsAgentRelay: pass --account <keystore> / --sender <address>");
        require(arbiter.code.length != 0, "DeployEnsAgentRelay: RELAY_AI_ARBITER has no code");
        require(subnames.code.length != 0, "DeployEnsAgentRelay: RELAY_SUBNAMES has no code");

        vm.startBroadcast(deployer);
        relay = new EnsAgentRelay(IJudgeArbiter(arbiter), IJudgeSubnames(subnames), label);
        vm.stopBroadcast();

        (bool ok, bytes memory ret) = arbiter.staticcall(abi.encodeWithSignature("agent()"));
        address agent = ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
        console2.log("EnsAgentRelay    ", address(relay));
        console2.log("AIArbiter        ", arbiter);
        console2.log("RentoutsSubnames ", subnames);
        console2.log("name             ", relay.name());
        console2.log("ENS judge now    ", relay.judge());
        console2.log("AIArbiter.agent()", agent);
        if (relay.judge() == address(0)) console2.log("WARNING: the name has no holder yet; register it before setAgent");
        else if (relay.judge() != agent) console2.log("WARNING: the ENS judge is not the current agent key");
        console2.log("switch on (human): cast send <aiArbiter> 'setAgent(address)' <relay>");
    }

    /// @notice Writes (or replaces) the "sepoliaEnsAgentRelay" entry, keeping every other entry.
    function record(string memory path, address deployer, EnsAgentRelay relay) public {
        string memory key = RECORD_KEY;
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "deployer", deployer);
        vm.serializeAddress(key, "aiArbiter", address(relay.arbiter()));
        vm.serializeAddress(key, "rentoutsSubnames", address(relay.subnames()));
        vm.serializeString(key, "name", relay.name());
        vm.serializeUint(key, "fromBlock", block.number);
        string memory json = vm.serializeAddress(key, "ensAgentRelay", address(relay));
        if (!vm.exists(path)) vm.writeFile(path, "{}");
        vm.writeJson(json, path, string.concat(".", RECORD_KEY));
        vm.writeFile(path, string.concat(vm.readFile(path), "\n"));
    }
}
