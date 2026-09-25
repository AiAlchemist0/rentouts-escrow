import { parseAbi } from 'viem'

/**
 * AIArbiter, transcribed from rentouts-escrow src/AIArbiter.sol (branch feat/ai-judge). It is RentEscrow's
 * arbiter: the AI judge's key (`agent`) can only propose a split for a disputed lease, either party can appeal
 * inside the challenge window, anyone can execute an unappealed proposal after it, and the `human` arbiter can
 * resolve any disputed lease directly or override a proposal that hasn't been executed.
 *
 * Solidity enums are uint8 on the ABI. Status = NONE, PROPOSED, APPEALED, EXECUTED, HUMAN_RESOLVED
 * (see RulingStatus in lib/aiJudge.ts); IRentEscrow.State is RentEscrow's lease state.
 */
export const aiArbiterAbi = parseAbi([
  'struct Ruling { uint8 status; uint16 tenantBps; uint16 confidenceBps; uint64 proposedAt; uint64 deadline; bytes32 rulingHash; }',

  'event EscrowBound(address indexed escrow)',
  'event HumanUpdated(address indexed previousHuman, address indexed newHuman)',
  'event AgentUpdated(address indexed previousAgent, address indexed newAgent)',
  'event ChallengeWindowUpdated(uint32 previousWindow, uint32 newWindow)',
  'event Evidence(uint256 indexed leaseId, address indexed party, string statement)',
  'event Proposed(uint256 indexed leaseId, address indexed agent, uint16 tenantBps, uint16 confidenceBps, bytes32 rulingHash, uint64 deadline, string summary)',
  'event ProposalReplaced(uint256 indexed leaseId, uint16 previousTenantBps, bytes32 previousRulingHash)',
  'event Appealed(uint256 indexed leaseId, address indexed by)',
  'event Executed(uint256 indexed leaseId, uint16 tenantBps, address indexed by)',
  'event HumanResolved(uint256 indexed leaseId, uint16 tenantBps, address indexed human, uint8 previous)',

  'error ZeroAddress()',
  'error NotHuman()',
  'error NotAgent()',
  'error NotParty(uint256 leaseId)',
  'error PartyCannotArbitrate(uint256 leaseId, address account)',
  'error EscrowNotBound()',
  'error EscrowAlreadyBound(address escrow)',
  'error NotEscrowArbiter(address escrow)',
  'error InvalidChallengeWindow(uint32 window)',
  'error InvalidBps(uint16 bps)',
  'error NotDisputed(uint256 leaseId, uint8 state)',
  'error InvalidStatementLength(uint256 length)',
  'error TooManyStatements(uint256 leaseId, address party)',
  'error SummaryTooLong(uint256 length)',
  'error NoOpenProposal(uint256 leaseId, uint8 status)',
  'error ProposalLocked(uint256 leaseId, uint8 status)',
  'error ChallengeWindowOver(uint256 leaseId, uint64 deadline)',
  'error ChallengeWindowOpen(uint256 leaseId, uint64 deadline)',
  'error ReentrancyGuardReentrantCall()',

  'function MIN_CHALLENGE_WINDOW() view returns (uint32)',
  'function MAX_CHALLENGE_WINDOW() view returns (uint32)',
  'function MAX_STATEMENT_BYTES() view returns (uint256)',
  'function MAX_STATEMENTS_PER_PARTY() view returns (uint256)',
  'function MAX_SUMMARY_BYTES() view returns (uint256)',

  'function escrow() view returns (address)',
  'function human() view returns (address)',
  'function agent() view returns (address)',
  'function challengeWindow() view returns (uint32)',
  'function evidenceCount(uint256 leaseId, address party) view returns (uint256 count)',
  'function getRuling(uint256 leaseId) view returns (Ruling)',

  'function bindEscrow(address escrow_)',
  'function setHuman(address newHuman)',
  'function setAgent(address newAgent)',
  'function setChallengeWindow(uint32 newWindow)',
  'function submitEvidence(uint256 leaseId, string statement)',
  'function appeal(uint256 leaseId)',
  'function propose(uint256 leaseId, uint16 tenantBps, bytes32 rulingHash, uint16 confidenceBps, string summary)',
  'function execute(uint256 leaseId)',
  'function resolveByHuman(uint256 leaseId, uint16 tenantBps)',
])
