// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRentEscrow} from "./interfaces/IRentEscrow.sol";

/// @notice What the relay reads from RentoutsSubnames (ens/src/RentoutsSubnames.sol, live on Sepolia).
interface IJudgeSubnames {
    /// @notice Current holder of a label, keyed by labelId = uint256(keccak256(label)); zero once revoked.
    function holderOf(uint256 labelId) external view returns (address);
    /// @notice The ENSv2 UserRegistry that holds the subnames.
    function registry() external view returns (address);
    /// @notice e.g. "rentouts.eth".
    function parentName() external view returns (string memory);
}

/// @notice The ENSv2 UserRegistry view the relay needs: the owner of a live (registered, unexpired) name.
interface IJudgeRegistry {
    function getOwner(uint256 anyId) external view returns (address);
}

/// @notice The AIArbiter calls the relay makes (src/AIArbiter.sol).
interface IJudgeArbiter {
    function propose(uint256 leaseId, uint16 tenantBps, bytes32 rulingHash, uint16 confidenceBps, string calldata summary)
        external;
    function escrow() external view returns (IRentEscrow);
}

/// @title EnsAgentRelay
/// @notice Makes an ENS name the AI judge's on-chain credential. The human arbiter sets this contract as
///         AIArbiter's `agent` (AIArbiter.setAgent, no redeploy); from then on a proposal reaches AIArbiter
///         only if its sender holds `<label>.<parent>` (judge.rentouts.eth) right now:
///         - RentoutsSubnames.holderOf(labelId) == msg.sender (RentOuts issued it and has not revoked it), and
///         - the ENS registry's getOwner(labelId) == msg.sender (the name is still registered and unexpired).
///         The key that may judge is therefore whoever ENS says `judge.rentouts.eth` is. Revoking the name
///         (RentoutsSubnames.revoke) stops the AI at once; the name is soulbound, so it cannot be sold or
///         moved to another key. Labels are single-use in RentoutsSubnames, so a revoked judge label stays
///         dead: a new judge key needs a new label and a new relay (or setAgent back to a plain key).
///
///         No owner, nothing mutable: arbiter, subnames, registry and label are fixed at deploy. The
///         relay only ever calls AIArbiter.propose, so AIArbiter's invariant AI-1 is untouched, and it
///         keeps AIArbiter's own rule that a party to the lease cannot judge it (applied to the judge
///         key, since AIArbiter now sees the relay as the sender).
///
///         Rollback: the human calls AIArbiter.setAgent(<judge EOA>) and the judge sends directly again.
/// @dev    Built for ETHGlobal Tokyo 2026 (Ethereum Sepolia). Testnet only, not audited.
contract EnsAgentRelay {
    IJudgeArbiter public immutable arbiter;
    IJudgeSubnames public immutable subnames;
    IJudgeRegistry public immutable registry;
    /// @notice uint256(keccak256(label)), the id RentoutsSubnames and the registry key the name by.
    uint256 public immutable labelId;
    /// @notice The judge's label, e.g. "judge". Set once in the constructor.
    string public label;

    /// @notice A proposal the ENS judge made through the relay (AIArbiter's Proposed names the relay).
    event RelayedProposal(uint256 indexed leaseId, address indexed judge, string name, uint16 tenantBps, bytes32 rulingHash);

    error ZeroAddress();
    error InvalidLabel();
    /// @notice The caller is not RentoutsSubnames' holder of the judge label (`holder`: who is, or zero).
    error NotEnsJudge(address caller, address holder);
    /// @notice RentoutsSubnames names the caller, but the ENS registry does not (unregistered or expired).
    error EnsNameNotLive(address caller, address registryOwner);
    /// @notice The judge key is the lease's tenant or landlord.
    error PartyCannotArbitrate(uint256 leaseId, address judge);

    constructor(IJudgeArbiter arbiter_, IJudgeSubnames subnames_, string memory label_) {
        if (address(arbiter_) == address(0) || address(subnames_) == address(0)) revert ZeroAddress();
        if (bytes(label_).length == 0) revert InvalidLabel();
        address registry_ = subnames_.registry();
        if (registry_ == address(0)) revert ZeroAddress();
        arbiter = arbiter_;
        subnames = subnames_;
        registry = IJudgeRegistry(registry_);
        label = label_;
        labelId = uint256(keccak256(bytes(label_)));
    }

    /// @notice The key ENS currently names as the judge, or address(0) if none (revoked, never issued,
    ///         or the registry no longer agrees). Only this address can propose through the relay.
    function judge() public view returns (address holder) {
        holder = subnames.holderOf(labelId);
        if (holder != address(0) && registry.getOwner(labelId) != holder) holder = address(0);
    }

    function isJudge(address account) external view returns (bool) {
        return account != address(0) && judge() == account;
    }

    /// @notice The judge's full ENS name, e.g. "judge.rentouts.eth".
    function name() public view returns (string memory) {
        return string.concat(label, ".", subnames.parentName());
    }

    /// @notice Same signature as AIArbiter.propose. Forwards only for the current ENS judge.
    function propose(uint256 leaseId, uint16 tenantBps, bytes32 rulingHash, uint16 confidenceBps, string calldata summary)
        external
    {
        address holder = subnames.holderOf(labelId);
        if (holder == address(0) || holder != msg.sender) revert NotEnsJudge(msg.sender, holder);
        address owner = registry.getOwner(labelId);
        if (owner != msg.sender) revert EnsNameNotLive(msg.sender, owner);

        IRentEscrow e = arbiter.escrow();
        if (address(e) != address(0)) {
            IRentEscrow.Lease memory l = e.getLease(leaseId);
            if (msg.sender == l.tenant || msg.sender == l.landlord) revert PartyCannotArbitrate(leaseId, msg.sender);
        }
        emit RelayedProposal(leaseId, msg.sender, name(), tenantBps, rulingHash);
        arbiter.propose(leaseId, tenantBps, rulingHash, confidenceBps, summary);
    }
}
