// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev TEST-ONLY misbehaving dependencies for AllOfHumanGate / EnsCredentialGate. Each one can
///      answer normally or: revert, return nothing, return short / malformed / oversized data, or
///      burn all the gas it is given. The gates under test must turn every failure into `false`.
enum Mode {
    Normal,
    Revert,
    Empty, // succeeds with no return data
    Short, // 1 byte of return data
    Raw, // returns `raw` verbatim
    Huge, // a valid answer followed by 64 KiB of padding
    GasHog // loops until it runs out of gas
}

abstract contract Misbehaving {
    Mode public mode;
    bytes public raw;

    function setMode(Mode m) external {
        mode = m;
    }

    function setRaw(bytes calldata r) external {
        mode = Mode.Raw;
        raw = r;
    }

    /// @dev Handles every non-Normal mode (never returns to the caller for those); `normal` is the
    ///      ABI-encoded answer used for Huge.
    function _misbehave(bytes memory normal) internal view {
        Mode m = mode;
        if (m == Mode.Revert) revert("MockGates: down");
        if (m == Mode.Empty) {
            assembly {
                return(0, 0)
            }
        }
        if (m == Mode.Short) {
            assembly {
                mstore(0, 0x0100000000000000000000000000000000000000000000000000000000000000)
                return(0, 1)
            }
        }
        if (m == Mode.Raw) {
            bytes memory r = raw;
            assembly {
                return(add(r, 0x20), mload(r))
            }
        }
        if (m == Mode.Huge) {
            bytes memory big = bytes.concat(normal, new bytes(64 * 1024));
            assembly {
                return(add(big, 0x20), mload(big))
            }
        }
        if (m == Mode.GasHog) {
            assembly {
                for {} 1 {} {}
            }
        }
    }
}

/// @notice IHumanGate whose answer and failure mode the test sets.
contract MockGate is Misbehaving {
    bool public answer;

    constructor(bool answer_) {
        answer = answer_;
    }

    function setAnswer(bool a) external {
        answer = a;
        mode = Mode.Normal;
    }

    function isVerified(address) external view returns (bool) {
        _misbehave(abi.encode(answer));
        return answer;
    }
}

/// @notice Stand-in for the live RentoutsSubnames: `labelOf` + `registry`.
contract MockSubnames is Misbehaving {
    address public registry;
    mapping(address => string) internal _labels;

    constructor(address registry_) {
        registry = registry_;
    }

    function setLabel(address holder, string calldata label) external {
        _labels[holder] = label;
    }

    function labelOf(address holder) external view returns (string memory) {
        _misbehave(abi.encode(_labels[holder]));
        return _labels[holder];
    }
}

/// @notice Stand-in for the ENSv2 UserRegistry: `getOwner(labelId)`.
contract MockEnsRegistry is Misbehaving {
    mapping(uint256 => address) public owners;

    function setOwner(string calldata label, address owner) external {
        owners[uint256(keccak256(bytes(label)))] = owner;
    }

    function getOwner(uint256 labelId) external view returns (address) {
        _misbehave(abi.encode(owners[labelId]));
        return owners[labelId];
    }
}
