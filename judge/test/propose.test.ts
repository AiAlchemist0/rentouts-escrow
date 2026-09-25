import { describe, expect, it } from 'vitest'
import type { ArbiterState } from '../src/chain.ts'
import { EXIT_STANDING_PROPOSAL, MAX_SUMMARY_BYTES, MOCK_SUMMARY_PREFIX, planProposal, proposalSummary } from '../src/propose.ts'

const NOW = 1_800_000_000n
const HASH = `0x${'11'.repeat(32)}` as const

function onchain(status: ArbiterState['ruling']['status'], deadline = NOW + 60n): ArbiterState['ruling'] {
  return { status, tenantBps: 0, confidenceBps: 9000, proposedAt: deadline - 120n, deadline, rulingHash: HASH }
}
const abstain = { decision: 'abstain' as const }
const propose = { decision: 'propose' as const }

describe('planProposal: the judge abstains while an earlier AI proposal is open', () => {
  it('--propose: says the open proposal still executes at its deadline, and exits 3 (not "the human decides")', () => {
    const plan = planProposal(abstain, onchain('PROPOSED'), { propose: true, now: NOW })
    expect(plan).toMatchObject({ send: false, exitCode: EXIT_STANDING_PROPOSAL })
    const text = plan.lines.join('\n')
    expect(text).toMatch(/earlier AI proposal is still open: tenantBps 0 \(0\.00% to the tenant\)/)
    expect(text).toMatch(/executes at 2027-01-15T08:01:00\.000Z unless a party appeals before then or the human arbiter calls resolveByHuman/)
    expect(text).toMatch(/cannot withdraw the open proposal/)
    expect(text).not.toMatch(/the human arbiter decides/)
  })

  it('once the window is over: anyone can execute it now', () => {
    const plan = planProposal(abstain, onchain('PROPOSED', NOW - 1n), { propose: true, now: NOW })
    expect(plan).toMatchObject({ send: false, exitCode: EXIT_STANDING_PROPOSAL })
    expect(plan.lines.join('\n')).toMatch(/ANYONE can execute it now/)
  })

  it('without --propose the warning is printed too, and the dry run exits 0', () => {
    const plan = planProposal(abstain, onchain('PROPOSED'), { propose: false, now: NOW })
    expect(plan).toMatchObject({ send: false, exitCode: 0 })
    expect(plan.lines.join('\n')).toMatch(/still open/)
  })

  it('no open proposal: the human arbiter decides (exit 0)', () => {
    for (const s of ['NONE', 'APPEALED'] as const) {
      const plan = planProposal(abstain, onchain(s), { propose: true, now: NOW })
      expect(plan).toMatchObject({ send: false, exitCode: 0 })
      expect(plan.lines.join('\n')).toMatch(/not sent: the judge abstained.*the human arbiter decides/)
      expect(plan.lines.join('\n')).not.toMatch(/WARNING/)
    }
  })
})

describe('planProposal: the judge proposes', () => {
  it('sends on a fresh lease, and replaces an open proposal inside its window', () => {
    expect(planProposal(propose, onchain('NONE'), { propose: true, now: NOW })).toEqual({ send: true, lines: [] })
    const replace = planProposal(propose, onchain('PROPOSED'), { propose: true, now: NOW })
    expect(replace.send).toBe(true)
    expect(replace.lines.join('\n')).toMatch(/replaces the open proposal/)
  })

  it('refuses before signing when the lease was appealed or the window is over', () => {
    expect(() => planProposal(propose, onchain('APPEALED'), { propose: true, now: NOW })).toThrow(/appealed/)
    expect(() => planProposal(propose, onchain('PROPOSED', NOW), { propose: true, now: NOW })).toThrow(/window is over/)
  })

  it('without --propose nothing is sent', () => {
    expect(planProposal(propose, onchain('NONE'), { propose: false, now: NOW })).toEqual({ send: false, exitCode: 0, lines: [] })
  })
})

describe('proposalSummary: what the Proposed event says', () => {
  const answers = { rationale: 'E2 admits E1.' } as never
  it('labels a mock ruling on-chain, and leaves a model ruling as its rationale', () => {
    expect(proposalSummary({ judge: { provider: 'mock', model: 'mock-keywords-v1' }, answers })).toBe(`${MOCK_SUMMARY_PREFIX}E2 admits E1.`)
    expect(proposalSummary({ judge: { provider: 'mock', model: 'mock-keywords-v1' }, answers })).toMatch(/^\[mock judge, keyword matching\] /)
    expect(proposalSummary({ judge: { provider: 'glm', model: 'glm-5.3' }, answers })).toBe('E2 admits E1.')
  })

  it('stays within AIArbiter.MAX_SUMMARY_BYTES with the label', () => {
    const long = { rationale: 'é'.repeat(800) } as never
    const s = proposalSummary({ judge: { provider: 'mock', model: 'mock-keywords-v1' }, answers: long })
    expect(s.startsWith(MOCK_SUMMARY_PREFIX)).toBe(true)
    expect(new TextEncoder().encode(s).length).toBeLessThanOrEqual(MAX_SUMMARY_BYTES)
  })
})
