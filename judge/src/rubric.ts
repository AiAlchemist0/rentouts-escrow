import type { JudgeAnswers } from './types.ts'

/**
 * The payout rubric. CODE, not the model, turns the checklist answers into tenantBps.
 *
 * The remaining escrow of a disputed lease (RentEscrow.escrowBalance) is three pots:
 *   deposit                the tenant's deposit
 *   earnedRentUnreleased   rent for periods that had elapsed when the dispute was opened but was
 *                          not yet released to the landlord
 *   unearnedRent           rent for periods that had NOT elapsed when the dispute was opened
 *
 * Rules (rubric v1):
 *   1. Earned rent goes to the landlord. The tenant had the unit for those periods; the model is
 *      not asked about it.
 *   2. Deposit: if Q1 (damage beyond normal wear) is "yes", the landlord keeps severity/5 of it
 *      (severity 1 = 20% .. 5 = 100%); otherwise all of it goes back to the tenant.
 *   3. Unearned rent: to the landlord if Q2 (the landlord's claim to rent for the rest of the term,
 *      e.g. the tenant left early without notice) is "yes"; otherwise back to the tenant.
 *   4. tenantBps = the tenant's amount / remaining escrow, rounded to the nearest 25% step
 *      (0 / 2500 / 5000 / 7500 / 10000 bps); an exact half step rounds toward the tenant. Coarse
 *      steps keep an AI ruling simple to explain and to check; a party who wants an exact split
 *      appeals to the human arbiter, who can rule any bps.
 */
export const RUBRIC_VERSION = 'rentouts-rubric-v1'
export const BPS_STEP = 2500
const BPS = 10_000n

export interface Pots {
  deposit: bigint
  earnedRentUnreleased: bigint
  unearnedRent: bigint
}

export interface Split {
  version: string
  remainingEscrow: bigint
  depositKept: bigint
  depositReturned: bigint
  earnedRentToLandlord: bigint
  unearnedRentToTenant: bigint
  /** What the rules give the tenant, before rounding. */
  tenantAmount: bigint
  /** tenantAmount / remainingEscrow in bps, rounded down (for display). */
  exactBps: number
  /** The ruling: exactBps rounded to a 25% step. */
  tenantBps: number
}

export type RubricAnswers = Pick<JudgeAnswers, 'damageBeyondNormalWear' | 'rentClaimValid' | 'severity'>

export function computeSplit(pots: Pots, answers: RubricAnswers): Split {
  const { deposit, earnedRentUnreleased, unearnedRent } = pots
  if (deposit < 0n || earnedRentUnreleased < 0n || unearnedRent < 0n) throw new Error('computeSplit: negative pot')
  const remainingEscrow = deposit + earnedRentUnreleased + unearnedRent

  const damage = answers.damageBeyondNormalWear.answer === 'yes'
  const severity = BigInt(Math.min(5, Math.max(1, Math.trunc(answers.severity))))
  const depositKept = damage ? (deposit * severity) / 5n : 0n
  const depositReturned = deposit - depositKept
  const unearnedRentToTenant = answers.rentClaimValid.answer === 'yes' ? 0n : unearnedRent
  const tenantAmount = depositReturned + unearnedRentToTenant

  let exactBps = 0
  let tenantBps = 0
  if (remainingEscrow > 0n) {
    exactBps = Number((tenantAmount * BPS) / remainingEscrow)
    // round half up of (tenantAmount / remainingEscrow) * 4 steps: floor((8a + p) / 2p)
    const steps = (8n * tenantAmount + remainingEscrow) / (2n * remainingEscrow)
    tenantBps = Number(steps) * BPS_STEP
  }

  return {
    version: RUBRIC_VERSION,
    remainingEscrow,
    depositKept,
    depositReturned,
    earnedRentToLandlord: earnedRentUnreleased,
    unearnedRentToTenant,
    tenantAmount,
    exactBps,
    tenantBps,
  }
}

/** The pots of a lease from its (string) facts. */
export function potsOf(lease: { deposit: string; earnedRentUnreleased: string; unearnedRent: string }): Pots {
  return {
    deposit: BigInt(lease.deposit),
    earnedRentUnreleased: BigInt(lease.earnedRentUnreleased),
    unearnedRent: BigInt(lease.unearnedRent),
  }
}
