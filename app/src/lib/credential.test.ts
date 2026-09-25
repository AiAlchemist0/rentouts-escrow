import { keccak256, stringToBytes, toBytes } from 'viem'
import { labelhash } from 'viem/ens'
import { describe, expect, it } from 'vitest'
import { evaluateCredential, formatRecord, labelId, labelUnder, staleCredentialKeys, syncedRecords } from './credential'
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

describe('syncedRecords', () => {
  const stats = { leasesCompleted: 2, leasesDisputed: 1, rentPaid: 1_234_567n, depositsPosted: 500_000n, depositsReturned: 333_333n }

  it('formats like CredentialSync (_usdc truncates to cents, _rate floors and caps)', () => {
    expect(syncedRecords(stats)).toEqual({
      'rentouts.leasesCompleted': '2',
      'rentouts.disputes': '1',
      'rentouts.rentPaid': '1.23',
      'rentouts.depositReturnRate': '66',
    })
    const zero = { leasesCompleted: 0, leasesDisputed: 0, rentPaid: 0n, depositsPosted: 0n, depositsReturned: 0n }
    expect(syncedRecords(zero)['rentouts.rentPaid']).toBe('0.00')
    expect(syncedRecords(zero)['rentouts.depositReturnRate']).toBe('n/a')
    expect(syncedRecords({ ...zero, rentPaid: 1n })['rentouts.rentPaid']).toBe('0.00')
    expect(syncedRecords({ ...zero, rentPaid: 1_050_000n })['rentouts.rentPaid']).toBe('1.05')
    expect(syncedRecords({ ...zero, rentPaid: 12_345_000_000n })['rentouts.rentPaid']).toBe('12345.00')
    expect(syncedRecords({ ...zero, depositsPosted: 3n, depositsReturned: 4n })['rentouts.depositReturnRate']).toBe('100')
  })
})

describe('staleCredentialKeys', () => {
  const synced = { leasesCompleted: 1, leasesDisputed: 0, rentPaid: 600_000n, depositsPosted: 250_000n, depositsReturned: 250_000n }
  const records = {
    'rentouts.leasesCompleted': '1',
    'rentouts.disputes': '0',
    'rentouts.rentPaid': '0.60',
    'rentouts.depositReturnRate': '100',
  }

  it('is empty right after a sync', () => {
    expect(staleCredentialKeys(records, synced)).toEqual([])
  })

  it('notices a rent claim, which changes only rentPaid', () => {
    expect(staleCredentialKeys(records, { ...synced, rentPaid: 800_000n })).toEqual(['rentouts.rentPaid'])
  })

  it('notices a dispute resolution, which changes only the deposit figures', () => {
    const resolved = { ...synced, depositsPosted: 500_000n, depositsReturned: 375_000n }
    expect(staleCredentialKeys(records, resolved)).toEqual(['rentouts.depositReturnRate'])
  })

  it('treats a never-synced name with no escrow history as up to date, and one with history as behind', () => {
    const none = { leasesCompleted: 0, leasesDisputed: 0, rentPaid: 0n, depositsPosted: 0n, depositsReturned: 0n }
    expect(staleCredentialKeys({}, none)).toEqual([])
    expect(staleCredentialKeys({}, synced)).toEqual(['rentouts.leasesCompleted', 'rentouts.rentPaid', 'rentouts.depositReturnRate'])
  })
})
