import { canonicalHash } from './canonical.ts'
import { computeSplit, potsOf, type Split } from './rubric.ts'
import { occupancyYears, type RulesPackRef } from './rules/tokyo.ts'
import { screenReasons } from './screen.ts'
import type { Address, DisputeInput, Hex, JudgeAnswers, LeaseFacts } from './types.ts'

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
  /**
   * The restoration rules pack the judge was given (id, version, keccak256 of its canonical JSON).
   * Absent on rulings made before the pack, so their hashes are unchanged; when present, the
   * rulingHash commits to it. Off-chain only: the on-chain proposal still carries just the hash.
   */
  rules?: RulesPackRef
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
    /** Rubric v2 (Tokyo rules): per-item charges, amounts in token units. */
    items?: Array<{
      item: string
      material: string
      cause: string
      severity: number
      ageYears: number
      usefulLifeYears: number | null
      tenantShareBps: number
      charge: string
    }>
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

/** The checklist's yes/no questions. */
export type Question = 'evidenceSufficient' | 'damageBeyondNormalWear' | 'rentClaimValid'

/**
 * The answers this dispute's payout rests on. Only these count toward the confidence:
 *   evidenceSufficient      always: it is the judge's own "can this be decided at all".
 *   damageBeyondNormalWear  always: the deposit is what every dispute decides.
 *   rentClaimValid          only when it changes the split, i.e. it is "yes" and there is unearned
 *                           rent in escrow, which then goes to the landlord. A "no" leaves the
 *                           unearned rent with the tenant, exactly where it goes when nobody claims
 *                           it, so its probability decides nothing. (On the damage-admitted demo,
 *                           GLM 5.3 answered "no" at p=0.60 while its rationale said the landlord
 *                           made no rent claim; counting that made the judge abstain on an admitted
 *                           claim.) A rent claim the model cannot settle still abstains through
 *                           evidenceSufficient, which asks about both questions.
 */
export function confidenceBasis(a: JudgeAnswers, lease: Pick<LeaseFacts, 'unearnedRent'>): Question[] {
  const basis: Question[] = ['evidenceSufficient', 'damageBeyondNormalWear']
  if (a.rentClaimValid.answer === 'yes' && BigInt(lease.unearnedRent) > 0n) basis.push('rentClaimValid')
  return basis
}

/**
 * Overall confidence: the weakest answer the payout rests on (see `confidenceBasis`), plus, under the
 * Tokyo rules, every item classified tenant_damage (those move deposit to the landlord; an item left
 * with the landlord is where the deposit goes anyway, like a rent "no").
 */
export function overallConfidence(a: JudgeAnswers, lease: Pick<LeaseFacts, 'unearnedRent'>): number {
  const charged = (a.items ?? []).filter((i) => i.cause === 'tenant_damage').map((i) => i.confidence)
  return Math.min(...confidenceBasis(a, lease).map((q) => a[q].confidence), ...charged)
}

/** Answer sets that contradict themselves go to the human rather than to a split. */
export function consistencyReasons(a: JudgeAnswers): string[] {
  if (!a.items || a.items.length === 0) return []
  const tenantItems = a.items.filter((i) => i.cause === 'tenant_damage')
  if (a.damageBeyondNormalWear.answer === 'yes' && tenantItems.length === 0) {
    return ['answers inconsistent: damage beyond normal wear is "yes" but no claimed item is classified as tenant damage']
  }
  if (a.damageBeyondNormalWear.answer === 'no' && tenantItems.length > 0) {
    return ['answers inconsistent: an item is classified as tenant damage but damage beyond normal wear is "no"']
  }
  return []
}

/**
 * Abstain rules on the answers: no proposal (the case goes to the human arbiter) when the judge says
 * the evidence is insufficient, or when an answer the payout rests on has a confidence below
 * `minConfidence`. decide() adds the code-level screen of the statements (screen.ts).
 */
export function abstainReasons(a: JudgeAnswers, lease: Pick<LeaseFacts, 'unearnedRent'>, minConfidence: number): string[] {
  const reasons: string[] = []
  if (a.evidenceSufficient.answer === 'no') reasons.push('evidence insufficient to decide')
  const c = overallConfidence(a, lease)
  if (c < minConfidence) reasons.push(`confidence ${c.toFixed(2)} is below the ${minConfidence.toFixed(2)} threshold`)
  reasons.push(...consistencyReasons(a))
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
  opts: { rules?: RulesPackRef } = {},
): Decision {
  const split = computeSplit(potsOf(input.lease), answers, { occupancyYears: occupancyYears(input.lease) })
  // The screen runs for every provider: a model that obeys an injected instruction still abstains.
  const reasons = [...abstainReasons(answers, input.lease, minConfidence), ...screenReasons(input)]
  const propose = reasons.length === 0
  const ruling: Ruling = {
    ...base(input, judge, minConfidence),
    ...(opts.rules ? { rules: opts.rules } : {}),
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
      ...(split.items ? { items: split.items.map((i) => ({ ...i, charge: i.charge.toString() })) } : {}),
    },
    confidenceBps: toBps(overallConfidence(answers, input.lease)),
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
