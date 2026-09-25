// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRentEscrow} from "./interfaces/IRentEscrow.sol";
import {IHumanGate} from "./interfaces/IHumanGate.sol";
import {LeaseShare1155} from "./LeaseShare1155.sol";

/// @title RentEscrow
/// @notice Non-custodial rental escrow: the tenant prepays deposit + all rent into this contract,
///         rent is released to the landlord period by period, and the deposit goes back to the
///         tenant when the term ends. Disputes freeze the lease until a fixed arbiter splits the
///         remaining escrow between the two parties. See {IRentEscrow} for the lifecycle and the
///         invariants (INV-1..INV-4) exercised by test/RentEscrow.invariant.t.sol.
/// @dev    No owner, no admin, no fees, no upgradeability: token, arbiter, leaseShare and humanGate
///         are immutable. The only party-independent role is the arbiter: it can never be a lease's
///         landlord or tenant, and it can only split a disputed lease's own escrow between that
///         lease's tenant and landlord.
///         humanGate (optional) is asked once, in fundLease, whether the tenant is a verified human.
///         The gate's own owner can later point it at a verifier (World ID) without redeploying
///         this contract, but a gate can only refuse NEW funding: it holds no funds, and no other
///         function consults it, so funded leases always run to the end.
///         The token must be a plain ERC-20 (no fee-on-transfer / rebasing), e.g. Circle USDC.
///         Built for ETHGlobal Tokyo 2026 (Ethereum Sepolia).
contract RentEscrow is IRentEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @inheritdoc IRentEscrow
    uint256 public constant SHARES_PER_LEASE = 100;
    /// @inheritdoc IRentEscrow
    uint32 public constant MIN_PERIOD = 60;
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @inheritdoc IRentEscrow
    address public immutable token;
    /// @inheritdoc IRentEscrow
    address public immutable arbiter;
    /// @inheritdoc IRentEscrow
    address public immutable leaseShare;
    /// @inheritdoc IRentEscrow
    address public immutable humanGate;

    /// @inheritdoc IRentEscrow
    uint256 public nextLeaseId = 1;
    /// @inheritdoc IRentEscrow
    mapping(uint256 leaseId => uint256 amount) public escrowBalance;

    mapping(uint256 leaseId => Lease) internal _leases;
    mapping(address tenant => TenantStats) internal _stats;
    /// @dev Rent periods earned (elapsed, claimed or not) when the lease's dispute was opened. Rent
    ///      stops accruing then, so resolveDispute can tell a refund of unearned rent apart from
    ///      the deposit coming back.
    mapping(uint256 leaseId => uint16 periods) internal _earnedAtDispute;

    /// @notice Constructor argument was the zero address (token or arbiter).
    error ZeroAddress();
    /// @notice A non-zero humanGate must be a contract: an EOA would make every fundLease revert.
    error HumanGateHasNoCode(address humanGate);

    /// @param token_      escrow token (Circle USDC on Sepolia: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238)
    /// @param arbiter_    dispute arbiter: an EOA or a contract (e.g. a Safe multisig); on testnet a
    ///                    single EOA
    /// @param leaseShare_ LeaseShare1155 this contract mints lease shares on, or address(0) to disable
    /// @param humanGate_  IHumanGate checked in fundLease (normally a HumanGate), or address(0) for no
    ///                    gating at all
    // forge-lint: disable-next-item(missing-zero-check) -- address(0) leaseShare_ / humanGate_ mean "disabled"
    constructor(IERC20 token_, address arbiter_, address leaseShare_, address humanGate_) {
        if (address(token_) == address(0) || arbiter_ == address(0)) revert ZeroAddress();
        if (humanGate_ != address(0) && humanGate_.code.length == 0) revert HumanGateHasNoCode(humanGate_);
        token = address(token_);
        arbiter = arbiter_;
        leaseShare = leaseShare_;
        humanGate = humanGate_;
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IRentEscrow
    function getLease(uint256 leaseId) external view returns (Lease memory) {
        return _leases[leaseId];
    }

    /// @inheritdoc IRentEscrow
    function tenantStats(address tenant) external view returns (TenantStats memory) {
        return _stats[tenant];
    }

    /// @inheritdoc IRentEscrow
    /// @dev Zero unless the lease is ACTIVE (rent is frozen while DISPUTED).
    // forge-lint: disable-next-item(block-timestamp) -- periods are >= 60s; seconds of drift are harmless
    function claimable(uint256 leaseId) public view returns (uint16 periods, uint256 amount) {
        Lease storage l = _leases[leaseId];
        if (l.state != State.ACTIVE) return (0, 0);
        uint256 elapsed = (block.timestamp - l.startTime) / l.periodSeconds;
        if (elapsed > l.periods) elapsed = l.periods;
        // elapsed >= periodsClaimed: periodsClaimed only ever catches up to a past `elapsed`.
        // casting to 'uint16' is safe because elapsed <= l.periods, a uint16
        // forge-lint: disable-next-line(unsafe-typecast)
        periods = uint16(elapsed - l.periodsClaimed);
        amount = uint256(periods) * l.rentPerPeriod;
    }

    /// @inheritdoc IRentEscrow
    function endTime(uint256 leaseId) public view returns (uint64) {
        Lease storage l = _leases[leaseId];
        if (l.startTime == 0) return 0;
        return _endTime(l);
    }

    // ------------------------------------------------------------------ actions

    /// @inheritdoc IRentEscrow
    /// @dev Reverts InvalidTerms if the arbiter would be the landlord or the tenant: an arbiter that
    ///      is also a party could open a dispute and rule the whole escrow to itself.
    ///      If lease shares are enabled, mints SHARES_PER_LEASE shares of tokenId == leaseId to the
    ///      landlord. LeaseShare1155 only lets allowlisted addresses receive shares, so a landlord
    ///      who is not on the compliance allowlist cannot list (the whole call reverts).
    function createLease(address tenant, uint128 deposit, uint128 rentPerPeriod, uint32 periodSeconds, uint16 periods)
        external
        nonReentrant
        returns (uint256 leaseId)
    {
        uint256 total = uint256(deposit) + uint256(rentPerPeriod) * periods;
        if (
            tenant == address(0) || tenant == msg.sender || msg.sender == arbiter || tenant == arbiter
                || uint256(deposit) + rentPerPeriod == 0 || periods == 0 || periodSeconds < MIN_PERIOD
                || total > type(uint128).max
        ) revert InvalidTerms();

        leaseId = nextLeaseId++;
        _leases[leaseId] = Lease({
            landlord: msg.sender,
            tenant: tenant,
            deposit: deposit,
            rentPerPeriod: rentPerPeriod,
            periodSeconds: periodSeconds,
            periods: periods,
            periodsClaimed: 0,
            startTime: 0,
            state: State.CREATED
        });
        emit LeaseCreated(leaseId, msg.sender, tenant, deposit, rentPerPeriod, periodSeconds, periods);

        if (leaseShare != address(0)) {
            // state is written above and every mutating entry point is nonReentrant
            // forge-lint: disable-next-line(reentrancy-no-eth)
            LeaseShare1155(leaseShare).mintShare(leaseId, msg.sender, SHARES_PER_LEASE);
        }
    }

    /// @inheritdoc IRentEscrow
    function cancelLease(uint256 leaseId) external nonReentrant {
        Lease storage l = _leases[leaseId];
        _requireState(l, leaseId, State.CREATED);
        if (msg.sender != l.landlord) revert NotLandlord(leaseId);

        l.state = State.CANCELLED;
        emit LeaseCancelled(leaseId);
    }

    /// @inheritdoc IRentEscrow
    /// @dev The human-gate check is a view (staticcall) made before any state change; a gate that
    ///      reverts makes funding revert (fail closed).
    function fundLease(uint256 leaseId) external nonReentrant {
        Lease storage l = _leases[leaseId];
        _requireState(l, leaseId, State.CREATED);
        if (msg.sender != l.tenant) revert NotTenant(leaseId);
        if (humanGate != address(0) && !IHumanGate(humanGate).isVerified(msg.sender)) {
            revert NotVerifiedHuman(msg.sender);
        }

        uint256 amount = uint256(l.deposit) + uint256(l.rentPerPeriod) * l.periods;
        // casting to 'uint64' is safe because timestamps fit in 64 bits for ~5e11 years
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 start = uint64(block.timestamp);
        l.state = State.ACTIVE;
        l.startTime = start;
        escrowBalance[leaseId] = amount;
        _stats[msg.sender].leasesFunded += 1;
        emit LeaseFunded(leaseId, msg.sender, amount, start);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @inheritdoc IRentEscrow
    function claimRent(uint256 leaseId) external nonReentrant {
        Lease storage l = _leases[leaseId];
        _requireState(l, leaseId, State.ACTIVE);
        (uint16 periods, uint256 amount) = claimable(leaseId);
        if (periods == 0) revert NothingToClaim(leaseId);

        l.periodsClaimed += periods;
        escrowBalance[leaseId] -= amount;
        TenantStats storage s = _stats[l.tenant];
        s.periodsPaid += periods;
        // casting to 'uint128' is safe because amount <= deposit + rent * periods <= type(uint128).max
        // forge-lint: disable-next-line(unsafe-typecast)
        s.rentPaid += uint128(amount);
        address landlord = l.landlord;
        emit RentClaimed(leaseId, landlord, periods, amount);

        _pay(landlord, amount);
    }

    /// @inheritdoc IRentEscrow
    /// @dev Reverts TermNotOver before endTime, and for anyone but the landlord until
    ///      endTime + periodSeconds (the grace window in which the landlord can still dispute).
    // forge-lint: disable-next-item(block-timestamp) -- periods are >= 60s; seconds of drift are harmless
    function closeLease(uint256 leaseId) external nonReentrant {
        Lease storage l = _leases[leaseId];
        _requireState(l, leaseId, State.ACTIVE);
        uint256 end = _endTime(l);
        if (block.timestamp < end) revert TermNotOver(leaseId);
        if (msg.sender != l.landlord && block.timestamp < end + l.periodSeconds) revert TermNotOver(leaseId);

        uint16 remaining = l.periods - l.periodsClaimed;
        uint256 toLandlord = uint256(remaining) * l.rentPerPeriod;
        uint128 deposit = l.deposit;
        address tenant = l.tenant;

        l.periodsClaimed = l.periods;
        l.state = State.CLOSED;
        escrowBalance[leaseId] = 0; // == deposit + toLandlord
        TenantStats storage s = _stats[tenant];
        s.leasesCompleted += 1;
        s.periodsPaid += remaining;
        // casting to 'uint128' is safe because toLandlord <= rent * periods <= type(uint128).max
        // forge-lint: disable-next-line(unsafe-typecast)
        s.rentPaid += uint128(toLandlord);
        s.depositsPosted += deposit;
        s.depositsReturned += deposit;
        emit LeaseClosed(leaseId, tenant, deposit, toLandlord);

        _pay(l.landlord, toLandlord);
        _pay(tenant, deposit);
    }

    /// @inheritdoc IRentEscrow
    function openDispute(uint256 leaseId) external nonReentrant {
        Lease storage l = _leases[leaseId];
        _requireState(l, leaseId, State.ACTIVE);
        if (msg.sender != l.tenant && msg.sender != l.landlord) revert NotParty(leaseId);

        (uint16 due,) = claimable(leaseId); // read while still ACTIVE
        _earnedAtDispute[leaseId] = l.periodsClaimed + due;
        l.state = State.DISPUTED;
        _stats[l.tenant].leasesDisputed += 1;
        emit DisputeOpened(leaseId, msg.sender);
    }

    /// @inheritdoc IRentEscrow
    /// @dev The tenant's share rounds down; the landlord gets the rest, so the payout is exact.
    ///      Counts toward depositsPosted / depositsReturned, never toward leasesCompleted.
    ///      depositsReturned: the tenant's payout first refunds rent not yet earned when the dispute
    ///      was opened, then returns the deposit, then any earned rent. So a ruling that refunds
    ///      unused rent but keeps the deposit records 0 returned, and one that returns the deposit
    ///      and leaves earned rent to the landlord records the whole deposit, claimed or not.
    function resolveDispute(uint256 leaseId, uint16 tenantBps) external nonReentrant {
        if (msg.sender != arbiter) revert NotArbiter();
        if (tenantBps > BPS_DENOMINATOR) revert InvalidBps(tenantBps);
        Lease storage l = _leases[leaseId];
        _requireState(l, leaseId, State.DISPUTED);

        uint256 balance = escrowBalance[leaseId];
        uint256 toTenant = balance * tenantBps / BPS_DENOMINATOR;
        uint256 toLandlord = balance - toTenant;
        uint128 deposit = l.deposit;
        address tenant = l.tenant;
        uint256 unearnedRent = uint256(l.periods - _earnedAtDispute[leaseId]) * l.rentPerPeriod;
        uint256 depositBack = toTenant > unearnedRent ? toTenant - unearnedRent : 0;
        if (depositBack > deposit) depositBack = deposit;

        l.state = State.CLOSED;
        escrowBalance[leaseId] = 0;
        TenantStats storage s = _stats[tenant];
        s.depositsPosted += deposit;
        // casting to 'uint128' is safe because depositBack <= deposit, a uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        s.depositsReturned += uint128(depositBack);
        emit DisputeResolved(leaseId, tenantBps, toTenant, toLandlord);

        _pay(tenant, toTenant);
        _pay(l.landlord, toLandlord);
    }

    // ------------------------------------------------------------------ internal

    function _requireState(Lease storage l, uint256 leaseId, State expected) internal view {
        if (l.state != expected) revert InvalidState(leaseId, l.state);
    }

    function _endTime(Lease storage l) internal view returns (uint64) {
        return l.startTime + uint64(l.periodSeconds) * l.periods;
    }

    function _pay(address to, uint256 amount) internal {
        if (amount != 0) IERC20(token).safeTransfer(to, amount);
    }
}
