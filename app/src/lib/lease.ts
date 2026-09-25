import { isAddressEqual, type Address } from 'viem'
import { LeaseState } from '../abi/rentEscrow'

export type LeaseTerms = {
  startTime: bigint
  periodSeconds: number
  periods: number
  periodsClaimed: number
}

export const STATE_LABELS: Record<number, string> = {
  [LeaseState.NONE]: 'Unknown',
  [LeaseState.CREATED]: 'Awaiting funding',
  [LeaseState.ACTIVE]: 'Active',
  [LeaseState.DISPUTED]: 'In dispute',
  [LeaseState.CLOSED]: 'Closed',
  [LeaseState.CANCELLED]: 'Cancelled',
}

export type LeaseTiming = {
  /** Unix seconds when the term ends (startTime + periods * periodSeconds). */
  end: number
  /** Periods fully elapsed, capped at the term. */
  elapsed: number
  /** Unix seconds when the next rent period unlocks, or null once the term is over. */
  nextUnlock: number | null
  ended: boolean
  /** Anyone may close one period after the end; the landlord may close at the end. */
  publicCloseAt: number
}

/** Mirrors the escrow's period arithmetic for display. Returns null before the lease is funded. */
export function leaseTiming(terms: LeaseTerms, now: number): LeaseTiming | null {
  const start = Number(terms.startTime)
  if (start === 0 || terms.periodSeconds <= 0) return null
  const end = start + terms.periods * terms.periodSeconds
  const elapsed = Math.min(terms.periods, Math.max(0, Math.floor((now - start) / terms.periodSeconds)))
  const nextUnlock = elapsed >= terms.periods ? null : start + (elapsed + 1) * terms.periodSeconds
  return { end, elapsed, nextUnlock, ended: now >= end, publicCloseAt: end + terms.periodSeconds }
}

/** deposit + rentPerPeriod * periods: what the tenant prepays in fundLease. */
export function totalDue(deposit: bigint, rentPerPeriod: bigint, periods: number): bigint {
  return deposit + rentPerPeriod * BigInt(periods)
}

/**
 * Why RentEscrow.createLease would refuse these parties, or null. The escrow reverts InvalidTerms when the
 * tenant is the landlord or when the arbiter is either party, so the app says so before anything is sent.
 */
export function leasePartyProblem(
  landlord: Address | undefined,
  tenant: Address | undefined,
  arbiter: Address | undefined,
): string | null {
  const same = (a: Address | undefined, b: Address | undefined) => !!a && !!b && isAddressEqual(a, b)
  if (same(tenant, landlord)) return 'The tenant can’t be your own wallet.'
  if (same(landlord, arbiter) || same(tenant, arbiter)) return 'The arbiter can’t be the landlord or the tenant of a lease.'
  return null
}
