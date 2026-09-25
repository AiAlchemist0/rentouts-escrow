// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VmSafe} from "forge-std/Vm.sol";
import {IRentEscrow} from "../../src/interfaces/IRentEscrow.sol";

/// @notice AI-1 checker over a vm.startStateDiffRecording session: classifies every account access
///         made BY `arbiter`. Allowed: reading the escrow's code size (Solidity's pre-call check),
///         view calls escrow.getLease / escrow.arbiter, and escrow.resolveDispute with no ETH.
///         Anything else (another target, another selector, ETH, delegatecall, create, selfdestruct)
///         is counted as forbidden, even if it reverted. `resolves` counts resolveDispute calls
///         that went through.
function classifyArbiterCalls(VmSafe.AccountAccess[] memory accesses, address arbiter, address escrow)
    pure
    returns (uint256 forbidden, uint256 resolves)
{
    for (uint256 i; i < accesses.length; i++) {
        VmSafe.AccountAccess memory acc = accesses[i];
        if (acc.accessor != arbiter || acc.kind == VmSafe.AccountAccessKind.Resume) continue;
        if (acc.account != escrow) {
            forbidden++;
            continue;
        }
        if (
            acc.kind == VmSafe.AccountAccessKind.Extcodesize || acc.kind == VmSafe.AccountAccessKind.Extcodehash
                || acc.kind == VmSafe.AccountAccessKind.Balance
        ) continue; // reads of the escrow's account info
        bytes4 sel = acc.data.length >= 4 ? bytes4(acc.data) : bytes4(0);
        if (acc.kind == VmSafe.AccountAccessKind.StaticCall) {
            if (sel != IRentEscrow.getLease.selector && sel != IRentEscrow.arbiter.selector) forbidden++;
        } else if (
            acc.kind == VmSafe.AccountAccessKind.Call && acc.value == 0 && sel == IRentEscrow.resolveDispute.selector
        ) {
            if (!acc.reverted) resolves++;
        } else {
            forbidden++;
        }
    }
}
