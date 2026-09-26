// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHumanGate} from "./interfaces/IHumanGate.sol";

/// @title AllOfHumanGate
/// @notice `IHumanGate` that is true only if EVERY one of its 1..4 gates says true. RentOuts uses it
///         as HumanGate's verifier to require both a World ID 4.0 verified human (WorldIdV4Gate) and
///         an active rentouts.eth credential (EnsCredentialGate) before a tenant can fund a lease.
///         Plugs into the live HumanGate with one `setVerifier` call: no RentEscrow redeploy.
/// @dev    - No owner, no storage: the gate list is fixed at construction (immutables).
///         - `isVerified` NEVER reverts. Each gate is asked with a low-level staticcall capped at
///           GATE_GAS that copies back at most 32 bytes; a revert, out-of-gas, short return data or
///           anything other than exactly `true` (1) counts as `false`. (A try/catch around
///           `gate.isVerified` would not be enough: malformed return data, e.g. a bool of 2, makes
///           the ABI decoder revert in THIS contract, outside the catch.)
///         - Fail closed: an AND of answers where every failure is `false` can never produce a
///           `true` the gates did not all give. Gas games by the caller can only turn a `true` into
///           `false` (funding reverts), never the reverse.
contract AllOfHumanGate is IHumanGate {
    uint256 public constant MAX_GATES = 4;
    /// @notice Gas forwarded to each gate. EnsCredentialGate makes two capped reads of its own
    ///         (2 x 100k cap, a few thousand used in practice), so this leaves it ample room.
    uint256 public constant GATE_GAS = 300_000;

    uint256 public immutable gateCount;
    IHumanGate internal immutable _gate0;
    IHumanGate internal immutable _gate1;
    IHumanGate internal immutable _gate2;
    IHumanGate internal immutable _gate3;

    error NoGates();
    error TooManyGates(uint256 count);
    error ZeroGate(uint256 index);
    error GateHasNoCode(address gate);
    error DuplicateGate(address gate);
    error SelfAsGate();
    error IndexOutOfRange(uint256 index);

    /// @param gates_ 1..4 distinct IHumanGate contracts, all of which must say yes
    constructor(address[] memory gates_) {
        uint256 n = gates_.length;
        if (n == 0) revert NoGates();
        if (n > MAX_GATES) revert TooManyGates(n);
        for (uint256 i; i < n; ++i) {
            address g = gates_[i];
            if (g == address(0)) revert ZeroGate(i);
            if (g == address(this)) revert SelfAsGate();
            if (g.code.length == 0) revert GateHasNoCode(g);
            for (uint256 j; j < i; ++j) {
                if (gates_[j] == g) revert DuplicateGate(g);
            }
        }
        gateCount = n;
        _gate0 = IHumanGate(gates_[0]);
        _gate1 = IHumanGate(n > 1 ? gates_[1] : address(0));
        _gate2 = IHumanGate(n > 2 ? gates_[2] : address(0));
        _gate3 = IHumanGate(n > 3 ? gates_[3] : address(0));
    }

    /// @notice The gate at `index` (0-based); reverts past `gateCount`.
    function gate(uint256 index) public view returns (IHumanGate) {
        if (index >= gateCount) revert IndexOutOfRange(index);
        if (index == 0) return _gate0;
        if (index == 1) return _gate1;
        if (index == 2) return _gate2;
        return _gate3;
    }

    /// @notice All gates, in order.
    function gates() external view returns (address[] memory list) {
        list = new address[](gateCount);
        for (uint256 i; i < list.length; ++i) {
            list[i] = address(gate(i));
        }
    }

    /// @inheritdoc IHumanGate
    /// @notice True iff every gate returns exactly `true` for `account`.
    function isVerified(address account) external view returns (bool) {
        uint256 n = gateCount;
        if (!_ask(_gate0, account)) return false;
        if (n > 1 && !_ask(_gate1, account)) return false;
        if (n > 2 && !_ask(_gate2, account)) return false;
        if (n > 3 && !_ask(_gate3, account)) return false;
        return true;
    }

    /// @dev `g.isVerified(account)` with a gas cap and at most 32 bytes of return data copied; only an
    ///      exact ABI `true` (a 32-byte word equal to 1) counts.
    function _ask(IHumanGate g, address account) internal view returns (bool yes) {
        bytes4 selector = IHumanGate.isVerified.selector;
        uint256 gasCap = GATE_GAS;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 0x04), account)
            let success := staticcall(gasCap, g, ptr, 0x24, ptr, 0x20)
            yes := and(success, and(iszero(lt(returndatasize(), 0x20)), eq(mload(ptr), 1)))
        }
    }
}
