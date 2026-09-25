import { readFileSync } from 'node:fs'
import type { DisputeInput, JudgeAnswers } from '../src/types.ts'

export function fixture(name: string): DisputeInput {
  return JSON.parse(readFileSync(new URL(`../fixtures/${name}.json`, import.meta.url), 'utf8'))
}

export function answers(overrides: Partial<JudgeAnswers> = {}): JudgeAnswers {
  return {
    damageBeyondNormalWear: { answer: 'no', confidence: 0.9 },
    rentClaimValid: { answer: 'no', confidence: 0.9 },
    evidenceSufficient: { answer: 'yes', confidence: 0.9 },
    severity: 1,
    rationale: 'No damage or rent claim is established.',
    ...overrides,
  }
}
