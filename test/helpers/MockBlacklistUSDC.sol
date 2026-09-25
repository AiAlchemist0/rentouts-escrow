// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice TEST-ONLY stand-in for Circle USDC's blacklist (FiatTokenV2_2): any transfer from, to,
///         or sent by a blacklisted address reverts. 6 decimals, anyone can mint or blacklist.
contract MockBlacklistUSDC is ERC20 {
    mapping(address account => bool) public isBlacklisted;

    error Blacklisted(address account);

    constructor() ERC20("Mock Blacklist USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blacklist(address account, bool on) external {
        isBlacklisted[account] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (isBlacklisted[from]) revert Blacklisted(from);
        if (isBlacklisted[to]) revert Blacklisted(to);
        if (isBlacklisted[msg.sender]) revert Blacklisted(msg.sender);
        super._update(from, to, value);
    }
}
