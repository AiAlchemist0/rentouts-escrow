import { describe, expect, it } from 'vitest'
import { abstainReasons, abstainWithoutModel, decide, overallConfidence } from '../src/decide.ts'
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

  it('abstains when the weakest answer is below the threshold (and proposes exactly at it)', () => {
    const shaky = answers({ rentClaimValid: { answer: 'no', confidence: 0.69 } })
    expect(overallConfidence(shaky)).toBe(0.69)
    expect(decide(input, shaky, judge, 0.7).ruling.decision).toBe('abstain')
    expect(abstainReasons(shaky, 0.7)[0]).toMatch(/confidence 0\.69 is below the 0\.70 threshold/)
    const atThreshold = answers({ damageBeyondNormalWear: { answer: 'no', confidence: 0.7 } })
    expect(decide(input, atThreshold, judge, 0.7).ruling.decision).toBe('propose')
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
