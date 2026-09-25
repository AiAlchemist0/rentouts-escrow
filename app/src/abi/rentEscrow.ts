import { parseAbi } from 'viem'

/**
 * RentEscrow, transcribed from rentouts-escrow-core/src/interfaces/IRentEscrow.sol (branch feat/core-escrow).
 * Solidity enums are uint8 on the ABI: State = NONE, CREATED, ACTIVE, DISPUTED, CLOSED, CANCELLED.
 */
export const rentEscrowAbi = parseAbi([
  'struct Lease { address landlord; address tenant; uint128 deposit; uint128 rentPerPeriod; uint32 periodSeconds; uint16 periods; uint16 periodsClaimed; uint64 startTime; uint8 state; }',
  'struct TenantStats { uint32 leasesFunded; uint32 leasesCompleted; uint32 leasesDisputed; uint32 periodsPaid; uint128 rentPaid; uint128 depositsPosted; uint128 depositsReturned; }',

  'event LeaseCreated(uint256 indexed leaseId, address indexed landlord, address indexed tenant, uint128 deposit, uint128 rentPerPeriod, uint32 periodSeconds, uint16 periods)',
  'event LeaseFunded(uint256 indexed leaseId, address indexed tenant, uint256 amount, uint64 startTime)',
  'event RentClaimed(uint256 indexed leaseId, address indexed landlord, uint16 periods, uint256 amount)',
  'event LeaseClosed(uint256 indexed leaseId, address indexed tenant, uint256 toTenant, uint256 toLandlord)',
  'event LeaseCancelled(uint256 indexed leaseId)',
  'event DisputeOpened(uint256 indexed leaseId, address indexed by)',
  'event DisputeResolved(uint256 indexed leaseId, uint16 tenantBps, uint256 toTenant, uint256 toLandlord)',

  'error InvalidTerms()',
  'error InvalidState(uint256 leaseId, uint8 state)',
  'error NotLandlord(uint256 leaseId)',
  'error NotTenant(uint256 leaseId)',
  'error NotParty(uint256 leaseId)',
  'error NotArbiter()',
  'error NothingToClaim(uint256 leaseId)',
  'error TermNotOver(uint256 leaseId)',
  'error InvalidBps(uint16 bps)',

  'function token() view returns (address)',
  'function arbiter() view returns (address)',
  'function leaseShare() view returns (address)',
  'function SHARES_PER_LEASE() view returns (uint256)',
  'function MIN_PERIOD() view returns (uint32)',

  'function nextLeaseId() view returns (uint256)',
  'function getLease(uint256 leaseId) view returns (Lease)',
  'function escrowBalance(uint256 leaseId) view returns (uint256)',
  'function tenantStats(address tenant) view returns (TenantStats)',
  'function claimable(uint256 leaseId) view returns (uint16 periods, uint256 amount)',
  'function endTime(uint256 leaseId) view returns (uint64)',

  'function createLease(address tenant, uint128 deposit, uint128 rentPerPeriod, uint32 periodSeconds, uint16 periods) returns (uint256 leaseId)',
  'function cancelLease(uint256 leaseId)',
  'function fundLease(uint256 leaseId)',
  'function claimRent(uint256 leaseId)',
  'function closeLease(uint256 leaseId)',
  'function openDispute(uint256 leaseId)',
  'function resolveDispute(uint256 leaseId, uint16 tenantBps)',
])

export const LeaseState = {
  NONE: 0,
  CREATED: 1,
  ACTIVE: 2,
  DISPUTED: 3,
  CLOSED: 4,
  CANCELLED: 5,
} as const
