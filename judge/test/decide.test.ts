import { describe, expect, it } from 'vitest'
import { abstainReasons, abstainWithoutModel, confidenceBasis, decide, overallConfidence } from '../src/decide.ts'
import { SYSTEM_PROMPT } from '../src/prompt.ts'
import { mockAnswers } from '../src/providers/mock.ts'
import { screenReasons } from '../src/screen.ts'
import type { DisputeInput, Party } from '../src/types.ts'
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

describe('one-sided evidence: silence is not an admission', () => {
  /** damage-admitted with only the given party's statements. */
  function onlyFrom(party: Party, statement: string): DisputeInput {
    const base = fixture('damage-admitted')
    const e = base.evidence.find((x) => x.party === party)!
    return { ...base, evidence: [{ ...e, id: 'E1', statement }] }
  }
  const landlordOnly = onlyFrom('landlord', 'The tenant destroyed the flat and left without notice.')
  const glmJudge = { provider: 'glm', model: 'glm-5.3' }

  it('the prompt no longer counts an uncontested claim as established when the other side posted nothing', () => {
    expect(SYSTEM_PROMPT).not.toMatch(/admits it or does not contest it/)
    expect(SYSTEM_PROMPT).toMatch(/Silence is not\s+an admission: if the party a claim is against has posted no statement at all, the evidence is\s+NOT sufficient/)
  })

  it('a confident "yes, the whole deposit" on a landlord-only case abstains in code (whatever the model answered)', () => {
    const sure = answers({
      damageBeyondNormalWear: { answer: 'yes', confidence: 0.9 },
      rentClaimValid: { answer: 'yes', confidence: 0.9 },
      evidenceSufficient: { answer: 'yes', confidence: 0.85 },
      severity: 5,
    })
    const d = decide(landlordOnly, sure, glmJudge, 0.7)
    expect(d.ruling.decision).toBe('abstain')
    expect(d.ruling.tenantBps).toBeNull()
    expect(d.ruling.abstainReasons).toEqual(["only the landlord has posted a statement; the tenant's silence is not an admission"])
    expect(d.ruling.rubric?.tenantBps).toBe(0) // what a first mover would have got
  })

  it('the mock gives the same answer as the prompt: evidence insufficient', () => {
    const a = mockAnswers(landlordOnly)
    expect(a.evidenceSufficient.answer).toBe('no')
    expect(a.rationale).toMatch(/silence is not an admission/)
    expect(decide(landlordOnly, a, { provider: 'mock', model: 'mock-keywords-v1' }, 0.7).ruling.decision).toBe('abstain')
  })

  it('applies to either side, and never to a case where both have posted', () => {
    expect(screenReasons(onlyFrom('tenant', 'Please return my deposit.'))).toEqual([
      "only the tenant has posted a statement; the landlord's silence is not an admission",
    ])
    expect(screenReasons({ ...landlordOnly, evidence: [] })).toEqual(['no statement from either party'])
    for (const name of ['damage-admitted', 'contested', 'no-claims', 'injection']) {
      expect(screenReasons(fixture(name)).filter((r) => /silence|either party/.test(r)), name).toEqual([])
    }
  })
})
