import { describe, expect, it } from 'vitest'
import { computeSplit, potsOf, RUBRIC_VERSION } from '../src/rubric.ts'
import { answers } from './helpers.ts'

// README demo lease: 0.30 deposit, 3 x 0.10 rent; dispute after 1 period, not yet claimed.
const pots = { deposit: 300_000n, earnedRentUnreleased: 100_000n, unearnedRent: 200_000n }
const yes = (confidence = 0.9) => ({ answer: 'yes' as const, confidence })

describe('rubric: code turns the answers into tenantBps', () => {
  it('no damage, no rent claim: deposit + unearned rent to the tenant, earned rent to the landlord', () => {
    const s = computeSplit(pots, answers())
    expect(s.version).toBe(RUBRIC_VERSION)
    expect(s.remainingEscrow).toBe(600_000n)
    expect(s.depositReturned).toBe(300_000n)
    expect(s.unearnedRentToTenant).toBe(200_000n)
    expect(s.earnedRentToLandlord).toBe(100_000n)
    expect(s.tenantAmount).toBe(500_000n)
    expect(s.exactBps).toBe(8333)
    expect(s.tenantBps).toBe(7500) // 83.3% rounds to the nearest 25% step
  })

  it('damage keeps severity/5 of the deposit', () => {
    const kept = [1, 2, 3, 4, 5].map(
      (severity) => computeSplit(pots, answers({ damageBeyondNormalWear: yes(), severity })).depositKept,
    )
    expect(kept).toEqual([60_000n, 120_000n, 180_000n, 240_000n, 300_000n])
  })

  it('severity is ignored when there is no damage', () => {
    expect(computeSplit(pots, answers({ severity: 5 })).depositKept).toBe(0n)
  })

  it('a valid rent claim gives the landlord the unearned rent too', () => {
    const s = computeSplit(pots, answers({ rentClaimValid: yes() }))
    expect(s.unearnedRentToTenant).toBe(0n)
    expect(s.tenantAmount).toBe(300_000n)
    expect(s.tenantBps).toBe(5000)
  })

  it('full damage and a valid rent claim: everything to the landlord', () => {
    const s = computeSplit(pots, answers({ damageBeyondNormalWear: yes(), rentClaimValid: yes(), severity: 5 }))
    expect(s.tenantAmount).toBe(0n)
    expect(s.tenantBps).toBe(0)
  })

  it('only ever proposes 0 / 2500 / 5000 / 7500 / 10000, and half steps round toward the tenant', () => {
    const at = (tenantShare: bigint, total = 1000n) =>
      computeSplit({ deposit: tenantShare, earnedRentUnreleased: total - tenantShare, unearnedRent: 0n }, answers())
    expect(at(1000n).tenantBps).toBe(10_000)
    expect(at(0n).tenantBps).toBe(0)
    expect(at(124n).tenantBps).toBe(0)
    expect(at(125n).tenantBps).toBe(2500) // exactly 12.5%: toward the tenant
    expect(at(375n).tenantBps).toBe(5000)
    expect(at(624n).tenantBps).toBe(5000)
    expect(at(625n).tenantBps).toBe(7500)
    expect(at(875n).tenantBps).toBe(10_000)
    for (let t = 0n; t <= 1000n; t += 7n) expect([0, 2500, 5000, 7500, 10_000]).toContain(at(t).tenantBps)
  })

  it('an empty escrow gives 0 bps', () => {
    const s = computeSplit({ deposit: 0n, earnedRentUnreleased: 0n, unearnedRent: 0n }, answers())
    expect(s.tenantBps).toBe(0)
    expect(s.exactBps).toBe(0)
  })

  it('reads the pots from lease facts', () => {
    expect(potsOf({ deposit: '300000', earnedRentUnreleased: '0', unearnedRent: '200000' })).toEqual({
      deposit: 300_000n,
      earnedRentUnreleased: 0n,
      unearnedRent: 200_000n,
    })
  })
})
