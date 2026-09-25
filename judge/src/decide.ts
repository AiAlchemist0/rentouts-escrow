import { canonicalHash } from './canonical.ts'
import { computeSplit, potsOf, type Split } from './rubric.ts'
import type { Address, DisputeInput, Hex, JudgeAnswers } from './types.ts'

export const RULING_KIND = 'rentouts.ai-ruling' as const

/**
 * The ruling record. Its canonical JSON is what `rulingHash` (sent on-chain with the proposal)
 * commits to. It contains no timestamps or latencies, so the same input and the same answers
 * always give the same hash; `inputHash` commits to every lease fact and every statement read.
 */
export interface Ruling {
  kind: typeof RULING_KIND
  version: 1
  chainId: number
  escrow: Address
  arbiter: Address
  leaseId: string
  inputHash: Hex
  evidenceCount: number
  judge: { provider: string; model: string }
  answers: JudgeAnswers | null
  rubric: {
    version: string
    remainingEscrow: string
    depositKept: string
    depositReturned: string
    earnedRentToLandlord: string
    unearnedRentToTenant: string
    tenantAmount: string
    exactBps: number
    tenantBps: number
  } | null
  confidenceBps: number
  minConfidenceBps: number
  decision: 'propose' | 'abstain'
  abstainReasons: string[]
  /** The proposed split; null when the judge abstains. */
  tenantBps: number | null
}

export interface Decision {
  ruling: Ruling
  rulingHash: Hex
  split: Split | null
}

/** Overall confidence: the weakest of the three yes/no answers. */
export function overallConfidence(a: JudgeAnswers): number {
  return Math.min(a.damageBeyondNormalWear.confidence, a.rentClaimValid.confidence, a.evidenceSufficient.confidence)
}

/**
 * Abstain rules: no proposal (the case goes to the human arbiter) when the judge says the evidence
 * is insufficient, or when any answer's confidence is below `minConfidence`.
 */
export function abstainReasons(a: JudgeAnswers, minConfidence: number): string[] {
  const reasons: string[] = []
  if (a.evidenceSufficient.answer === 'no') reasons.push('evidence insufficient to decide')
  const c = overallConfidence(a)
  if (c < minConfidence) reasons.push(`confidence ${c.toFixed(2)} is below the ${minConfidence.toFixed(2)} threshold`)
  return reasons
}

function base(input: DisputeInput, judge: { provider: string; model: string }, minConfidence: number) {
  return {
    kind: RULING_KIND,
    version: 1 as const,
    chainId: input.chainId,
    escrow: input.escrow,
    arbiter: input.arbiter,
    leaseId: input.lease.leaseId,
    inputHash: canonicalHash(input),
    evidenceCount: input.evidence.length,
    judge,
    minConfidenceBps: toBps(minConfidence),
  }
}

export function decide(
  input: DisputeInput,
  answers: JudgeAnswers,
  judge: { provider: string; model: string },
  minConfidence: number,
): Decision {
  const split = computeSplit(potsOf(input.lease), answers)
  const reasons = abstainReasons(answers, minConfidence)
  const propose = reasons.length === 0
  const ruling: Ruling = {
    ...base(input, judge, minConfidence),
    answers,
    rubric: {
      version: split.version,
      remainingEscrow: split.remainingEscrow.toString(),
      depositKept: split.depositKept.toString(),
      depositReturned: split.depositReturned.toString(),
      earnedRentToLandlord: split.earnedRentToLandlord.toString(),
      unearnedRentToTenant: split.unearnedRentToTenant.toString(),
      tenantAmount: split.tenantAmount.toString(),
      exactBps: split.exactBps,
      tenantBps: split.tenantBps,
    },
    confidenceBps: toBps(overallConfidence(answers)),
    decision: propose ? 'propose' : 'abstain',
    abstainReasons: reasons,
    tenantBps: propose ? split.tenantBps : null,
  }
  return { ruling, rulingHash: canonicalHash(ruling), split }
}

/** A ruling made without asking a model (e.g. no statements at all): always an abstention. */
export function abstainWithoutModel(
  input: DisputeInput,
  judge: { provider: string; model: string },
  minConfidence: number,
  reason: string,
): Decision {
  const ruling: Ruling = {
    ...base(input, judge, minConfidence),
    answers: null,
    rubric: null,
    confidenceBps: 0,
    decision: 'abstain',
    abstainReasons: [reason],
    tenantBps: null,
  }
  return { ruling, rulingHash: canonicalHash(ruling), split: null }
}

function toBps(p: number): number {
  return Math.round(Math.min(1, Math.max(0, p)) * 10_000)
}
