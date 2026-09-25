import { describe, expect, it } from 'vitest'
import { abstainReasons, abstainWithoutModel, confidenceBasis, decide, overallConfidence } from '../src/decide.ts'
import { answers, fixture } from './helpers.ts'

const judge = { provider: 'mock', model: 'test' }
const input = fixture('no-claims')

describe('abstain logic', () => {
  it('proposes when the evidence is sufficient and every answer is confident enough', () => {
    const d = decide(input, answers(), judge, 0.7)
    expect(d.ruling.decision).toBe('propose')
    expect(d.ruling.tenantBps).toBe(7500)
    expect(d.ruling.confidenceBps).toBe(9000)
    expect(d.ruling.abstainReasons).toEqual([])
  })

  it('abstains when the judge says the evidence is insufficient, however confident', () => {
    const d = decide(input, answers({ evidenceSufficient: { answer: 'no', confidence: 0.99 } }), judge, 0.7)
    expect(d.ruling.decision).toBe('abstain')
    expect(d.ruling.tenantBps).toBeNull()
    expect(d.ruling.abstainReasons).toContain('evidence insufficient to decide')
    expect(d.ruling.rubric?.tenantBps).toBe(7500) // what the rubric would have said, for the human
  })

  it('abstains when an answer the payout rests on is below the threshold (and proposes exactly at it)', () => {
    const shakyDamage = answers({ damageBeyondNormalWear: { answer: 'no', confidence: 0.69 } })
    expect(overallConfidence(shakyDamage, input.lease)).toBe(0.69)
    expect(decide(input, shakyDamage, judge, 0.7).ruling.decision).toBe('abstain')
    expect(abstainReasons(shakyDamage, input.lease, 0.7)[0]).toMatch(/confidence 0\.69 is below the 0\.70 threshold/)
    const shakyEvidence = answers({ evidenceSufficient: { answer: 'yes', confidence: 0.69 } })
    expect(decide(input, shakyEvidence, judge, 0.7).ruling.decision).toBe('abstain')
    const atThreshold = answers({ damageBeyondNormalWear: { answer: 'no', confidence: 0.7 } })
    expect(decide(input, atThreshold, judge, 0.7).ruling.decision).toBe('propose')
  })

  it('evidenceSufficient and damageBeyondNormalWear always count toward the confidence', () => {
    expect(confidenceBasis(answers(), input.lease)).toEqual(['evidenceSufficient', 'damageBeyondNormalWear'])
    const shakyYes = answers({ damageBeyondNormalWear: { answer: 'yes', confidence: 0.6 }, severity: 2 })
    expect(decide(input, shakyYes, judge, 0.7).ruling.decision).toBe('abstain')
  })

  it('rentClaimValid "no" does not count: it leaves the unearned rent with the tenant, as when nobody claims it', () => {
    const unsureNo = answers({ rentClaimValid: { answer: 'no', confidence: 0.3 } })
    expect(confidenceBasis(unsureNo, input.lease)).not.toContain('rentClaimValid')
    const d = decide(input, unsureNo, judge, 0.7)
    expect(d.ruling.decision).toBe('propose')
    expect(d.ruling.confidenceBps).toBe(9000)
    expect(d.ruling.rubric?.unearnedRentToTenant).toBe(input.lease.unearnedRent)
    expect(d.ruling.tenantBps).toBe(decide(input, answers(), judge, 0.7).ruling.tenantBps)
  })

  it('rentClaimValid "yes" counts when there is unearned rent to move to the landlord', () => {
    const shakyYes = answers({ rentClaimValid: { answer: 'yes', confidence: 0.69 } })
    expect(confidenceBasis(shakyYes, input.lease)).toContain('rentClaimValid')
    const d = decide(input, shakyYes, judge, 0.7)
    expect(d.ruling.decision).toBe('abstain')
    expect(d.ruling.abstainReasons).toEqual(['confidence 0.69 is below the 0.70 threshold'])
    expect(d.ruling.rubric?.unearnedRentToTenant).toBe('0')
    const sureYes = answers({ rentClaimValid: { answer: 'yes', confidence: 0.8 } })
    expect(decide(input, sureYes, judge, 0.7).ruling).toMatchObject({ decision: 'propose', tenantBps: 5000, confidenceBps: 8000 })
  })

  it('rentClaimValid "yes" does not count when no unearned rent is left (it moves nothing)', () => {
    const lease = { ...input.lease, unearnedRent: '0', remainingEscrow: '400000' }
    const shakyYes = answers({ rentClaimValid: { answer: 'yes', confidence: 0.5 } })
    expect(confidenceBasis(shakyYes, lease)).toEqual(['evidenceSufficient', 'damageBeyondNormalWear'])
    expect(decide({ ...input, lease }, shakyYes, judge, 0.7).ruling.decision).toBe('propose')
  })

  it('the threshold is configurable (JUDGE_MIN_CONFIDENCE)', () => {
    expect(decide(input, answers(), judge, 0.95).ruling.decision).toBe('abstain')
    expect(decide(input, answers(), judge, 0.95).ruling.minConfidenceBps).toBe(9500)
  })

  it('no statements at all: abstains without asking a model', () => {
    const d = abstainWithoutModel({ ...input, evidence: [] }, judge, 0.7, 'no statements from either party')
    expect(d.ruling.decision).toBe('abstain')
    expect(d.ruling.answers).toBeNull()
    expect(d.ruling.tenantBps).toBeNull()
    expect(d.rulingHash).toMatch(/^0x[0-9a-f]{64}$/)
  })
})
