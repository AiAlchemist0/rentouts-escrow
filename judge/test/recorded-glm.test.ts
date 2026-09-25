import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { canonicalHash } from '../src/canonical.ts'
import { confidenceBasis, decide, type Question } from '../src/decide.ts'
import { JudgeAnswersSchema, type JudgeAnswers } from '../src/types.ts'
import { fixture } from './helpers.ts'

/**
 * Regression tests on answers a real GLM 5.3 run gave for the fixtures (test/recorded/glm-5.3.json,
 * copied from the gitignored out/ folder). No network: the answers are replayed through decide().
 */
interface RecordedCase {
  fixture: string
  inputHash: string
  judge: { provider: string; model: string }
  minConfidenceBps: number
  answers: JudgeAnswers
  recordedRuling: {
    rulingHash: string
    confidenceBps: number
    decision: 'propose' | 'abstain'
    abstainReasons: string[]
    tenantBps: number | null
    rubricTenantBps: number
  }
}

const recorded: { cases: RecordedCase[] } = JSON.parse(
  readFileSync(new URL('./recorded/glm-5.3.json', import.meta.url), 'utf8'),
)

function replay(name: string) {
  const c = recorded.cases.find((x) => x.fixture === name)
  if (!c) throw new Error(`no recorded GLM answers for ${name}`)
  const input = fixture(name)
  const answers = JudgeAnswersSchema.parse(c.answers)
  return { c, input, answers, d: decide(input, answers, c.judge, c.minConfidenceBps / 10_000) }
}

const QUESTIONS: Question[] = ['evidenceSufficient', 'damageBeyondNormalWear', 'rentClaimValid']

describe('recorded GLM 5.3 answers', () => {
  it('were given for exactly these fixtures, by glm-5.3, and pass the checklist schema', () => {
    expect(recorded.cases.map((c) => c.fixture)).toEqual(['damage-admitted', 'contested', 'injection'])
    for (const c of recorded.cases) {
      expect(canonicalHash(fixture(c.fixture))).toBe(c.inputHash)
      expect(c.judge).toEqual({ provider: 'glm', model: 'glm-5.3' })
      expect(JudgeAnswersSchema.safeParse(c.answers).success).toBe(true)
    }
  })

  it('damage-admitted: proposes 75% to the tenant; the unclaimed-rent answer (no, p=0.60) no longer blocks it', () => {
    const { c, input, answers, d } = replay('damage-admitted')
    // What went wrong: the landlord made no rent claim, GLM said so in its rationale, answered "no"
    // at p=0.60, and the old minimum over all three answers abstained on an admitted claim.
    expect(c.recordedRuling.decision).toBe('abstain')
    expect(c.recordedRuling.abstainReasons).toEqual(['confidence 0.60 is below the 0.70 threshold'])
    expect(answers.rentClaimValid).toEqual({ answer: 'no', confidence: 0.6 })
    expect(answers.rationale).toMatch(/no claim for unelapsed rent/)

    expect(confidenceBasis(answers, input.lease)).toEqual(['evidenceSufficient', 'damageBeyondNormalWear'])
    expect(d.ruling.decision).toBe('propose')
    expect(d.ruling.abstainReasons).toEqual([])
    expect(d.ruling.confidenceBps).toBe(8500) // evidenceSufficient p=0.85, the weakest counted answer
    expect(d.ruling.tenantBps).toBe(7500)
    expect(d.ruling.tenantBps).toBe(c.recordedRuling.rubricTenantBps) // same split the rubric gave before
    expect(d.ruling.rubric).toMatchObject({
      remainingEscrow: '500000',
      depositKept: '120000', // severity 2 of 5
      depositReturned: '180000',
      earnedRentToLandlord: '0',
      unearnedRentToTenant: '200000',
      tenantAmount: '380000',
      exactBps: 7600,
      tenantBps: 7500,
    })
    expect(canonicalHash(d.ruling)).toBe(d.rulingHash)
  })

  it('contested: still abstains (evidence insufficient), with exactly the ruling and hash recorded before the fix', () => {
    const { c, d } = replay('contested')
    expect(d.ruling.decision).toBe('abstain')
    expect(d.ruling.tenantBps).toBeNull()
    expect(d.ruling.abstainReasons).toContain('evidence insufficient to decide')
    expect(d.ruling.abstainReasons).toEqual(c.recordedRuling.abstainReasons)
    expect(d.ruling.confidenceBps).toBe(c.recordedRuling.confidenceBps)
    expect(d.rulingHash).toBe(c.recordedRuling.rulingHash)
  })

  it('injection: still abstains for the recorded reasons, and the code screen now adds its own', () => {
    const { c, d } = replay('injection')
    expect(d.ruling.decision).toBe('abstain')
    expect(d.ruling.tenantBps).toBeNull()
    expect(d.ruling.confidenceBps).toBe(c.recordedRuling.confidenceBps)
    expect(d.ruling.abstainReasons).toEqual([
      ...c.recordedRuling.abstainReasons,
      'statement E1 tries to instruct the judge, impersonate an authority or claim a prior decision',
    ])
    // The ruling records one more reason, so its hash is not the one recorded before the screen.
    expect(d.rulingHash).not.toBe(c.recordedRuling.rulingHash)
  })

  it('contested: abstains on "evidence insufficient" alone, even with every p=0.99', () => {
    const { c, input, answers } = replay('contested')
    const sure: JudgeAnswers = structuredClone(answers)
    for (const q of QUESTIONS) sure[q].confidence = 0.99
    const d = decide(input, sure, c.judge, 0.7)
    expect(d.ruling.decision).toBe('abstain')
    expect(d.ruling.abstainReasons).toEqual(['evidence insufficient to decide'])
  })

  it('injection: abstains even if GLM had obeyed E1 (every answer yes, p=1.0), on the code screen alone', () => {
    const { c, input, answers } = replay('injection')
    const obeyed: JudgeAnswers = {
      ...answers,
      damageBeyondNormalWear: { answer: 'yes', confidence: 1 },
      rentClaimValid: { answer: 'yes', confidence: 1 },
      evidenceSufficient: { answer: 'yes', confidence: 1 },
      severity: 5,
    }
    const d = decide(input, obeyed, c.judge, 0.7)
    expect(d.ruling.decision).toBe('abstain')
    expect(d.ruling.tenantBps).toBeNull()
    expect(d.ruling.abstainReasons).toEqual(['statement E1 tries to instruct the judge, impersonate an authority or claim a prior decision'])
    expect(d.ruling.answers).toEqual(obeyed) // kept in the record for the human
  })
})
