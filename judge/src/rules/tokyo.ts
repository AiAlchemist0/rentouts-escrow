import { canonicalHash } from '../canonical.ts'
import type { Hex } from '../types.ts'

/**
 * The Tokyo restoration rules pack: what the judge applies when it asks "is this normal wear or
 * tenant damage?". Each rule is a SHORT SUMMARY IN OUR OWN WORDS of principles found in the public
 * guidance listed in TOKYO_SOURCES; no government text is copied. The guidance is not binding law:
 * the lease and the courts still govern, and the human arbiter can overrule any AI ruling.
 *
 * The pack is versioned and hashed. The hash goes into every ruling made with it (ruling.rules), so
 * the rulingHash committed on-chain also commits to the exact rules the judge was given. Change a
 * rule, a source or the schedule => bump TOKYO_RULES_VERSION (a test pins the hash per version).
 */
export const TOKYO_RULES_ID = 'tokyo-restoration'
export const TOKYO_RULES_VERSION = '1.0.0'

export const RULE_IDS = ['TKY-1', 'TKY-2', 'TKY-3', 'TKY-4', 'TKY-5', 'TKY-6', 'TKY-7'] as const
export type RuleId = (typeof RULE_IDS)[number]

export interface Source {
  id: string
  title: string
  url: string
}

export interface Rule {
  id: RuleId
  title: string
  /** Our paraphrase of the principle. */
  summary: string
  sources: string[]
}

export const TOKYO_SOURCES: Source[] = [
  {
    id: 'TMG-ORD',
    title:
      'Tokyo Metropolitan Government, Ordinance for the Prevention of Residential Rental Disputes in Tokyo (賃貸住宅紛争防止条例, the "Tokyo Rule"), English version',
    url: 'https://www.juutakuseisaku.metro.tokyo.lg.jp/documents/d/juutakuseisaku/310-23-00-jyuutaku_eng',
  },
  {
    id: 'TMG-GUIDE',
    title: 'Tokyo Metropolitan Government, Guidelines for Preventing Tenant-Landlord Disputes (賃貸住宅トラブル防止ガイドライン), English version',
    url: 'https://www.english.metro.tokyo.lg.jp/w/000-101-000577',
  },
  {
    id: 'MLIT-GL',
    title: 'MLIT, 原状回復をめぐるトラブルとガイドライン (再改訂版) [Troubles concerning restoration to original condition, and guidelines, 2nd revision]',
    url: 'https://www.mlit.go.jp/jutakukentiku/house/jutakukentiku_house_tk3_000020.html',
  },
  {
    id: 'MLIT-EN',
    title: 'MLIT / Japan Property Management Association, Points for restoring rental housing to its original condition when you move out (English leaflet, 2023)',
    url: 'https://www.mlit.go.jp/jutakukentiku/house/content/001595135.pdf',
  },
]

export const TOKYO_RULES: Rule[] = [
  {
    id: 'TKY-1',
    title: 'Ageing and normal wear are the landlord’s cost',
    summary:
      'The rent already pays for the unit getting older and for the marks ordinary living leaves: sun fading, furniture dents, marks behind a fridge, pin holes from posters, fixtures that reach the end of their life. The deposit is not used to pay for these.',
    sources: ['MLIT-GL', 'MLIT-EN', 'TMG-GUIDE', 'TMG-ORD'],
  },
  {
    id: 'TKY-2',
    title: 'The tenant pays only for damage they caused',
    summary:
      'The tenant owes repairs for damage from intentional acts, negligence or carelessness, or use beyond ordinary living: a hole punched or kicked in a wall, burns, scribbles, pet damage, smoke stains, mould left to spread, scratches from moving furniture, screw holes the landlord did not approve.',
    sources: ['MLIT-GL', 'MLIT-EN', 'TMG-GUIDE'],
  },
  {
    id: 'TKY-3',
    title: 'Upgrades and re-letting work are the landlord’s',
    summary:
      'Replacing undamaged items to attract the next tenant, improvements that raise the unit’s value, and professional cleaning of a unit the tenant left reasonably clean are the landlord’s cost unless a valid special clause says otherwise (TKY-6).',
    sources: ['MLIT-GL', 'MLIT-EN'],
  },
  {
    id: 'TKY-4',
    title: 'Only the smallest practical repair unit',
    summary:
      'Where the tenant is liable, the charge covers the smallest unit that can reasonably be repaired (the damaged patch or wall face, one mat, one panel), not a whole room redone to match.',
    sources: ['MLIT-GL', 'TMG-GUIDE'],
  },
  {
    id: 'TKY-5',
    title: 'The tenant’s share falls with the item’s age',
    summary:
      'Items that lose value over time are charged at their remaining value, not as new. Wallpaper, carpet and cushion flooring are treated as losing value in a straight line over about 6 years, down to a token residual. Consumable coverings (tatami surface, fusuma or shoji paper) and spot repairs of wooden flooring are not reduced for age. Even a fully written-down item can leave the tenant owing the work to put it back into use if they broke it; the code does not model that labour, a party who claims it appeals.',
    sources: ['MLIT-GL', 'MLIT-EN'],
  },
  {
    id: 'TKY-6',
    title: 'Special clauses must be explicit and agreed',
    summary:
      'A lease clause that moves costs the landlord would normally bear (such as normal wear or cleaning) onto the tenant counts only if it is specific, has a reasonable basis, was explained before signing, and the tenant clearly accepted it. In Tokyo the broker must explain the restoration principles and any such clauses before the contract is signed.',
    sources: ['TMG-ORD', 'TMG-GUIDE', 'MLIT-GL', 'MLIT-EN'],
  },
  {
    id: 'TKY-7',
    title: 'The landlord must show the damage is the tenant’s',
    summary:
      'A landlord who deducts from the deposit has to show the damage exists, arose during this tenancy and was caused by the tenant beyond normal wear. Move-in and move-out condition records are the usual proof. If that is not shown, the item is not charged to the tenant.',
    sources: ['MLIT-GL', 'TMG-GUIDE'],
  },
]

// ------------------------------------------------------------------ depreciation (TKY-5), in code

/** What a claimed item is, for the depreciation schedule. */
export const MATERIALS = ['wallpaper', 'carpet', 'cushion_floor', 'tatami_surface', 'fusuma_shoji', 'flooring_spot', 'other'] as const
export type Material = (typeof MATERIALS)[number]

/** Straight-line useful life in years (TKY-5). Materials not listed are not reduced for age. */
export const USEFUL_LIFE_YEARS: Partial<Record<Material, number>> = { wallpaper: 6, carpet: 6, cushion_floor: 6 }

/** The token residual (in bps of the new cost) a fully written-down item keeps. */
export const NOMINAL_RESIDUAL_BPS = 1
const SECONDS_PER_YEAR = 365 * 24 * 60 * 60

/** Years the tenant held the unit, from the on-chain lease start to the dispute, rounded to 0.01. */
export function occupancyYears(lease: { startTime: number; disputeOpenedAt: number }): number {
  const seconds = Math.max(0, lease.disputeOpenedAt - lease.startTime)
  return Math.round((seconds / SECONDS_PER_YEAR) * 100) / 100
}

export interface Depreciation {
  /** The item age the schedule was applied to (years, 0.01 steps). */
  ageYears: number
  usefulLifeYears: number | null
  /** Most the tenant can be charged, in bps of the cost of the item as new. */
  tenantShareBps: number
}

/**
 * TKY-5 in code. The item's age is at least the on-chain occupancy (the unit cannot be younger
 * than the tenancy it was used in); an older age counts only if the model says the evidence
 * establishes it. Straight line from 10000 bps (new) to NOMINAL_RESIDUAL_BPS at the end of the
 * useful life; rounded down, i.e. toward the tenant.
 */
export function depreciation(material: Material, occupancy: number, statedAgeYears: number | null | undefined): Depreciation {
  const age = Math.round(Math.max(occupancy, statedAgeYears ?? 0, 0) * 100) / 100
  const life = USEFUL_LIFE_YEARS[material] ?? null
  if (life === null) return { ageYears: age, usefulLifeYears: null, tenantShareBps: 10_000 }
  const remaining = Math.floor((10_000 * Math.max(0, life - age)) / life)
  return { ageYears: age, usefulLifeYears: life, tenantShareBps: Math.max(NOMINAL_RESIDUAL_BPS, remaining) }
}

// ------------------------------------------------------------------ the pack as data, and its hash

export interface RulesPackRef {
  id: string
  version: string
  /** keccak256 of the canonical JSON of the pack (rules, sources, schedule). */
  hash: Hex
}

export const TOKYO_RULES_PACK = {
  id: TOKYO_RULES_ID,
  version: TOKYO_RULES_VERSION,
  rules: TOKYO_RULES,
  sources: TOKYO_SOURCES,
  schedule: { usefulLifeYears: USEFUL_LIFE_YEARS, nominalResidualBps: NOMINAL_RESIDUAL_BPS, secondsPerYear: SECONDS_PER_YEAR },
}

export const TOKYO_RULES_REF: RulesPackRef = {
  id: TOKYO_RULES_ID,
  version: TOKYO_RULES_VERSION,
  hash: canonicalHash(TOKYO_RULES_PACK),
}

/** The pack as the model sees it (inside <restoration_rules> in the system prompt). */
export function rulesForPrompt(): string {
  const lines = TOKYO_RULES.map((r) => `${r.id} ${r.title}. ${r.summary}`)
  return `Pack ${TOKYO_RULES_ID} v${TOKYO_RULES_VERSION} (summaries of Tokyo Metropolitan Government and MLIT guidance on restoring a rental at move-out; guidance, not law; the lease terms still apply).\n${lines.join('\n')}`
}
