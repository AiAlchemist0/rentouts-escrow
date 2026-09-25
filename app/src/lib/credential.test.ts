import { describe, expect, it } from 'vitest'
import { evaluateCredential, formatRecord, labelUnder } from './credential'

const alice = '0x484811c8c967809bE644A89d677933c29fb9e936'
const mallory = '0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE'

describe('evaluateCredential', () => {
  it('verifies an active name that resolves to its holder', () => {
    expect(evaluateCredential({ address: alice, status: 'active', expectedHolder: alice })).toEqual({ verified: true })
  })

  it('hides records when anything is off', () => {
    expect(evaluateCredential({ address: alice, status: 'revoked', expectedHolder: alice }).verified).toBe(false)
    expect(evaluateCredential({ address: null, status: 'active', expectedHolder: alice }).verified).toBe(false)
    expect(evaluateCredential({ address: alice, status: 'active', expectedHolder: null }).verified).toBe(false)
    expect(evaluateCredential({ address: mallory, status: 'active', expectedHolder: alice }).verified).toBe(false)
    expect(evaluateCredential({ address: alice, status: null, expectedHolder: alice }).verified).toBe(false)
  })
})

describe('formatRecord', () => {
  it('adds units to bare numbers only', () => {
    expect(formatRecord('rentouts.rentPaid', '0.60')).toBe('0.60 USDC')
    expect(formatRecord('rentouts.depositReturnRate', '100')).toBe('100%')
    expect(formatRecord('rentouts.depositReturnRate', '100%')).toBe('100%')
    expect(formatRecord('rentouts.leasesCompleted', '3')).toBe('3')
    expect(formatRecord('rentouts.rating', null)).toBe('—')
  })
})

describe('labelUnder', () => {
  it('extracts direct child labels', () => {
    expect(labelUnder('alice.rentouts.eth', 'rentouts.eth')).toBe('alice')
    expect(labelUnder('a.b.rentouts.eth', 'rentouts.eth')).toBeNull()
    expect(labelUnder('alice.eth', 'rentouts.eth')).toBeNull()
  })
})
