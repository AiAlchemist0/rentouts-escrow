// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHumanGate} from "./interfaces/IHumanGate.sol";

/// @title HumanGate
/// @notice The seam between RentEscrow and a proof-of-personhood verifier (World ID). RentEscrow
///         takes this gate's address once, as an immutable constructor argument, and asks it
///         `isVerified(tenant)` in fundLease. The gate forwards the question to `verifier`, which
///         the owner can set or swap later, so World can be plugged in (or replaced) without
///         redeploying the escrow. While `verifier` is address(0) the gate is open: everyone passes.
/// @dev    What the owner can and cannot do:
///         - It decides only who may FUND NEW leases, by choosing the verifier.
///         - It can never move, freeze or redirect funds. The gate holds no tokens and has no role in
///           RentEscrow beyond this yes/no answer; claimRent, closeLease, openDispute and
///           resolveDispute never consult it, so leases that are already funded run to the end
///           whatever the verifier says.
///         - A verifier that reverts makes fundLease revert (fail closed); setting the verifier back
///           to address(0) reopens funding.
contract HumanGate is IHumanGate, Ownable {
    /// @notice Where isVerified is forwarded to; address(0) = open gate (everyone is verified).
    IHumanGate public verifier;

    event VerifierUpdated(address indexed previousVerifier, address indexed newVerifier);

    /// @notice A non-zero verifier must be a contract (an EOA would make every isVerified revert).
    error VerifierHasNoCode(address verifier);

    /// @param initialOwner who may set the verifier (the RentOuts deployer on testnet)
    /// @param verifier_    initial verifier, or address(0) to start open
    constructor(address initialOwner, address verifier_) Ownable(initialOwner) {
        _setVerifier(verifier_);
    }

    /// @notice Points the gate at a new verifier, or at address(0) to open it. Owner only.
    function setVerifier(address newVerifier) external onlyOwner {
        _setVerifier(newVerifier);
    }

    /// @inheritdoc IHumanGate
    function isVerified(address account) external view returns (bool) {
        IHumanGate v = verifier;
        return address(v) == address(0) || v.isVerified(account);
    }

    function _setVerifier(address newVerifier) internal {
        if (newVerifier != address(0) && newVerifier.code.length == 0) revert VerifierHasNoCode(newVerifier);
        emit VerifierUpdated(address(verifier), newVerifier);
        verifier = IHumanGate(newVerifier);
    }
}
