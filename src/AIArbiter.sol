// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRentEscrow} from "./interfaces/IRentEscrow.sol";

/// @title AIArbiter
/// @notice RentEscrow's arbiter: an AI judge proposes, a human has the last word.
///
///         Roles:
///         - `agent`: the AI judge service's key (judge/ in this repo). It can only PROPOSE a split
///           for a disputed lease, never resolve one. address(0) switches AI proposals off.
///         - `human`: the human arbiter (an EOA on testnet, a Safe in production). It can resolve
///           any disputed lease directly, at any time, with or without a proposal (this overrides
///           a proposal that has not been executed yet), and it sets the agent and the challenge
///           window. It hands its own role over in two steps (setHuman, then acceptHuman by the
///           new address), because an appealed lease can only ever be closed by the human.
///
///         Flow:
///           escrow.openDispute (tenant or landlord)
///           -> submitEvidence (tenant / landlord, short text statements, optional)
///           -> propose (agent: tenantBps, rulingHash, confidence, summary)
///           -> challenge window -> execute (anyone) -> escrow.resolveDispute(leaseId, tenantBps)
///                              \-> appeal (tenant / landlord, inside the window) -> resolveByHuman
///           resolveByHuman (human) works at any point while the lease is DISPUTED.
///
///         One proposal per lease. While its window is still open the agent may replace it (a new
///         ruling restarts the window, so the parties always get a full window on what would be
///         executed); once the window is over it can only be executed or overridden by the human,
///         and once appealed only the human can rule.
///
///         Deployment: RentEscrow's `arbiter` is immutable, so this contract is deployed FIRST, then
///         the escrow with arbiter = address(this), then the human calls bindEscrow(escrow) once.
///
///         Invariant AI-1 (test/AIArbiter.invariant.t.sol): the only state-changing call this
///         contract ever makes is `escrow.resolveDispute(leaseId, tenantBps)` on the bound escrow;
///         its other external calls are views on that same escrow (arbiter, getLease). It holds no
///         tokens and has no approvals. So even if the agent key, the human key or both are
///         compromised, the worst outcome is a wrong split of one disputed lease's own escrow
///         between that lease's tenant and landlord (RentEscrow INV-1 / INV-4): never theft, never a
///         payout to anyone else.
/// @dev    Built for ETHGlobal Tokyo 2026 (Ethereum Sepolia). Testnet only, not audited.
contract AIArbiter is ReentrancyGuard {
    /// @notice Where a lease's dispute stands in this contract.
    enum Status {
        NONE, // no proposal yet (the human may still resolve directly)
        PROPOSED, // the agent proposed; appealable until `deadline`, executable from `deadline`
        APPEALED, // a party appealed in time: only the human can rule now
        EXECUTED, // the proposal was executed after the window: lease CLOSED
        HUMAN_RESOLVED // the human ruled (directly or overriding a proposal): lease CLOSED
    }

    /// @notice A lease's ruling. `tenantBps` is the final split once EXECUTED / HUMAN_RESOLVED, the
    ///         proposed one before. `confidenceBps`, `proposedAt`, `deadline` and `rulingHash`
    ///         describe the agent's latest proposal (zero if it never proposed); a human ruling keeps
    ///         them as the record of what the AI had said.
    struct Ruling {
        Status status;
        uint16 tenantBps;
        uint16 confidenceBps;
        uint64 proposedAt;
        uint64 deadline;
        bytes32 rulingHash; // keccak256 of the judge's canonical JSON ruling (judge/README.md)
    }

    uint32 public constant MIN_CHALLENGE_WINDOW = 60; // 1 minute: live demos
    uint32 public constant MAX_CHALLENGE_WINDOW = 30 days;
    uint256 public constant MAX_STATEMENT_BYTES = 1000;
    uint256 public constant MAX_STATEMENTS_PER_PARTY = 5; // bounds what the judge has to read
    uint256 public constant MAX_SUMMARY_BYTES = 1000;
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice The RentEscrow whose immutable arbiter is this contract; zero until bindEscrow.
    IRentEscrow public escrow;
    address public human;
    /// @notice The address setHuman nominated; it becomes `human` only when it calls acceptHuman.
    address public pendingHuman;
    /// @notice The AI judge service key; address(0) = AI proposals off.
    address public agent;
    /// @notice Seconds a proposal stays appealable. Applies to proposals made after it is set.
    uint32 public challengeWindow;

    mapping(uint256 leaseId => Ruling) internal _rulings;
    /// @notice Statements submitted per lease and party (at most MAX_STATEMENTS_PER_PARTY).
    mapping(uint256 leaseId => mapping(address party => uint256 count)) public evidenceCount;

    event EscrowBound(address indexed escrow);
    /// @notice setHuman nominated `pendingHuman` (address(0): a pending handover was cancelled).
    event HumanTransferStarted(address indexed currentHuman, address indexed pendingHuman);
    event HumanUpdated(address indexed previousHuman, address indexed newHuman);
    event AgentUpdated(address indexed previousAgent, address indexed newAgent);
    event ChallengeWindowUpdated(uint32 previousWindow, uint32 newWindow);
    /// @notice A party's statement. Untrusted text: the judge treats it as a claim, not as a fact.
    event Evidence(uint256 indexed leaseId, address indexed party, string statement);
    event Proposed(
        uint256 indexed leaseId,
        address indexed agent,
        uint16 tenantBps,
        uint16 confidenceBps,
        bytes32 rulingHash,
        uint64 deadline,
        string summary
    );
    /// @notice Emitted before the Proposed event of a proposal that replaces an open one.
    event ProposalReplaced(uint256 indexed leaseId, uint16 previousTenantBps, bytes32 previousRulingHash);
    event Appealed(uint256 indexed leaseId, address indexed by);
    event Executed(uint256 indexed leaseId, uint16 tenantBps, address indexed by);
    /// @notice `previous` is the status the human ruled over (NONE: direct; PROPOSED / APPEALED: override).
    event HumanResolved(uint256 indexed leaseId, uint16 tenantBps, address indexed human, Status previous);

    error ZeroAddress();
    error NotHuman();
    error NotPendingHuman();
    error NotAgent();
    error NotParty(uint256 leaseId);
    /// @notice The agent or the human is the lease's own tenant or landlord.
    error PartyCannotArbitrate(uint256 leaseId, address account);
    error EscrowNotBound();
    error EscrowAlreadyBound(address escrow);
    /// @notice The address is not a RentEscrow whose arbiter is this contract.
    error NotEscrowArbiter(address escrow);
    error InvalidChallengeWindow(uint32 window);
    error InvalidBps(uint16 bps);
    error NotDisputed(uint256 leaseId, IRentEscrow.State state);
    error InvalidStatementLength(uint256 length);
    error TooManyStatements(uint256 leaseId, address party);
    error SummaryTooLong(uint256 length);
    /// @notice There is no appealable / executable proposal for the lease.
    error NoOpenProposal(uint256 leaseId, Status status);
    /// @notice The lease's proposal was appealed (or is final): the agent cannot propose again.
    error ProposalLocked(uint256 leaseId, Status status);
    error ChallengeWindowOver(uint256 leaseId, uint64 deadline);
    error ChallengeWindowOpen(uint256 leaseId, uint64 deadline);

    modifier onlyHuman() {
        if (msg.sender != human) revert NotHuman();
        _;
    }

    /// @param human_           human arbiter (EOA or Safe); never zero
    /// @param agent_           AI judge service key; address(0) = AI proposals off until setAgent
    /// @param challengeWindow_ seconds a proposal stays appealable (MIN..MAX_CHALLENGE_WINDOW)
    // forge-lint: disable-next-item(missing-zero-check) -- agent_ == address(0) means "AI off"
    constructor(address human_, address agent_, uint32 challengeWindow_) {
        if (human_ == address(0)) revert ZeroAddress();
        _checkWindow(challengeWindow_);
        human = human_;
        agent = agent_;
        challengeWindow = challengeWindow_;
        emit HumanUpdated(address(0), human_);
        emit AgentUpdated(address(0), agent_);
        emit ChallengeWindowUpdated(0, challengeWindow_);
    }

    // ------------------------------------------------------------------ views

    function getRuling(uint256 leaseId) external view returns (Ruling memory) {
        return _rulings[leaseId];
    }

    // ------------------------------------------------------------------ setup (human)

    /// @notice Binds the escrow this contract arbitrates. Once, by the human, and only to an escrow
    ///         whose immutable arbiter is this contract.
    function bindEscrow(IRentEscrow escrow_) external onlyHuman {
        if (address(escrow) != address(0)) revert EscrowAlreadyBound(address(escrow));
        if (address(escrow_).code.length == 0) revert NotEscrowArbiter(address(escrow_));
        try escrow_.arbiter() returns (address a) {
            if (a != address(this)) revert NotEscrowArbiter(address(escrow_));
        } catch {
            revert NotEscrowArbiter(address(escrow_));
        }
        escrow = escrow_;
        emit EscrowBound(address(escrow_));
    }

    /// @notice Step 1 of handing the human role to `newHuman` (e.g. from a testnet EOA to a Safe).
    ///         The current human keeps the role until `newHuman` calls acceptHuman, so a mistyped
    ///         address cannot strand appealed leases (only the human can close those, and
    ///         RentEscrow's arbiter is immutable). A new call replaces the nominee; address(0)
    ///         cancels.
    // forge-lint: disable-next-item(missing-zero-check) -- address(0) cancels a pending handover
    function setHuman(address newHuman) external onlyHuman {
        pendingHuman = newHuman;
        emit HumanTransferStarted(human, newHuman);
    }

    /// @notice Step 2: the address setHuman nominated takes the human role.
    function acceptHuman() external {
        address newHuman = pendingHuman;
        if (newHuman == address(0) || msg.sender != newHuman) revert NotPendingHuman();
        address previous = human;
        human = newHuman;
        pendingHuman = address(0);
        emit HumanUpdated(previous, newHuman);
    }

    /// @notice Rotates the AI judge key; address(0) switches AI proposals off.
    // forge-lint: disable-next-item(missing-zero-check) -- address(0) means "AI off"
    function setAgent(address newAgent) external onlyHuman {
        address previous = agent;
        agent = newAgent;
        emit AgentUpdated(previous, newAgent);
    }

    /// @notice Sets the challenge window for proposals made from now on (open ones keep theirs).
    function setChallengeWindow(uint32 newWindow) external onlyHuman {
        _checkWindow(newWindow);
        uint32 previous = challengeWindow;
        challengeWindow = newWindow;
        emit ChallengeWindowUpdated(previous, newWindow);
    }

    // ------------------------------------------------------------------ parties

    /// @notice A short statement by the lease's tenant or landlord while the lease is DISPUTED.
    ///         Up to MAX_STATEMENTS_PER_PARTY statements of 1..MAX_STATEMENT_BYTES bytes each.
    ///         Stored only in the event log. Anyone can write anything here: the judge reads it as
    ///         a party's claim, never as an established fact or as an instruction.
    function submitEvidence(uint256 leaseId, string calldata statement) external {
        IRentEscrow.Lease memory l = _disputedLease(leaseId);
        if (msg.sender != l.tenant && msg.sender != l.landlord) revert NotParty(leaseId);
        uint256 len = bytes(statement).length;
        if (len == 0 || len > MAX_STATEMENT_BYTES) revert InvalidStatementLength(len);
        uint256 n = evidenceCount[leaseId][msg.sender];
        if (n >= MAX_STATEMENTS_PER_PARTY) revert TooManyStatements(leaseId, msg.sender);
        evidenceCount[leaseId][msg.sender] = n + 1;
        emit Evidence(leaseId, msg.sender, statement);
    }

    /// @notice Tenant or landlord sends an open proposal to the human arbiter, inside its window.
    ///         An appealed proposal can never be executed; only resolveByHuman closes the lease.
    // forge-lint: disable-next-item(block-timestamp) -- windows are >= 60 s
    function appeal(uint256 leaseId) external {
        Ruling storage r = _rulings[leaseId];
        if (r.status != Status.PROPOSED) revert NoOpenProposal(leaseId, r.status);
        if (block.timestamp >= r.deadline) revert ChallengeWindowOver(leaseId, r.deadline);
        // PROPOSED implies a bound escrow and a lease that is still DISPUTED.
        IRentEscrow.Lease memory l = escrow.getLease(leaseId);
        if (msg.sender != l.tenant && msg.sender != l.landlord) revert NotParty(leaseId);
        r.status = Status.APPEALED;
        emit Appealed(leaseId, msg.sender);
    }

    // ------------------------------------------------------------------ agent

    /// @notice The AI judge proposes `tenantBps` for a DISPUTED lease. `rulingHash` commits to the
    ///         judge's full canonical ruling (inputs, answers, rubric, model), `confidenceBps` is its
    ///         confidence (0..10000) and `summary` a short plain-language rationale. Replaces an open
    ///         proposal only while that proposal's window is still running (the window restarts).
    // forge-lint: disable-next-item(block-timestamp) -- windows are >= 60 s
    function propose(
        uint256 leaseId,
        uint16 tenantBps,
        bytes32 rulingHash,
        uint16 confidenceBps,
        string calldata summary
    ) external {
        if (msg.sender != agent) revert NotAgent(); // agent == address(0): nobody can propose
        IRentEscrow.Lease memory l = _disputedLease(leaseId);
        if (msg.sender == l.tenant || msg.sender == l.landlord) revert PartyCannotArbitrate(leaseId, msg.sender);
        if (tenantBps > BPS_DENOMINATOR) revert InvalidBps(tenantBps);
        if (confidenceBps > BPS_DENOMINATOR) revert InvalidBps(confidenceBps);
        if (bytes(summary).length > MAX_SUMMARY_BYTES) revert SummaryTooLong(bytes(summary).length);

        Ruling storage r = _rulings[leaseId];
        if (r.status == Status.PROPOSED) {
            if (block.timestamp >= r.deadline) revert ChallengeWindowOver(leaseId, r.deadline);
            emit ProposalReplaced(leaseId, r.tenantBps, r.rulingHash);
        } else if (r.status != Status.NONE) {
            revert ProposalLocked(leaseId, r.status); // APPEALED (a closed lease fails _disputedLease)
        }

        // casting to 'uint64' is safe because timestamps fit in 64 bits for ~5e11 years
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nowTs = uint64(block.timestamp);
        uint64 deadline = nowTs + challengeWindow;
        r.status = Status.PROPOSED;
        r.tenantBps = tenantBps;
        r.confidenceBps = confidenceBps;
        r.proposedAt = nowTs;
        r.deadline = deadline;
        r.rulingHash = rulingHash;
        emit Proposed(leaseId, msg.sender, tenantBps, confidenceBps, rulingHash, deadline, summary);
    }

    // ------------------------------------------------------------------ resolution

    /// @notice Anyone executes an unappealed proposal once its challenge window is over:
    ///         escrow.resolveDispute(leaseId, proposed tenantBps).
    // forge-lint: disable-next-item(block-timestamp) -- windows are >= 60 s
    function execute(uint256 leaseId) external nonReentrant {
        Ruling storage r = _rulings[leaseId];
        if (r.status != Status.PROPOSED) revert NoOpenProposal(leaseId, r.status);
        if (block.timestamp < r.deadline) revert ChallengeWindowOpen(leaseId, r.deadline);
        uint16 bps = r.tenantBps;
        r.status = Status.EXECUTED;
        emit Executed(leaseId, bps, msg.sender);
        // every state write is above; the lint means ReentrancyGuard's own _status
        // forge-lint: disable-next-line(reentrancy-no-eth)
        escrow.resolveDispute(leaseId, bps);
    }

    /// @notice The human arbiter rules on a DISPUTED lease: directly, after an appeal, or overriding
    ///         a proposal that has not been executed (inside or after its window).
    function resolveByHuman(uint256 leaseId, uint16 tenantBps) external nonReentrant onlyHuman {
        IRentEscrow.Lease memory l = _disputedLease(leaseId);
        if (msg.sender == l.tenant || msg.sender == l.landlord) revert PartyCannotArbitrate(leaseId, msg.sender);
        if (tenantBps > BPS_DENOMINATOR) revert InvalidBps(tenantBps);
        Ruling storage r = _rulings[leaseId];
        Status previous = r.status;
        r.status = Status.HUMAN_RESOLVED;
        r.tenantBps = tenantBps;
        emit HumanResolved(leaseId, tenantBps, msg.sender, previous);
        // every state write is above; the lint means ReentrancyGuard's own _status
        // forge-lint: disable-next-line(reentrancy-no-eth)
        escrow.resolveDispute(leaseId, tenantBps);
    }

    // ------------------------------------------------------------------ internal

    function _disputedLease(uint256 leaseId) internal view returns (IRentEscrow.Lease memory l) {
        IRentEscrow e = escrow;
        if (address(e) == address(0)) revert EscrowNotBound();
        l = e.getLease(leaseId);
        if (l.state != IRentEscrow.State.DISPUTED) revert NotDisputed(leaseId, l.state);
    }

    function _checkWindow(uint32 window) internal pure {
        if (window < MIN_CHALLENGE_WINDOW || window > MAX_CHALLENGE_WINDOW) revert InvalidChallengeWindow(window);
    }
}
