// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {LeaseShare1155} from "../src/LeaseShare1155.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";

/// @notice Drives RentEscrow through random lease lifecycles across several actors and keeps an
///         independent ledger of every token transfer out of the escrow (read from the token's
///         Transfer logs, not from the escrow's own bookkeeping).
contract EscrowHandler is Test {
    bytes32 internal constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");

    RentEscrow public immutable escrow;
    MockUSDC public immutable usdc;
    address public immutable arbiter;
    address public immutable keeper; // unrelated third party that pokes claim/close
    address[] public actors; // landlords and tenants

    /// @dev Block time survives between handler calls only through this ghost.
    uint256 public currentTime;

    // INV-1: per-address ledger + recipient check
    mapping(address => uint256) public ghostMinted; // test tokens minted to an actor so it can fund
    mapping(address => uint256) public ghostPaidIn; // paid by an actor into the escrow
    mapping(address => uint256) public ghostReceived; // paid by the escrow to this address
    uint256 public ghostOutToNonParty; // escrow transfers to anyone but the lease's tenant/landlord
    uint256 public ghostWrongPayout; // claim/close paid a party something other than its due

    // INV-3: rent actually transferred to the landlord per lease
    mapping(uint256 => uint256) public ghostRentReleased;

    // INV-4: dispute resolutions
    mapping(uint256 => bool) public ghostResolved;
    mapping(uint256 => uint256) public ghostEscrowAtResolve;
    mapping(uint256 => uint256) public ghostResolvePayout;
    uint256 public ghostBadSplit;

    mapping(bytes32 => uint256) public calls;

    modifier useTime() {
        vm.warp(currentTime);
        _;
    }

    constructor(RentEscrow escrow_, MockUSDC usdc_, address arbiter_, address keeper_, address[] memory actors_) {
        escrow = escrow_;
        usdc = usdc_;
        arbiter = arbiter_;
        keeper = keeper_;
        actors = actors_;
        currentTime = block.timestamp;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------ actions

    function createLease(
        uint256 landlordSeed,
        uint256 tenantSeed,
        uint128 deposit,
        uint128 rent,
        uint32 periodSeconds,
        uint16 periods
    ) external useTime {
        address landlord = actors[landlordSeed % actors.length];
        address tenant = actors[tenantSeed % actors.length];
        if (tenant == landlord) tenant = actors[(tenantSeed % actors.length + 1) % actors.length];
        deposit = uint128(bound(deposit, 0, 10_000e6));
        rent = uint128(bound(rent, 0, 5_000e6));
        if (deposit == 0 && rent == 0) deposit = 1;
        periodSeconds = uint32(bound(periodSeconds, 60, 6 hours));
        periods = uint16(bound(periods, 1, 12));

        vm.prank(landlord);
        escrow.createLease(tenant, deposit, rent, periodSeconds, periods);
        calls["createLease"]++;
    }

    function cancelLease(uint256 seed) external useTime {
        if (seed % 4 != 0) return; // keep most proposals alive long enough to be funded
        uint256 id = _find(seed, IRentEscrow.State.CREATED);
        if (id == 0) return;
        vm.prank(escrow.getLease(id).landlord);
        escrow.cancelLease(id);
        calls["cancelLease"]++;
    }

    function fundLease(uint256 seed) external useTime {
        uint256 id = _find(seed, IRentEscrow.State.CREATED);
        if (id == 0) return;
        IRentEscrow.Lease memory l = escrow.getLease(id);
        uint256 total = uint256(l.deposit) + uint256(l.rentPerPeriod) * l.periods;

        usdc.mint(l.tenant, total);
        ghostMinted[l.tenant] += total;
        vm.prank(l.tenant);
        usdc.approve(address(escrow), total);
        vm.recordLogs();
        vm.prank(l.tenant);
        escrow.fundLease(id);
        ghostPaidIn[l.tenant] += total;
        _outflows(id); // funding must not move anything out
        calls["fundLease"]++;
    }

    function warp(uint256 secs) external {
        currentTime += bound(secs, 0, 12 hours);
        calls["warp"]++;
    }

    function claimRent(uint256 seed, uint256 callerSeed) external useTime {
        uint256 id = _findClaimable(seed);
        if (id == 0) return;
        (, uint256 expected) = escrow.claimable(id);

        vm.recordLogs();
        vm.prank(_anyone(callerSeed));
        escrow.claimRent(id);
        (uint256 toTenant, uint256 toLandlord) = _outflows(id);

        if (toTenant != 0 || toLandlord != expected) ghostWrongPayout++;
        ghostRentReleased[id] += toLandlord;
        calls["claimRent"]++;
    }

    function closeLease(uint256 seed, uint256 callerSeed) external useTime {
        uint256 id = _findClosable(seed);
        if (id == 0) return;
        IRentEscrow.Lease memory l = escrow.getLease(id);
        address caller = _anyone(callerSeed);
        // Only the landlord may close inside the one-period grace window.
        if (block.timestamp < uint256(escrow.endTime(id)) + l.periodSeconds) caller = l.landlord;

        vm.recordLogs();
        vm.prank(caller);
        escrow.closeLease(id);
        (uint256 toTenant, uint256 toLandlord) = _outflows(id);

        uint256 rentDue = uint256(l.rentPerPeriod) * (l.periods - l.periodsClaimed);
        if (toTenant != l.deposit || toLandlord != rentDue) ghostWrongPayout++;
        ghostRentReleased[id] += toLandlord;
        calls["closeLease"]++;
    }

    function openDispute(uint256 seed, bool byLandlord) external useTime {
        if (seed % 3 != 0) return; // most leases should run to term
        uint256 id = _find(seed, IRentEscrow.State.ACTIVE);
        if (id == 0) return;
        IRentEscrow.Lease memory l = escrow.getLease(id);
        vm.prank(byLandlord ? l.landlord : l.tenant);
        escrow.openDispute(id);
        calls["openDispute"]++;
    }

    function resolveDispute(uint256 seed, uint16 tenantBps) external useTime {
        uint256 id = _find(seed, IRentEscrow.State.DISPUTED);
        if (id == 0) return;
        tenantBps = uint16(bound(tenantBps, 0, 10_000));
        uint256 before = escrow.escrowBalance(id);

        vm.recordLogs();
        vm.prank(arbiter);
        escrow.resolveDispute(id, tenantBps);
        (uint256 toTenant, uint256 toLandlord) = _outflows(id);

        ghostResolved[id] = true;
        ghostEscrowAtResolve[id] = before;
        ghostResolvePayout[id] = toTenant + toLandlord;
        if (toTenant != before * tenantBps / 10_000 || toTenant + toLandlord != before) ghostBadSplit++;
        calls["resolveDispute"]++;
    }

    // ------------------------------------------------------------------ internal

    /// @dev Reads the token Transfer logs emitted by the last escrow call and books every transfer
    ///      whose sender is the escrow. Anything sent to a non-party of `leaseId` is flagged.
    function _outflows(uint256 leaseId) internal returns (uint256 toTenant, uint256 toLandlord) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        IRentEscrow.Lease memory l = escrow.getLease(leaseId);
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(usdc) || logs[i].topics[0] != TRANSFER_SIG) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != address(escrow)) continue;
            address to = address(uint160(uint256(logs[i].topics[2])));
            uint256 amount = abi.decode(logs[i].data, (uint256));
            ghostReceived[to] += amount;
            if (to == l.tenant) toTenant += amount;
            else if (to == l.landlord) toLandlord += amount;
            else ghostOutToNonParty++;
        }
    }

    function _anyone(uint256 seed) internal view returns (address) {
        uint256 i = seed % (actors.length + 2);
        if (i == actors.length) return keeper;
        if (i == actors.length + 1) return arbiter;
        return actors[i];
    }

    function _count() internal view returns (uint256) {
        return escrow.nextLeaseId() - 1;
    }

    function _find(uint256 seed, IRentEscrow.State state) internal view returns (uint256) {
        uint256 n = _count();
        for (uint256 i; i < n; i++) {
            uint256 id = 1 + (seed % n + i) % n;
            if (escrow.getLease(id).state == state) return id;
        }
        return 0;
    }

    function _findClaimable(uint256 seed) internal view returns (uint256) {
        uint256 n = _count();
        for (uint256 i; i < n; i++) {
            uint256 id = 1 + (seed % n + i) % n;
            (uint16 periods,) = escrow.claimable(id);
            if (periods > 0) return id;
        }
        return 0;
    }

    function _findClosable(uint256 seed) internal view returns (uint256) {
        uint256 n = _count();
        for (uint256 i; i < n; i++) {
            uint256 id = 1 + (seed % n + i) % n;
            if (escrow.getLease(id).state == IRentEscrow.State.ACTIVE && block.timestamp >= escrow.endTime(id)) {
                return id;
            }
        }
        return 0;
    }
}

/// @notice INV-1..INV-4 from IRentEscrow's NatSpec, checked after every handler call.
contract RentEscrowInvariantTest is Test {
    MockUSDC internal usdc;
    LeaseShare1155 internal shares;
    RentEscrow internal escrow;
    EscrowHandler internal handler;

    address internal arbiter = makeAddr("arbiter");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        shares = new LeaseShare1155(address(this), "https://rentouts.co/api/lease-share/{id}.json");
        escrow = new RentEscrow(IERC20(address(usdc)), arbiter, address(shares));
        shares.setMinter(address(escrow));

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");
        actors[3] = makeAddr("dave");
        for (uint256 i; i < actors.length; i++) {
            shares.setAllowlist(actors[i], true); // every actor may list as a landlord
        }

        handler = new EscrowHandler(escrow, usdc, arbiter, keeper, actors);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = EscrowHandler.createLease.selector;
        selectors[1] = EscrowHandler.cancelLease.selector;
        selectors[2] = EscrowHandler.fundLease.selector;
        selectors[3] = EscrowHandler.warp.selector;
        selectors[4] = EscrowHandler.claimRent.selector;
        selectors[5] = EscrowHandler.closeLease.selector;
        selectors[6] = EscrowHandler.openDispute.selector;
        selectors[7] = EscrowHandler.resolveDispute.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// INV-1: funds only ever move to the lease's tenant or landlord (no owner, no fee, no admin).
    function invariant_INV1_FundsOnlyReachLeaseParties() public {
        assertEq(handler.ghostOutToNonParty(), 0, "escrow paid a non-party");
        assertEq(handler.ghostWrongPayout(), 0, "claim/close paid the wrong amount");
        // Nobody outside the actor set ever holds tokens: not the arbiter, keeper, or share issuer.
        assertEq(usdc.balanceOf(arbiter), 0, "arbiter holds tokens");
        assertEq(usdc.balanceOf(keeper), 0, "keeper holds tokens");
        assertEq(usdc.balanceOf(address(this)), 0, "issuer holds tokens");
        // Each actor's balance is exactly what it was minted, minus what it escrowed, plus what the
        // escrow paid it as a tenant/landlord: the log-based ledger misses no transfer.
        for (uint256 i; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            assertEq(
                usdc.balanceOf(a),
                handler.ghostMinted(a) - handler.ghostPaidIn(a) + handler.ghostReceived(a),
                "actor ledger mismatch"
            );
        }
    }

    /// INV-2: sum of escrowBalance(leaseId) == token.balanceOf(escrow).
    function invariant_INV2_EscrowBalancesSumToTokenBalance() public {
        uint256 n = escrow.nextLeaseId();
        uint256 sum;
        for (uint256 id = 1; id < n; id++) {
            IRentEscrow.Lease memory l = escrow.getLease(id);
            uint256 bal = escrow.escrowBalance(id);
            sum += bal;
            if (l.state == IRentEscrow.State.ACTIVE || l.state == IRentEscrow.State.DISPUTED) {
                assertEq(bal, uint256(l.deposit) + uint256(l.rentPerPeriod) * (l.periods - l.periodsClaimed));
            } else {
                assertEq(bal, 0, "settled/unfunded lease holds escrow");
            }
        }
        assertEq(sum, usdc.balanceOf(address(escrow)), "escrow balances != token balance");
    }

    /// INV-3: rent released for a lease never exceeds rentPerPeriod * elapsed periods (capped at term).
    function invariant_INV3_RentNeverExceedsElapsedPeriods() public {
        uint256 n = escrow.nextLeaseId();
        uint256 nowTs = handler.currentTime();
        for (uint256 id = 1; id < n; id++) {
            IRentEscrow.Lease memory l = escrow.getLease(id);
            uint256 released = handler.ghostRentReleased(id);
            if (l.startTime == 0) {
                assertEq(released, 0, "rent released before funding");
                continue;
            }
            uint256 elapsed = (nowTs - l.startTime) / l.periodSeconds;
            if (elapsed > l.periods) elapsed = l.periods;
            assertLe(l.periodsClaimed, elapsed, "claimed periods ahead of time");
            assertLe(released, uint256(l.rentPerPeriod) * elapsed, "rent released ahead of time");
            assertEq(released, uint256(l.rentPerPeriod) * l.periodsClaimed, "rent ledger mismatch");
        }
    }

    /// INV-4: a dispute resolution pays out exactly the lease's remaining escrow, split tenant/landlord.
    function invariant_INV4_ResolutionPaysOutExactlyRemainingEscrow() public {
        assertEq(handler.ghostBadSplit(), 0, "resolution split mismatch");
        uint256 n = escrow.nextLeaseId();
        for (uint256 id = 1; id < n; id++) {
            if (!handler.ghostResolved(id)) continue;
            assertEq(handler.ghostResolvePayout(id), handler.ghostEscrowAtResolve(id), "payout != remaining escrow");
            assertEq(escrow.escrowBalance(id), 0, "resolved lease still holds escrow");
            assertEq(uint8(escrow.getLease(id).state), uint8(IRentEscrow.State.CLOSED));
        }
    }
}
