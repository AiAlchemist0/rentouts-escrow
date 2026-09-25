import { describe, expect, it } from 'vitest'
import { leaseFacts, partyOf, type OnchainLease } from '../src/chain.ts'

const landlord = '0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE'
const tenant = '0x484811c8c967809bE644A89d677933c29fb9e936'
const token = { address: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238' as const, symbol: 'USDC', decimals: 6 }
const lease = (periodsClaimed = 0): OnchainLease => ({
  landlord,
  tenant,
  deposit: 300_000n,
  rentPerPeriod: 100_000n,
  periodSeconds: 60,
  periods: 3,
  periodsClaimed,
  startTime: 1_000_000n,
  state: 3,
})

describe('leaseFacts: splitting the remaining escrow like RentEscrow', () => {
  it('a dispute after 1.5 periods: 1 earned (unclaimed), 2 unearned', () => {
    const f = leaseFacts({ leaseId: 7n, lease: lease(), escrowBalance: 600_000n, disputeOpenedAt: 1_000_090, disputeOpenedBy: tenant, token })
    expect(f).toMatchObject({
      leaseId: '7',
      periodsEarnedAtDispute: 1,
      earnedRentUnreleased: '100000',
      unearnedRent: '200000',
      remainingEscrow: '600000',
      disputeOpenedBy: 'tenant',
    })
  })

  it('claimed rent is not in the escrow any more', () => {
    const f = leaseFacts({ leaseId: 1n, lease: lease(2), escrowBalance: 400_000n, disputeOpenedAt: 1_000_150, disputeOpenedBy: landlord, token })
    expect(f).toMatchObject({ periodsEarnedAtDispute: 2, earnedRentUnreleased: '0', unearnedRent: '100000', disputeOpenedBy: 'landlord' })
  })

  it('after the term every period is earned', () => {
    const f = leaseFacts({ leaseId: 1n, lease: lease(), escrowBalance: 600_000n, disputeOpenedAt: 1_010_000, disputeOpenedBy: landlord, token })
    expect(f).toMatchObject({ periodsEarnedAtDispute: 3, earnedRentUnreleased: '300000', unearnedRent: '0' })
  })

  it('refuses facts that do not add up to escrowBalance', () => {
    expect(() =>
      leaseFacts({ leaseId: 1n, lease: lease(), escrowBalance: 599_999n, disputeOpenedAt: 1_000_090, disputeOpenedBy: tenant, token }),
    ).toThrow(/escrowBalance/)
  })

  it('attributes an address to a party, or refuses', () => {
    expect(partyOf(tenant.toLowerCase() as `0x${string}`, { tenant, landlord })).toBe('tenant')
    expect(() => partyOf('0x000000000000000000000000000000000000dEaD', { tenant, landlord })).toThrow(/neither/)
  })
})
