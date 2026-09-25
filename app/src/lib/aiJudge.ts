import { isAddressEqual, type Address, type Hash } from 'viem'
import { LeaseState } from '../abi/rentEscrow'
import { shortAddress } from './format'

/** Basis points: 10,000 = 100 %. */
export const BPS = 10_000

/** AIArbiter.Status (uint8 on the ABI). */
export const RulingStatus = {
  NONE: 0,
  PROPOSED: 1,
  APPEALED: 2,
  EXECUTED: 3,
  HUMAN_RESOLVED: 4,
} as const

/** AIArbiter.getRuling(leaseId), as viem returns it. */
export type Ruling = {
  status: number
  tenantBps: number
  confidenceBps: number
  proposedAt: bigint
  deadline: bigint
  rulingHash: Hash
}

// ------------------------------------------------------------------ bps <-> %

/** 7500 -> 75, 3333 -> 33.33. Clamped to 0..100. */
export function bpsToPercent(bps: number): number {
  return Math.min(BPS, Math.max(0, bps)) / 100
}

/** 75 -> 7500, 33.33 -> 3333 (nearest basis point). null outside 0..100 % or for NaN. */
export function percentToBps(percent: number): number | null {
  if (!Number.isFinite(percent) || percent < 0 || percent > 100) return null
  // toFixed first, so 12.345 % (1234.4999… in floating point) rounds to 1235 like on paper.
  return Math.round(Number((percent * 100).toFixed(6)))
}

/** 7500 -> "75%", 3333 -> "33.33%", 50 -> "0.5%". */
export function formatBps(bps: number): string {
  return `${bpsToPercent(bps).toFixed(2).replace(/\.?0+$/, '')}%`
}

/** RentEscrow.resolveDispute's payout: the tenant's share rounds down, the landlord gets the rest. */
export function splitEscrow(balance: bigint, tenantBps: number): { toTenant: bigint; toLandlord: bigint } {
  const bps = BigInt(Math.min(BPS, Math.max(0, Math.trunc(tenantBps))))
  const toTenant = (balance * bps) / BigInt(BPS)
  return { toTenant, toLandlord: balance - toTenant }
}

// ------------------------------------------------------------------ state

export type JudgePhase = 'awaiting-evidence' | 'proposed' | 'appealed' | 'executed' | 'human-resolved'

export const PHASE_LABELS: Record<JudgePhase, string> = {
  'awaiting-evidence': 'Awaiting evidence',
  proposed: 'Proposed',
  appealed: 'Appealed',
  executed: 'Executed',
  'human-resolved': 'Resolved by human',
}

const PHASES: Record<number, JudgePhase> = {
  [RulingStatus.NONE]: 'awaiting-evidence',
  [RulingStatus.PROPOSED]: 'proposed',
  [RulingStatus.APPEALED]: 'appealed',
  [RulingStatus.EXECUTED]: 'executed',
  [RulingStatus.HUMAN_RESOLVED]: 'human-resolved',
}

/** Who is looking: the lease's parties, and AIArbiter.human(). */
export type Viewer = { isTenant: boolean; isLandlord: boolean; isHuman: boolean }

export type JudgeView = {
  phase: JudgePhase
  label: string
  /** EXECUTED or HUMAN_RESOLVED: the lease is closed and paid out. */
  final: boolean
  /** A proposal is open and still appealable (now < deadline). */
  windowOpen: boolean
  /** Seconds left in the challenge window (0 once it's over); null without an open proposal. */
  secondsLeft: number | null
  canSubmitEvidence: boolean
  canAppeal: boolean
  canExecute: boolean
  canResolveByHuman: boolean
}

/**
 * What the AI judge panel shows and allows, mirroring AIArbiter's checks: evidence and appeals come from the
 * lease's tenant or landlord; an appeal only before the deadline, execution (by anyone) only from it; the human
 * arbiter rules on any DISPUTED lease, but never on one it is a party to.
 */
export function judgeView({
  leaseState,
  ruling,
  now,
  viewer,
  statementsLeft = Infinity,
}: {
  leaseState: number
  ruling: Ruling | undefined
  now: number
  viewer: Viewer
  /** How many more statements the viewer may submit (MAX_STATEMENTS_PER_PARTY - evidenceCount). */
  statementsLeft?: number
}): JudgeView {
  const status = ruling?.status ?? RulingStatus.NONE
  const phase = PHASES[status] ?? 'awaiting-evidence'
  const disputed = leaseState === LeaseState.DISPUTED
  const party = viewer.isTenant || viewer.isLandlord
  const proposed = status === RulingStatus.PROPOSED
  const deadline = Number(ruling?.deadline ?? 0n)
  const windowOpen = proposed && now < deadline
  const final = status === RulingStatus.EXECUTED || status === RulingStatus.HUMAN_RESOLVED
  return {
    phase,
    label: PHASE_LABELS[phase],
    final,
    windowOpen,
    secondsLeft: proposed ? Math.max(0, deadline - now) : null,
    canSubmitEvidence: disputed && party && statementsLeft > 0,
    canAppeal: disputed && proposed && windowOpen && party,
    canExecute: disputed && proposed && !windowOpen,
    canResolveByHuman: disputed && viewer.isHuman && !party && !final,
  }
}

// ------------------------------------------------------------------ events

export type EvidenceItem = { party: Address; statement: string; txHash?: Hash; key: string }

export type ProposalRecord = {
  agent: Address
  tenantBps: number
  confidenceBps: number
  rulingHash: Hash
  deadline: bigint
  summary: string
  txHash?: Hash
}

export type DisputeLog = {
  evidence: EvidenceItem[]
  /** The Proposed event behind the current ruling (matched by rulingHash), else the latest one. */
  proposal?: ProposalRecord
  /** Proposed events for this lease; more than one means the agent replaced an open proposal. */
  proposals: number
  appealedBy?: Address
}

/** The decoded AIArbiter logs the app reads (viem getLogs with strict: true). */
export type ArbiterLog =
  | { eventName: 'Evidence'; args: { leaseId: bigint; party: Address; statement: string }; transactionHash: Hash | null; logIndex: number | null; blockNumber: bigint | null }
  | {
      eventName: 'Proposed'
      args: { leaseId: bigint; agent: Address; tenantBps: number; confidenceBps: number; rulingHash: Hash; deadline: bigint; summary: string }
      transactionHash: Hash | null
      logIndex: number | null
      blockNumber: bigint | null
    }
  | { eventName: 'Appealed'; args: { leaseId: bigint; by: Address }; transactionHash: Hash | null; logIndex: number | null; blockNumber: bigint | null }

/** One lease's statements, proposal and appeal, in chain order. */
export function disputeLog(logs: readonly ArbiterLog[], leaseId: bigint, rulingHash?: Hash): DisputeLog {
  const ordered = logs
    .filter((log) => log.args.leaseId === leaseId)
    .sort((a, b) => Number((a.blockNumber ?? 0n) - (b.blockNumber ?? 0n)) || (a.logIndex ?? 0) - (b.logIndex ?? 0))
  const evidence: EvidenceItem[] = []
  const proposals: ProposalRecord[] = []
  let appealedBy: Address | undefined
  for (const log of ordered) {
    const txHash = log.transactionHash ?? undefined
    if (log.eventName === 'Evidence') {
      evidence.push({
        party: log.args.party,
        statement: log.args.statement,
        txHash,
        key: `${log.transactionHash ?? log.blockNumber}-${log.logIndex}`,
      })
    } else if (log.eventName === 'Proposed') {
      const { agent, tenantBps, confidenceBps, rulingHash: hash, deadline, summary } = log.args
      proposals.push({ agent, tenantBps, confidenceBps, rulingHash: hash, deadline, summary, txHash })
    } else {
      appealedBy = log.args.by
    }
  }
  const matching = rulingHash ? proposals.filter((p) => p.rulingHash === rulingHash).at(-1) : undefined
  return { evidence, proposal: matching ?? proposals.at(-1), proposals: proposals.length, appealedBy }
}

// ------------------------------------------------------------------ statements

/** UTF-8 bytes, which is what AIArbiter's MAX_STATEMENT_BYTES counts. */
export function statementBytes(text: string): number {
  return new TextEncoder().encode(text).length
}

/** Why submitEvidence would refuse this text, or null. The app sends the trimmed text. */
export function statementProblem(text: string, maxBytes = 1000): string | null {
  const bytes = statementBytes(text.trim())
  if (bytes === 0) return 'Write a statement first.'
  if (bytes > maxBytes) return `${bytes.toLocaleString('en-US')} bytes; the limit is ${maxBytes.toLocaleString('en-US')}. Shorten it.`
  return null
}

// ------------------------------------------------------------------ setup

/**
 * Why AI rulings can't settle this escrow's disputes, or null: AIArbiter must be bound (bindEscrow, once) to
 * this escrow, and this escrow's immutable arbiter must be that AIArbiter.
 */
export function aiArbiterProblem({
  aiArbiter,
  boundEscrow,
  escrow,
  escrowArbiter,
}: {
  aiArbiter: Address
  boundEscrow: Address | undefined
  escrow: Address | undefined
  escrowArbiter: Address | undefined
}): string | null {
  const same = (a: Address, b: Address) => isAddressEqual(a, b)
  if (!boundEscrow) {
    return 'The AI judge contract isn’t bound to an escrow yet: the human arbiter calls bindEscrow(escrow) once.'
  }
  if (escrow && !same(boundEscrow, escrow)) {
    return `The AI judge contract ${shortAddress(aiArbiter)} arbitrates another escrow (${shortAddress(boundEscrow)}), not this one.`
  }
  if (escrowArbiter && !same(escrowArbiter, aiArbiter)) {
    return `This escrow’s arbiter is ${shortAddress(escrowArbiter)}, not the AI judge contract ${shortAddress(aiArbiter)}.`
  }
  return null
}

/**
 * The AIArbiter this page may read rulings from and send transactions to, or the problem that rules it out. Any
 * aiArbiterProblem blocks it: AIArbiter settles a lease id on the escrow *it* is bound to, and lease ids restart
 * at 1 in every escrow, so appeal / execute / resolveByHuman sent through another escrow's AIArbiter could close
 * a different lease, and its getRuling describes that other lease.
 */
export function judgeFor<T extends { address: Address; boundEscrow?: Address }>(
  info: T | undefined,
  escrow: Address | undefined,
  escrowArbiter: Address | undefined,
): { judge?: T; problem?: string } {
  if (!info) return {}
  const problem = aiArbiterProblem({ aiArbiter: info.address, boundEscrow: info.boundEscrow, escrow, escrowArbiter })
  return problem ? { problem } : { judge: info }
}
