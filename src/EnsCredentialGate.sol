// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHumanGate} from "./interfaces/IHumanGate.sol";

/// @dev The two reads EnsCredentialGate makes on the live ENS side. Declared here because the ENS
///      contracts live in the separate `ens/` Foundry project (RentoutsSubnames, ENSv2 UserRegistry).
interface IRentoutsSubnamesReader {
    /// @notice `alice` for the holder of `alice.rentouts.eth`; "" if none (revoke clears it).
    function labelOf(address holder) external view returns (string memory);
    /// @notice The ENSv2 UserRegistry the subnames live in (immutable in RentoutsSubnames).
    function registry() external view returns (address);
}

interface IEnsRegistryOwner {
    /// @notice Current owner of `labelId = uint256(keccak256(label))`; address(0) once the name is
    ///         unregistered or expired.
    function getOwner(uint256 anyId) external view returns (address);
}

/// @title EnsCredentialGate
/// @notice `IHumanGate` that answers "does this wallet hold an ACTIVE rentouts.eth credential?".
///         Active means both:
///           1. RentoutsSubnames still maps the wallet to a label (`labelOf` is non-empty; `revoke`
///              clears it), and
///           2. ENS itself still says the wallet owns that name: the ENSv2 registry's
///              `getOwner(uint256(keccak256(label)))` is the wallet (this catches a name that was
///              unregistered or expired outside RentoutsSubnames).
///         Combined with the World ID gate in {AllOfHumanGate}, funding a lease needs a verified
///         human AND a live ENS credential: remove either and fundLease reverts NotVerifiedHuman.
/// @dev    - No owner, no storage, nothing to configure: `subnames` and `registry` are immutable.
///         - `isVerified` NEVER reverts. Every external read is a low-level staticcall with a gas cap
///           and a bounded return-data copy, and the result is decoded by hand; any failure (revert,
///           out of gas, no code, short / oversized / malformed return data) is `false`. A plain
///           try/catch would not be enough: Solidity decodes the return data in the CALLER, so
///           malformed return data would still revert past the catch.
///         - Fail closed: nothing that goes wrong here can turn a `false` into a `true`.
contract EnsCredentialGate is IHumanGate {
    /// @notice Gas forwarded to each external read (labelOf / getOwner). Both are a few thousand gas
    ///         on Sepolia; the cap only bounds what a broken dependency can burn.
    uint256 public constant CALL_GAS = 100_000;
    /// @notice Longest label accepted from `labelOf` (DNS wire format caps a label at 255 bytes;
    ///         RentoutsSubnames itself only issues 3-32 character labels).
    uint256 public constant MAX_LABEL_LENGTH = 255;

    /// @notice The live RentoutsSubnames (issues `<label>.rentouts.eth`).
    IRentoutsSubnamesReader public immutable subnames;
    /// @notice ENSv2 UserRegistry holding the subnames (read from `subnames.registry()` at deploy).
    IEnsRegistryOwner public immutable registry;

    error NoCode(address account);
    error BadRegistry(address subnames);

    constructor(address subnames_) {
        if (subnames_.code.length == 0) revert NoCode(subnames_);
        address registry_ = IRentoutsSubnamesReader(subnames_).registry();
        if (registry_ == address(0)) revert BadRegistry(subnames_);
        if (registry_.code.length == 0) revert NoCode(registry_);
        subnames = IRentoutsSubnamesReader(subnames_);
        registry = IEnsRegistryOwner(registry_);
    }

    /// @inheritdoc IHumanGate
    /// @notice True iff `account` holds an active rentouts.eth credential (see the contract notice).
    function isVerified(address account) external view returns (bool) {
        if (account == address(0)) return false;
        (bool ok, uint256 labelId) = _labelIdOf(account);
        if (!ok) return false;
        return _ownerOf(labelId) == account;
    }

    /// @dev `uint256(keccak256(labelOf(account)))`, or ok = false if there is no label or the call /
    ///      its return data is bad. Expects the canonical ABI encoding of one `string`:
    ///      [0x20][len][data padded to 32 bytes].
    function _labelIdOf(address account) internal view returns (bool ok, uint256 labelId) {
        address target = address(subnames);
        bytes4 selector = IRentoutsSubnamesReader.labelOf.selector;
        uint256 gasCap = CALL_GAS;
        // head (offset + length words) + the longest label padded to whole words: 64 + 256
        uint256 maxReturn = 320;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 0x04), account)
            let success := staticcall(gasCap, target, ptr, 0x24, 0, 0)
            let size := returndatasize()
            // never copy more than maxReturn bytes (no return-data bomb)
            if and(success, and(iszero(lt(size, 0x40)), iszero(gt(size, maxReturn)))) {
                returndatacopy(ptr, 0, size)
                let offset := mload(ptr)
                let len := mload(add(ptr, 0x20))
                if and(
                    eq(offset, 0x20),
                    and(gt(len, 0), and(iszero(gt(len, MAX_LABEL_LENGTH)), iszero(gt(add(0x40, len), size))))
                ) {
                    labelId := keccak256(add(ptr, 0x40), len)
                    ok := 1
                }
            }
        }
    }

    /// @dev `registry.getOwner(labelId)`, or address(0) on any failure / malformed return.
    function _ownerOf(uint256 labelId) internal view returns (address owner) {
        address target = address(registry);
        bytes4 selector = IEnsRegistryOwner.getOwner.selector;
        uint256 gasCap = CALL_GAS;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 0x04), labelId)
            // copies at most 32 bytes back, whatever the callee returns
            let success := staticcall(gasCap, target, ptr, 0x24, ptr, 0x20)
            if and(success, iszero(lt(returndatasize(), 0x20))) {
                let word := mload(ptr)
                // a well-formed address has its top 12 bytes clear
                if iszero(shr(160, word)) { owner := word }
            }
        }
    }
}
