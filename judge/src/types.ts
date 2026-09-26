import { z } from 'zod'
import { MATERIALS, RULE_IDS } from './rules/tokyo.ts'

export type Hex = `0x${string}`
export type Address = `0x${string}`

/** Who wrote a statement. Evidence is always attributed to one of the lease's two parties. */
export type Party = 'tenant' | 'landlord'

/**
 * On-chain facts about the disputed lease (RentEscrow.getLease + escrowBalance + the DisputeOpened
 * event). Token amounts are decimal strings in token units (USDC: 6 decimals) so the input can be
 * hashed as canonical JSON.
 */
export interface LeaseFacts {
  leaseId: string
  landlord: Address
  tenant: Address
  token: { address: Address; symbol: string; decimals: number }
  deposit: string
  rentPerPeriod: string
  periodSeconds: number
  periods: number
  periodsClaimed: number
  startTime: number
  disputeOpenedAt: number
  disputeOpenedBy: Party
  /** Rent periods elapsed when the dispute was opened (RentEscrow stops accruing rent then). */
  periodsEarnedAtDispute: number
  /** escrowBalance(leaseId) = deposit + earnedRentUnreleased + unearnedRent. */
  remainingEscrow: string
  /** Rent for periods that had elapsed at the dispute but was not yet released to the landlord. */
  earnedRentUnreleased: string
  /** Rent for periods that had NOT elapsed when the dispute was opened. */
  unearnedRent: string
}

export interface EvidenceItem {
  /** E1, E2, ... in on-chain order. */
  id: string
  party: Party
  author: Address
  statement: string
  txHash: Hex
  blockNumber: string
  logIndex: number
}

/**
 * The tenant's rentouts.* ENS credential, read through the ENS Universal Resolver. Only the
 * identity part (name, status, whether it resolves to the tenant) is shown to the model; the track
 * record (disputes, deposit return rate, rating) is kept for the human reviewer only, because a past
 * record is not evidence about this dispute and a ruling feeds back into it.
 */
export interface TenantCredential {
  name: string | null
  status: string | null
  resolvesToTenant: boolean
  records: Record<string, string | null>
  error?: string
}

export interface DisputeInput {
  version: 1
  chainId: number
  escrow: Address
  arbiter: Address
  lease: LeaseFacts
  evidence: EvidenceItem[]
  tenantCredential: TenantCredential | null
}

// ------------------------------------------------------------------ the checklist (same for every provider)

const yesNo = z
  .object({
    answer: z.enum(['yes', 'no']),
    /** The model's probability (0..1) that this answer is correct. */
    confidence: z.number().min(0).max(1),
  })
  .strict()

const ruleIds = z.array(z.enum(RULE_IDS)).min(1).max(7)

/**
 * One item the landlord claims for, classified under the Tokyo rules pack (rules/tokyo.ts). The
 * model classifies; code applies the depreciation schedule (TKY-5) and the payout (rubric.ts).
 */
export const ClaimedItemSchema = z
  .object({
    /** Short name, e.g. "bedroom wallpaper". */
    item: z.string().min(1).max(80),
    material: z.enum(MATERIALS),
    /** ageing / normal_use => landlord (TKY-1); tenant_damage => tenant (TKY-2); not_established => landlord (TKY-7). */
    cause: z.enum(['ageing', 'normal_use', 'tenant_damage', 'not_established']),
    confidence: z.number().min(0).max(1),
    /** Cost of repairing the smallest practical unit (TKY-4) AS IF NEW, relative to the deposit, 1..5. No depreciation. */
    severity: z.number().int().min(1).max(5),
    /** The item's age at move-out in years, only if the evidence establishes it; else null. */
    ageYears: z.number().min(0).max(100).nullable().optional(),
    rules: ruleIds,
  })
  .strict()

export type ClaimedItem = z.infer<typeof ClaimedItemSchema>

export const JudgeAnswersSchema = z
  .object({
    /** Q1: damage beyond normal wear and tear, caused during the tenancy, established by the evidence. */
    damageBeyondNormalWear: yesNo,
    /** Q2: the landlord's claim to rent for periods that had not elapsed at the dispute is valid. */
    rentClaimValid: yesNo,
    /** Q3: the evidence is sufficient to decide Q1 and Q2. */
    evidenceSufficient: yesNo,
    /** Q4: severity of the damage relative to the deposit, 1 (minor) .. 5 (the whole deposit). 1 if Q1 is no. */
    severity: z.number().int().min(1).max(5),
    /** Short plain-language reasons, citing evidence ids (E1, E2, ...). Explanation only: it never sets the split. */
    rationale: z.string().min(1).max(800),
    /** Ids of the Tokyo rules (TKY-n) the answers rest on. Optional: answers recorded before the pack have none. */
    rules: ruleIds.optional(),
    /** The claimed items, classified under the pack. When present, code charges per item (rubric v2). */
    items: z.array(ClaimedItemSchema).max(6).optional(),
  })
  .strict()

export type JudgeAnswers = z.infer<typeof JudgeAnswersSchema>
export type YesNo = JudgeAnswers['damageBeyondNormalWear']
