import { describe, expect, it } from 'vitest'
import { checkLabel, looksLikeEnsName } from './label'

describe('checkLabel', () => {
  it('accepts labels the contract accepts', () => {
    for (const label of ['alice', 'bob-2', 'a1c', '0xrent', 'a'.repeat(32)]) {
      expect(checkLabel(label)).toEqual({ ok: true, label })
    }
  })

  it('normalizes before validating (ENSIP-15)', () => {
    expect(checkLabel('  Alice ')).toEqual({ ok: true, label: 'alice' })
  })

  it('rejects what RentoutsSubnames._validateLabel rejects', () => {
    const bad = ['', 'ab', 'a'.repeat(33), '-abc', 'abc-', 'ab--c', 'al_ce', 'alice.eth', 'álice', '🏠🏠🏠']
    for (const label of bad) expect(checkLabel(label).ok, label).toBe(false)
  })

  it('explains the reserved hyphen rule', () => {
    expect(checkLabel('xn--abc')).toMatchObject({ ok: false, reason: expect.stringContaining('positions 3 and 4') })
  })
})

describe('looksLikeEnsName', () => {
  it('tells names from addresses', () => {
    expect(looksLikeEnsName('alice.rentouts.eth')).toBe(true)
    expect(looksLikeEnsName('0x484811c8c967809bE644A89d677933c29fb9e936')).toBe(false)
    expect(looksLikeEnsName('alice')).toBe(false)
  })

  it('treats names whose label starts with 0x as names (0xrent is claimable)', () => {
    expect(checkLabel('0xrent')).toEqual({ ok: true, label: '0xrent' })
    expect(looksLikeEnsName('0xrent.rentouts.eth')).toBe(true)
    expect(looksLikeEnsName('0x484811c8c967809be644a89d677933c29fb9e936')).toBe(false)
  })
})
