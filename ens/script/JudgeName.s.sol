// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {DeployEns} from "./DeployEns.s.sol";
import {RentoutsSubnames} from "../src/RentoutsSubnames.sol";
import {IUserRegistry} from "../src/interfaces/IENSv2.sol";

interface IAIArbiterAgent {
    function agent() external view returns (address);
}

/// @notice `judge.<parent>.eth` (judge.rentouts.eth): an ENS name for the AI dispute judge, the key that
///         AIArbiter lets propose rulings. Same state file, env and seams as DeployEns; run with --sig.
///
///           judgeStatus()   read-only report
///           registerJudge() the ISSUER mints judge.<parent> to AIArbiter.agent() (read on chain, never
///                           hard-coded). RentoutsSubnames writes its addr + credential records. If the
///                           chain already shows it (a re-run), it sends nothing and, with BROADCAST=true,
///                           records `judgeHolder` in the state file: the file only names what landed.
///           judgeProfile()  the JUDGE KEY sets its own profile texts (description, url).
///                           RentoutsSubnames.setProfileText is holder-only, so this is a second signer.
///
///         If AIArbiter.agent() is already a contract (the EnsAgentRelay in src/ of the root project, which
///         forwards only for the holder of this name), registerJudge reports the relay's judge and stops.
///
///         env: ENS_PARENT_LABEL (rentouts), AI_ARBITER (default: the live Sepolia AIArbiter), ENS_STATE,
///              BROADCAST, JUDGE_URL, JUDGE_DESCRIPTION.
contract JudgeName is DeployEns {
    string public constant JUDGE_LABEL = "judge";
    address public constant SEPOLIA_AI_ARBITER = 0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5;
    string public constant REPO_URL = "https://github.com/AiAlchemist0/rentouts-escrow";

    function judgeStatus() public {
        _init();
        RentoutsSubnames sub = _existingSubnames(_load());
        address arbiter = _arbiter();
        address agent = IAIArbiterAgent(arbiter).agent();
        uint256 id = _judgeId();
        string memory name = judgeName();
        address resolved = _urAddr(name);
        console2.log("judge name        :", name);
        console2.log("AIArbiter         :", arbiter);
        console2.log("AIArbiter.agent() :", agent);
        console2.log("holderOf(judge)   :", sub.holderOf(id));
        console2.log("registry owner    :", IUserRegistry(address(sub.registry())).getOwner(id));
        console2.log("retired           :", sub.retired(id));
        console2.log("UR addr           :", resolved);
        console2.log("UR description    :", _urText(name, "description"));
        console2.log("UR url            :", _urText(name, "url"));
        console2.log("UR rentouts.status:", _urText(name, "rentouts.status"));
        console2.log("name == agent     :", resolved != address(0) && resolved == agent);
    }

    function registerJudge() external {
        _init();
        State memory s = _load();
        RentoutsSubnames sub = _existingSubnames(s);
        address arbiter = _arbiter();
        address agent = IAIArbiterAgent(arbiter).agent();
        require(agent != address(0), "AIArbiter.agent() is zero (AI proposals are off): nothing to name");
        uint256 id = _judgeId();
        address current = sub.holderOf(id);

        if (agent.code.length != 0) {
            // The relay is the agent: the name belongs to the EOA the relay forwards for, not the relay.
            (bool ok, address relayed) = _readAddress(agent, abi.encodeWithSignature("judge()"));
            require(ok, "AIArbiter.agent() is a contract that is not an EnsAgentRelay: refusing to name it");
            console2.log("AIArbiter.agent() is an EnsAgentRelay; its judge:", relayed);
            require(relayed != address(0) && relayed == current, "the relay names no live judge: register the judge EOA first");
            _recordJudge(s, current);
            return;
        }
        if (current == agent) {
            console2.log("already registered:", judgeName(), "->", agent);
            _recordJudge(s, agent);
            return;
        }
        require(current == address(0), string.concat("judge label is held by ", vm.toString(current), ", not the agent"));
        require(!sub.retired(id), "judge label was revoked (labels are single-use): choose another label");
        require(IUserRegistry(address(sub.registry())).getExpiry(id) == 0, "judge label is taken in the registry");
        require(
            bytes(sub.labelOf(agent)).length == 0,
            string.concat("the agent already holds ", sub.nameOf(agent), " (one name per address)")
        );
        require(sub.isIssuer(me), "sender is not a RentoutsSubnames issuer");

        vm.startBroadcast(me);
        sub.register(JUDGE_LABEL, agent);
        vm.stopBroadcast();
        console2.log("registered:", judgeName(), "->", agent);
        console2.log("(state is recorded by a re-run once the chain shows it)");
    }

    function judgeProfile() external {
        _init();
        RentoutsSubnames sub = _existingSubnames(_load());
        address holder = sub.holderOf(_judgeId());
        require(holder != address(0), "judge name not registered yet: run registerJudge() first");
        require(
            holder == me,
            string.concat(
                "only the holder sets profile texts (RentoutsSubnames.setProfileText): --sender ", vm.toString(holder)
            )
        );
        string memory name = judgeName();
        string memory description = _envOr("JUDGE_DESCRIPTION", judgeDescription(_arbiter()));
        string memory url = _envOr("JUDGE_URL", REPO_URL);
        bool setDescription = !_eq(_urText(name, "description"), description);
        bool setUrl = !_eq(_urText(name, "url"), url);
        if (!setDescription && !setUrl) {
            console2.log("profile texts already set");
            return;
        }
        vm.startBroadcast(me);
        if (setDescription) sub.setProfileText(JUDGE_LABEL, "description", description);
        if (setUrl) sub.setProfileText(JUDGE_LABEL, "url", url);
        vm.stopBroadcast();
        console2.log("description:", description);
        console2.log("url        :", url);
    }

    function judgeName() public view returns (string memory) {
        return string.concat(JUDGE_LABEL, ".", _parentName());
    }

    function judgeDescription(address arbiter) public view returns (string memory) {
        return string.concat(
            "RentOuts AI dispute judge: proposes rulings on AIArbiter ",
            vm.toString(arbiter),
            "; humans can appeal and override"
        );
    }

    /// @notice True when `name` forward-resolves (Universal Resolver) to `expected`, and to nothing else.
    ///         The same check the off-chain judge and the app make before trusting the name.
    function resolvesTo(string memory name, address expected) public view returns (bool) {
        address a = _urAddr(name);
        return a != address(0) && a == expected;
    }

    function _judgeId() internal pure returns (uint256) {
        return uint256(keccak256(bytes(JUDGE_LABEL)));
    }

    function _arbiter() internal view returns (address a) {
        a = _envOr("AI_ARBITER", SEPOLIA_AI_ARBITER);
        require(a.code.length != 0, "AI_ARBITER has no code on this chain");
    }

    function _recordJudge(State memory s, address holder) internal {
        if (s.judgeHolder == holder) return;
        s.judgeHolder = holder;
        _save(s);
    }
}
