// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LeaseShare1155
/// @notice Tokenized rental-lease / deposit shares as a real-world asset (RWA).
///         `tokenId == leaseId`. Every share is subject to **compliance-aware
///         transfer logic**: only allowlisted (e.g. KYC/eligibility-approved)
///         addresses may receive shares. This is the minimal, demoable cut of
///         RentOuts' Stage-3 investor surface (permissioned ERC-1155 lease shares).
/// @dev    Built for ETHGlobal Tokyo 2026 — Curvegrid "Best RWA Tokenization" track.
contract LeaseShare1155 is ERC1155, Ownable {
    /// @notice Total shares minted per lease (tokenId => amount).
    mapping(uint256 => uint256) public totalSupply;

    /// @notice Compliance allowlist — only these addresses may hold/receive shares.
    mapping(address => bool) public allowlisted;

    /// @notice Address permitted to mint (the escrow / issuer). Owner can always mint.
    address public minter;

    event Allowlisted(address indexed account, bool allowed);
    event MinterUpdated(address indexed minter);
    event ShareMinted(uint256 indexed leaseId, address indexed to, uint256 amount);

    error NotAllowlisted(address account);
    error NotMinter(address caller);

    constructor(address initialOwner, string memory uri_) ERC1155(uri_) Ownable(initialOwner) {
        // The issuer/owner is allowlisted by default so it can custody freshly minted shares.
        allowlisted[initialOwner] = true;
        emit Allowlisted(initialOwner, true);
    }

    /// @notice Add or remove an address from the compliance allowlist.
    function setAllowlist(address account, bool allowed) external onlyOwner {
        allowlisted[account] = allowed;
        emit Allowlisted(account, allowed);
    }

    /// @notice Set the escrow/issuer address permitted to mint lease shares.
    function setMinter(address minter_) external onlyOwner {
        minter = minter_;
        emit MinterUpdated(minter_);
    }

    /// @notice Mint a tokenized share of a lease (tokenId == leaseId) to an approved holder.
    /// @dev    Callable by the escrow (`minter`) or the owner. Recipient must be allowlisted.
    function mintShare(uint256 leaseId, address to, uint256 amount) external {
        if (msg.sender != minter && msg.sender != owner()) revert NotMinter(msg.sender);
        totalSupply[leaseId] += amount;
        emit ShareMinted(leaseId, to, amount);
        _mint(to, leaseId, amount, ""); // recipient allowlist enforced in _update
    }

    /// @dev OZ v5 hook for ALL balance changes — mint, single transfer, and
    ///      batch transfer all route through here, so the allowlist covers every
    ///      path. This is the compliance-aware transfer logic. The `to == 0`
    ///      branch keeps burns valid should a burn entrypoint be added later.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
    {
        if (to != address(0) && !allowlisted[to]) revert NotAllowlisted(to);
        super._update(from, to, ids, values);
    }
}
