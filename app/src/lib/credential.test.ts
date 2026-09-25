import { keccak256, stringToBytes, toBytes } from 'viem'
import { labelhash } from 'viem/ens'
import { describe, expect, it } from 'vitest'
import { evaluateCredential, formatRecord, labelId, labelUnder } from './credential'
import { checkLabel } from './label'

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

describe('labelId', () => {
  it('hashes the label as text, like RentoutsSubnames (uint256(keccak256(bytes(label))))', () => {
    // ENS's well-known labelhash("eth").
    expect(labelId('eth')).toBe(0x4f5b812789fc606be1b3b16908db13fc7a9adf7ca72641f84d75b47069d3d7f0n)
    for (const label of ['alice', 'abc', '0xrent']) expect(labelId(label)).toBe(BigInt(labelhash(label)))
  })

  it('does not read claimable hex-looking labels as hex bytes', () => {
    for (const label of ['0xdead', '0xabc', '0x1337', '0xcafe', '0x123']) {
      expect(checkLabel(label)).toEqual({ ok: true, label }) // RentoutsSubnames accepts it
      expect(labelId(label)).toBe(BigInt(keccak256(stringToBytes(label))))
      expect(labelId(label)).toBe(BigInt(labelhash(label)))
      expect(labelId(label)).not.toBe(BigInt(keccak256(toBytes(label)))) // the old, hex-decoding hash
    }
  })
})
