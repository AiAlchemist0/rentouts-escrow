// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHumanGate} from "./interfaces/IHumanGate.sol";
import {IWorldID} from "./interfaces/IWorldID.sol";

/// @title WorldHumanVerifier
/// @notice Proof-of-personhood verifier for {HumanGate}. A wallet proves it controls a unique
///         World ID (Orb) by submitting an IDKit proof whose signal is that wallet. After the
///         World ID Router accepts the proof, {isVerified} returns true for that address, so
///         RentEscrow's deployed HumanGate can start requiring it with one `setVerifier` call.
///         Nothing here is wired into the escrow until the gate owner does that. This contract
///         holds no tokens and cannot move escrow funds.
/// @dev    External nullifier is `hashToField(abi.encodePacked(hashToField(appId), action))`,
///         the same derivation World ID uses, so IDKit proofs for this app id + action verify.
contract WorldHumanVerifier is IHumanGate {
    /// @notice Orb credential. The only group the World ID Router verifies on-chain.
    uint256 public constant GROUP_ID = 1;

    IWorldID public immutable worldIdRouter;

    /// @notice Scopes proofs to this app + action. A proof for another app will not verify.
    uint256 public immutable externalNullifierHash;

    /// @notice Nullifiers already consumed. One human, one verification for this action.
    mapping(uint256 nullifierHash => bool used) public nullifierHashes;

    /// @notice Wallets that have proved personhood.
    mapping(address account => bool) private _verified;

    event HumanVerified(address indexed account, uint256 nullifierHash);

    error ZeroAccount();
    error AlreadyVerified(address account);
    error InvalidNullifier();

    /// @param router World ID Router for this chain (Ethereum Sepolia: 0x469449f2…2157).
    /// @param appId  World Developer Portal app id (e.g. `app_staging_…`).
    /// @param action Action name configured for that app (e.g. `fund-lease`).
    constructor(IWorldID router, string memory appId, string memory action) {
        worldIdRouter = router;
        externalNullifierHash = _hashToField(abi.encodePacked(_hashToField(bytes(appId)), action));
    }

    /// @notice Verify an Orb proof bound to `account` and mark that wallet as a unique human.
    /// @param account Wallet that must match the proof signal (the tenant who will fund).
    /// @param root Merkle root from IDKit.
    /// @param nullifierHash Nullifier from IDKit. Reused nullifiers revert.
    /// @param proof 8-word zk proof from IDKit.
    function verify(address account, uint256 root, uint256 nullifierHash, uint256[8] calldata proof) external {
        if (account == address(0)) revert ZeroAccount();
        if (_verified[account]) revert AlreadyVerified(account);
        if (nullifierHashes[nullifierHash]) revert InvalidNullifier();

        worldIdRouter.verifyProof(
            root, GROUP_ID, _hashToField(abi.encodePacked(account)), nullifierHash, externalNullifierHash, proof
        );

        nullifierHashes[nullifierHash] = true;
        _verified[account] = true;
        emit HumanVerified(account, nullifierHash);
    }

    /// @inheritdoc IHumanGate
    function isVerified(address account) external view returns (bool) {
        return _verified[account];
    }

    /// @dev Field element from keccak256, matching World ID's `hashToField` (drop the top byte).
    function _hashToField(bytes memory data) internal pure returns (uint256) {
        return uint256(keccak256(data)) >> 8;
    }
}
