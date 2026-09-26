import { spawnSync } from 'node:child_process'
import { describe, expect, it } from 'vitest'
import { canonicalHash } from '../src/canonical.ts'
import { decide } from '../src/decide.ts'
import { SYSTEM_PROMPT } from '../src/prompt.ts'
import { mockAnswers } from '../src/providers/mock.ts'
import { proposalSummary } from '../src/propose.ts'
import {
  depreciation,
  occupancyYears,
  RULE_IDS,
  TOKYO_RULES,
  TOKYO_RULES_PACK,
  TOKYO_RULES_REF,
  TOKYO_SOURCES,
} from '../src/rules/tokyo.ts'
import { JudgeAnswersSchema, type DisputeInput, type JudgeAnswers } from '../src/types.ts'
import { answers, fixture } from './helpers.ts'

const judge = { provider: 'mock', model: 'mock-keywords-v1' }
const opts = { rules: TOKYO_RULES_REF }

/** A fixture's lease with new statements: [landlord, tenant]. */
function withStatements(name: string, landlord: string, tenant: string): DisputeInput {
  const input = structuredClone(fixture(name))
  input.evidence[0]!.statement = landlord
  input.evidence[1]!.statement = tenant
  return input
}

function mockDecide(input: DisputeInput) {
  return decide(input, mockAnswers(input), judge, 0.7, opts)
}

describe('Tokyo rules pack', () => {
  it('has stable, unique TKY ids, each citing known sources with https URLs', () => {
    expect(TOKYO_RULES.map((r) => r.id)).toEqual([...RULE_IDS])
    const sources = new Set(TOKYO_SOURCES.map((s) => s.id))
    for (const r of TOKYO_RULES) {
      expect(r.sources.length, r.id).toBeGreaterThan(0)
      for (const s of r.sources) expect(sources.has(s), `${r.id} cites ${s}`).toBe(true)
    }
    for (const s of TOKYO_SOURCES) expect(s.url).toMatch(/^https:\/\/(www\.)?[a-z.]+\.(go\.jp|lg\.jp)\//)
  })

  it('is pinned per version: editing a rule, source or the schedule must bump TOKYO_RULES_VERSION', () => {
    expect(TOKYO_RULES_REF.hash).toBe(canonicalHash(TOKYO_RULES_PACK))
    expect(TOKYO_RULES_REF.version).toBe('1.0.0')
    expect(TOKYO_RULES_REF.hash).toBe('0xd0f5e094ab666f360e36c7f47ec3304be3c10d18f979097f50742d7262da2885')
  })

  it('is in the system prompt, every rule id, and the model is told not to depreciate itself', () => {
    expect(SYSTEM_PROMPT).toMatch(/<restoration_rules>[\s\S]*<\/restoration_rules>/)
    for (const id of RULE_IDS) expect(SYSTEM_PROMPT).toContain(`${id} `)
    expect(SYSTEM_PROMPT).toMatch(/do NOT reduce it for age, code applies the depreciation schedule \(TKY-5\)/)
  })
})

describe('depreciation (TKY-5), in code', () => {
  it('wallpaper, carpet, cushion floor: straight line over 6 years down to a nominal residual', () => {
    expect(depreciation('wallpaper', 0, null).tenantShareBps).toBe(10_000)
    expect(depreciation('wallpaper', 3, null).tenantShareBps).toBe(5_000)
    expect(depreciation('carpet', 1.5, null).tenantShareBps).toBe(7_500)
    expect(depreciation('cushion_floor', 6, null).tenantShareBps).toBe(1)
    expect(depreciation('wallpaper', 7.01, null)).toEqual({ ageYears: 7.01, usefulLifeYears: 6, tenantShareBps: 1 })
  })

  it('consumable coverings, spot floor repairs and other items are not reduced for age', () => {
    for (const m of ['tatami_surface', 'fusuma_shoji', 'flooring_spot', 'other'] as const) {
      expect(depreciation(m, 10, null), m).toEqual({ ageYears: 10, usefulLifeYears: null, tenantShareBps: 10_000 })
    }
  })

  it('age is at least the on-chain occupancy; an older established age counts, a younger one does not', () => {
    expect(depreciation('wallpaper', 1, 4).ageYears).toBe(4)
    expect(depreciation('wallpaper', 4, 1).ageYears).toBe(4)
    expect(occupancyYears({ startTime: 0, disputeOpenedAt: 365 * 24 * 3600 * 3 })).toBe(3)
    expect(occupancyYears(fixture('damage-admitted').lease)).toBe(0)
  })
})

describe('mock judge under the Tokyo rules', () => {
  it('wallpaper yellowed after a 7-year tenancy: ageing (TKY-1), the tenant pays nothing', () => {
    const input = fixture('tokyo-wallpaper-ageing')
    const a = mockAnswers(input)
    expect(a.items).toEqual([expect.objectContaining({ material: 'wallpaper', cause: 'ageing', rules: ['TKY-1'] })])
    expect(a.rules).toEqual(['TKY-1'])
    const d = mockDecide(input)
    expect(d.ruling.decision).toBe('propose')
    expect(d.ruling.rubric).toMatchObject({ version: 'rentouts-rubric-v2-tokyo', depositKept: '0', tenantBps: 10_000 })
    expect(d.ruling.tenantBps).toBe(10_000)
  })

  it('wallpaper the tenant admits scribbling on, after 7 years: charged at the nominal residual only (~0)', () => {
    const input = withStatements(
      'tokyo-wallpaper-ageing',
      "The tenant's child scribbled with crayon on the living-room wallpaper. Replacing it costs the whole deposit.",
      'I admit my child drew on the wallpaper. It had been up for all of my 7-year tenancy.',
    )
    const a = mockAnswers(input)
    expect(a.damageBeyondNormalWear.answer).toBe('yes')
    expect(a.items).toEqual([expect.objectContaining({ material: 'wallpaper', cause: 'tenant_damage', rules: ['TKY-2', 'TKY-4', 'TKY-5'] })])
    const d = mockDecide(input)
    const item = d.ruling.rubric!.items![0]!
    expect(item).toMatchObject({ usefulLifeYears: 6, tenantShareBps: 1 })
    expect(BigInt(item.charge)).toBeLessThan(100n) // 0.0001 USDC on a 0.3 USDC deposit
    expect(d.ruling.decision).toBe('propose')
    expect(d.ruling.tenantBps).toBe(10_000)

    // The same damage in the first year of a tenancy is charged at (nearly) full cost.
    const fresh = withStatements('damage-admitted', input.evidence[0]!.statement, 'I admit my child drew on the wallpaper.')
    const f = mockDecide(fresh)
    expect(f.ruling.rubric!.items![0]!.tenantShareBps).toBe(10_000)
    expect(BigInt(f.ruling.rubric!.depositKept)).toBeGreaterThan(0n)
  })

  it('a hole punched in a wall: tenant damage (TKY-2), the tenant pays', () => {
    const d = mockDecide(fixture('tokyo-hole-in-wall'))
    expect(d.ruling.answers!.items).toEqual([expect.objectContaining({ material: 'wallpaper', cause: 'tenant_damage' })])
    expect(d.ruling.decision).toBe('propose')
    expect(d.ruling.rubric).toMatchObject({ depositKept: '180000', tenantBps: 7500 })
    expect(d.ruling.tenantBps).toBeLessThan(10_000)
    expect(proposalSummary(d.ruling)).toMatch(/\[tokyo-restoration v1\.0\.0: TKY-2, TKY-4, TKY-5\]$/)
  })

  it('tatami faded by the sun: ageing (TKY-1), the landlord pays', () => {
    const input = withStatements(
      'damage-admitted',
      "The tatami by the balcony is faded by the sun and has to be re-covered at the tenant's cost.",
      'That is ordinary sun fading from the balcony window; I kept the room clean.',
    )
    const a = mockAnswers(input)
    expect(a.items).toEqual([expect.objectContaining({ material: 'tatami_surface', cause: 'ageing' })])
    expect(a.damageBeyondNormalWear.answer).toBe('no')
    const d = mockDecide(input)
    expect(d.ruling.decision).toBe('propose')
    expect(d.ruling.rubric!.depositKept).toBe('0')
    expect(d.ruling.tenantBps).toBe(10_000)
  })

  it('a landlord claim with nothing behind it, contested: not established (TKY-7), nothing charged, and the judge abstains', () => {
    const input = withStatements(
      'damage-admitted',
      'The walls are damaged. I am keeping the whole deposit.',
      'I did not damage the walls; they are exactly as they were at move-in.',
    )
    const a = mockAnswers(input)
    expect(a.items).toEqual([expect.objectContaining({ cause: 'not_established', rules: ['TKY-7'] })])
    const d = mockDecide(input)
    expect(d.ruling.decision).toBe('abstain') // existing policy: contested with nothing to tell the sides apart
    expect(d.ruling.abstainReasons).toContain('evidence insufficient to decide')
    expect(d.ruling.rubric).toMatchObject({ depositKept: '0', tenantBps: 10_000 }) // what the rules give the tenant
  })

  it('a landlord who posts nothing: the one-sided tenant statement still goes to the human', () => {
    const input = structuredClone(fixture('tokyo-wallpaper-ageing'))
    input.evidence = input.evidence.filter((e) => e.party === 'tenant')
    const d = mockDecide(input)
    expect(d.ruling.decision).toBe('abstain')
    expect(d.ruling.abstainReasons).toContain("only the tenant has posted a statement; the landlord's silence is not an admission")
  })
})

describe('Tokyo rules in the answers and the ruling', () => {
  const tenantDamage: JudgeAnswers = answers({
    damageBeyondNormalWear: { answer: 'yes', confidence: 0.9 },
    severity: 3,
    rules: ['TKY-2'],
    items: [{ item: 'wall', material: 'wallpaper', cause: 'tenant_damage', confidence: 0.9, severity: 3, ageYears: null, rules: ['TKY-2'] }],
  })

  it('the schema takes rule ids from the pack only', () => {
    expect(JudgeAnswersSchema.safeParse(tenantDamage).success).toBe(true)
    expect(JudgeAnswersSchema.safeParse({ ...tenantDamage, rules: ['TKY-99'] }).success).toBe(false)
    expect(JudgeAnswersSchema.safeParse({ ...tenantDamage, items: [{ ...tenantDamage.items![0], material: 'marble' }] }).success).toBe(false)
  })

  it('the ruling records the pack and rulingHash commits to it; rulings without it hash as before', () => {
    const input = fixture('tokyo-hole-in-wall')
    const withPack = decide(input, tenantDamage, judge, 0.7, opts)
    const without = decide(input, tenantDamage, judge, 0.7)
    expect(withPack.ruling.rules).toEqual(TOKYO_RULES_REF)
    expect(without.ruling).not.toHaveProperty('rules')
    expect(withPack.rulingHash).not.toBe(without.rulingHash)
    expect(withPack.rulingHash).toBe(canonicalHash(withPack.ruling))
  })

  it('a tenant-damage item it is unsure of pulls the confidence down', () => {
    const unsure = structuredClone(tenantDamage)
    unsure.items![0]!.confidence = 0.55
    const d = decide(fixture('tokyo-hole-in-wall'), unsure, judge, 0.7, opts)
    expect(d.ruling.decision).toBe('abstain')
    expect(d.ruling.confidenceBps).toBe(5500)
  })

  it('answers that contradict their own items abstain', () => {
    const input = fixture('tokyo-hole-in-wall')
    const noItem = structuredClone(tenantDamage)
    noItem.items![0]!.cause = 'ageing'
    expect(decide(input, noItem, judge, 0.7, opts).ruling.abstainReasons).toEqual([
      'answers inconsistent: damage beyond normal wear is "yes" but no claimed item is classified as tenant damage',
    ])
    const noDamage = { ...tenantDamage, damageBeyondNormalWear: { answer: 'no' as const, confidence: 0.9 } }
    const d = decide(input, noDamage, judge, 0.7, opts)
    expect(d.ruling.abstainReasons).toEqual(['answers inconsistent: an item is classified as tenant damage but damage beyond normal wear is "no"'])
    expect(d.ruling.rubric!.depositKept).toBe('0') // nothing is charged on the weaker answer
  })
})

describe('CLI on the Tokyo fixtures', () => {
  it('prints the rules pack, the cited rules and the per-item depreciation, and records the pack in the ruling', () => {
    const cwd = new URL('..', import.meta.url).pathname
    const { ZAI_API_KEY: _drop, ...env } = process.env
    const r = spawnSync(process.execPath, ['src/cli.ts', '--input', 'fixtures/tokyo-wallpaper-ageing.json', '--provider', 'mock', '--json', '--out', '/dev/null'], {
      cwd,
      encoding: 'utf8',
      env,
    })
    expect(r.status).toBe(0)
    expect(r.stderr).toMatch(/rules cited\s+TKY-1/)
    expect(r.stderr).toMatch(/rules pack\s+tokyo-restoration v1\.0\.0 \(0x[0-9a-f]{64}\)/)
    expect(r.stderr).toMatch(/item\s+wallpaper \[wallpaper\] ageing, .*age 7\.01 of 6 y -> tenant share 0\.01%: charge 0 USDC/)
    expect(r.stderr).toMatch(/PROPOSE tenantBps 10000/)
    expect(JSON.parse(r.stdout).rules).toEqual(TOKYO_RULES_REF)
  })
})
