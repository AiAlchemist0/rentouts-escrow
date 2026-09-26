import { describe, expect, it } from 'vitest'
import { HUMAN_GATE_TITLE, humanGateNotice, type HumanGateView } from './humanGate'

const gate = '0x1111111111111111111111111111111111111111' as const

describe('humanGateNotice', () => {
  it('shows nothing when funding isn’t gated', () => {
    expect(humanGateNotice({})).toBeNull()
    expect(humanGateNotice({ verified: false, open: false })).toBeNull()
  })

  it('always carries the World ID title when a gate is set', () => {
    const views: HumanGateView[] = [{ gate }, { gate, verified: true }, { gate, verified: true, open: true }, { gate, verified: false }]
    for (const view of views) {
      expect(humanGateNotice(view)?.title).toBe(HUMAN_GATE_TITLE)
    }
  })

  it('blocks funding only for a wallet the gate rejects', () => {
    const rejected = humanGateNotice({ gate, verified: false, open: false })
    expect(rejected).toMatchObject({ tone: 'error', blocksFunding: true })
    expect(rejected?.detail).toMatch(/funding would revert/)

    expect(humanGateNotice({ gate, verified: true })).toMatchObject({ tone: 'info', blocksFunding: false })
    expect(humanGateNotice({ gate })).toMatchObject({ tone: 'info', blocksFunding: false })
  })

  it('tells a rejected wallet how to pass with World ID 4.0, without a stale “coming soon”', () => {
    const rejected = humanGateNotice({ gate, verified: false, open: false, verifier: gate })
    expect(rejected?.detail).toMatch(/World ID 4\.0/)
    expect(rejected?.detail).toMatch(/registers the wallet/)
    for (const view of [{ gate, verified: false }, { gate, verified: true }, { gate, verified: true, open: true }] as HumanGateView[]) {
      const n = humanGateNotice(view)
      expect(`${n?.title} ${n?.detail}`).not.toMatch(/coming soon|isn’t in this demo/)
    }
    expect(HUMAN_GATE_TITLE).toBe('Human verification required (World ID)')
  })

  it('says so when the gate is open (no verifier yet)', () => {
    expect(humanGateNotice({ gate, verified: true, open: true })?.detail).toMatch(/every wallet passes for now/)
    expect(humanGateNotice({ gate, verified: true, open: false })?.detail).toMatch(/This wallet passes it/)
  })
})
