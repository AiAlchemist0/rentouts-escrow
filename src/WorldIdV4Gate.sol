// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IHumanGate} from "./interfaces/IHumanGate.sol";

/// @title WorldIdV4Gate
/// @notice Sepolia `IHumanGate` for World ID 4.0. World App issues a 4.0 Proof of Human. World
///         checks that proof at `POST /api/v4/verify/{rp_id}` (there is no World ID 4.0 verifier
///         on Ethereum Sepolia). This contract then records the wallet: the RentOuts RP signer
///         signs `(chainId, this, actionHash, account, nullifier, deadline)` and anyone may submit
///         that signature. `isVerified` is true only after that. Plug it into the deployed
///         `HumanGate` with `setVerifier`. It holds no tokens and cannot move escrow funds.
/// @dev    `actionHash` is World ID's `hash_to_field(utf8(action))`: `uint256(keccak256(action)) >> 8`.
contract WorldIdV4Gate is IHumanGate {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @notice Address whose World ID 4.0 signing key attests successful `/api/v4/verify` results.
    address public immutable signer;

    /// @notice Field-reduced action id. For RentOuts this is `fund-lease`.
    bytes32 public immutable actionHash;

    mapping(uint256 nullifier => bool used) public nullifierUsed;
    mapping(address account => bool) private _verified;

    event HumanRegistered(address indexed account, uint256 nullifier);

    error ZeroAccount();
    error ZeroSigner();
    error Expired();
    error InvalidNullifier();
    error BadSigner();

    constructor(address signer_, string memory action) {
        if (signer_ == address(0)) revert ZeroSigner();
        signer = signer_;
        actionHash = bytes32(uint256(keccak256(bytes(action))) >> 8);
    }

    /// @notice Record `account` as a verified human for this action. The signature is from `signer`.
    function register(address account, uint256 nullifier, uint256 deadline, bytes calldata signature) external {
        if (account == address(0)) revert ZeroAccount();
        if (block.timestamp > deadline) revert Expired();
        if (nullifierUsed[nullifier]) revert InvalidNullifier();

        bytes32 structHash = keccak256(abi.encode(block.chainid, address(this), actionHash, account, nullifier, deadline));
        address recovered = structHash.toEthSignedMessageHash().recover(signature);
        if (recovered != signer) revert BadSigner();

        nullifierUsed[nullifier] = true;
        _verified[account] = true;
        emit HumanRegistered(account, nullifier);
    }

    /// @inheritdoc IHumanGate
    function isVerified(address account) external view returns (bool) {
        return _verified[account];
    }
}
