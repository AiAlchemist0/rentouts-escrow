// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRentEscrow
/// @notice Non-custodial rental escrow (Ethereum Sepolia, Circle USDC). A smart contract, never
///         RentOuts, holds the tenant's deposit and prepaid rent; it releases rent to the landlord
///         as periods elapse and returns the deposit at the end. Disputes go to a fixed arbiter who
///         can only split the remaining escrow between tenant and landlord.
///
///         Lifecycle:  createLease (landlord) -> fundLease (tenant, prepays deposit + all rent)
///                     -> claimRent (as periods elapse) -> closeLease (after term: rest of rent to
///                     landlord, deposit to tenant)
///                     ACTIVE -> openDispute (either party) -> resolveDispute (arbiter, tenantBps)
///                     CREATED -> cancelLease (landlord, before funding)
///
///         Invariants (tested):
///         INV-1  funds only ever move to the lease's tenant or landlord (no owner, no fee, no admin)
///         INV-2  sum of escrowBalance(leaseId) == token.balanceOf(escrow) (escrow-originated flows)
///         INV-3  rent released for a lease never exceeds rentPerPeriod * elapsed periods (capped at term)
///         INV-4  a dispute resolution pays out exactly the lease's remaining escrow, split tenant/landlord
interface IRentEscrow {
    enum State {
        NONE,
        CREATED,
        ACTIVE,
        DISPUTED,
        CLOSED,
        CANCELLED
    }

    struct Lease {
        address landlord;
        address tenant;
        uint128 deposit; // token units (USDC: 6 decimals)
        uint128 rentPerPeriod; // token units
        uint32 periodSeconds; // >= MIN_PERIOD; short periods make a live demo possible
        uint16 periods; // lease term, in periods
        uint16 periodsClaimed; // rent periods already released to the landlord
        uint64 startTime; // set when the tenant funds
        State state;
    }

    /// @notice Per-tenant track record, read by RentOuts' ENS credential sync (rentouts.* records).
    struct TenantStats {
        uint32 leasesFunded;
        uint32 leasesCompleted; // closed normally (no dispute)
        uint32 leasesDisputed; // disputes opened on this tenant's leases (by either party)
        uint32 periodsPaid; // rent periods released to landlords
        uint128 rentPaid; // token units released to landlords
        uint128 depositsPosted; // token units of deposit posted on leases that have ended
        uint128 depositsReturned; // token units of deposit returned to the tenant
    }

    event LeaseCreated(
        uint256 indexed leaseId,
        address indexed landlord,
        address indexed tenant,
        uint128 deposit,
        uint128 rentPerPeriod,
        uint32 periodSeconds,
        uint16 periods
    );
    event LeaseFunded(uint256 indexed leaseId, address indexed tenant, uint256 amount, uint64 startTime);
    event RentClaimed(uint256 indexed leaseId, address indexed landlord, uint16 periods, uint256 amount);
    event LeaseClosed(uint256 indexed leaseId, address indexed tenant, uint256 toTenant, uint256 toLandlord);
    event LeaseCancelled(uint256 indexed leaseId);
    event DisputeOpened(uint256 indexed leaseId, address indexed by);
    event DisputeResolved(uint256 indexed leaseId, uint16 tenantBps, uint256 toTenant, uint256 toLandlord);

    error InvalidTerms();
    error InvalidState(uint256 leaseId, State state);
    error NotLandlord(uint256 leaseId);
    error NotTenant(uint256 leaseId);
    error NotParty(uint256 leaseId);
    error NotArbiter();
    error NothingToClaim(uint256 leaseId);
    error TermNotOver(uint256 leaseId);
    error InvalidBps(uint16 bps);

    // ------------------------------------------------------------------ config (immutable)

    function token() external view returns (address);
    function arbiter() external view returns (address);
    /// @notice LeaseShare1155 (Curvegrid RWA) or address(0) if disabled. createLease mints
    ///         SHARES_PER_LEASE shares of tokenId == leaseId to the landlord; the landlord must be
    ///         allowlisted there (compliance-aware listing).
    function leaseShare() external view returns (address);
    function SHARES_PER_LEASE() external view returns (uint256);
    function MIN_PERIOD() external view returns (uint32);

    // ------------------------------------------------------------------ views

    function nextLeaseId() external view returns (uint256);
    function getLease(uint256 leaseId) external view returns (Lease memory);
    function escrowBalance(uint256 leaseId) external view returns (uint256);
    function tenantStats(address tenant) external view returns (TenantStats memory);
    /// @notice Rent periods elapsed but not yet released, and their amount.
    function claimable(uint256 leaseId) external view returns (uint16 periods, uint256 amount);
    /// @notice startTime + periods * periodSeconds (0 before funding).
    function endTime(uint256 leaseId) external view returns (uint64);

    // ------------------------------------------------------------------ actions

    /// @notice Landlord (msg.sender) proposes a lease to `tenant`. Leases are numbered from 1.
    function createLease(address tenant, uint128 deposit, uint128 rentPerPeriod, uint32 periodSeconds, uint16 periods)
        external
        returns (uint256 leaseId);

    /// @notice Landlord withdraws an unfunded lease. CREATED -> CANCELLED.
    function cancelLease(uint256 leaseId) external;

    /// @notice Tenant prepays deposit + rentPerPeriod * periods (needs token approval). CREATED -> ACTIVE.
    function fundLease(uint256 leaseId) external;

    /// @notice Releases every elapsed, unclaimed rent period to the landlord. Callable by anyone
    ///         (funds can only go to the landlord). ACTIVE only; frozen while DISPUTED.
    function claimRent(uint256 leaseId) external;

    /// @notice After the term: remaining rent to the landlord, deposit to the tenant. ACTIVE -> CLOSED.
    ///         The landlord may close as soon as the term ends; anyone may close one period later
    ///         (the grace period gives the landlord time to open a dispute over the deposit).
    function closeLease(uint256 leaseId) external;

    /// @notice Tenant or landlord freezes the lease for the arbiter. ACTIVE -> DISPUTED.
    function openDispute(uint256 leaseId) external;

    /// @notice Arbiter splits the lease's remaining escrow: tenantBps/10000 to the tenant, the rest
    ///         to the landlord. DISPUTED -> CLOSED.
    function resolveDispute(uint256 leaseId, uint16 tenantBps) external;
}
