import { USEFUL_LIFE_YEARS, type Material, type RuleId } from '../rules/tokyo.ts'
import { manipulationIn } from '../screen.ts'
import type { ClaimedItem, DisputeInput, EvidenceItem, JudgeAnswers, YesNo } from '../types.ts'
import type { JudgeProvider, ProviderResult } from './types.ts'

/**
 * Deterministic keyword judge, for tests and for demos without an API key. Same input, same
 * answers, no network. It is NOT a real judge: it only recognises a few obvious patterns (a
 * damage claim the tenant admits or denies, an early-termination claim, manipulation attempts).
 * It follows the same rules as the LLM prompt: a claim contested with nothing to tell the sides
 * apart is "insufficient", so is a claim against a party who has posted nothing (silence is not an
 * admission), a claim the other party leaves unaddressed gets a low confidence, and any statement
 * that tries to instruct the judge or claims the case was already decided sends the case to the
 * human. decide() adds the code-level screen (screen.ts) on top, for every provider.
 */
export const MOCK_MODEL = 'mock-keywords-v1'

const DAMAGE =
  /\b(damag\w*|broken|broke|smashed|cracked|crack|holes?|burn\w*|stain\w*|missing|destroy\w*|flood\w*|mou?ld|punch\w*|kick\w*|scribbl\w*|crayon|graffiti|gouge\w*|torn|tore|ripped)\b/i
const TENANT_ADMITS_DAMAGE =
  /\b(i|we)\s+(accidentally\s+)?(broke|damaged|cracked|smashed|burn(ed|t)|stained|caused|lost)\b|\bmy fault\b|\b(i|we) admit\b|\b(i'?m|i am) sorry\b|\b(i|we) will pay\b/i
const TENANT_DENIES_DAMAGE =
  /\bpre-?existing\b|\balready (there|broken|damaged|cracked|stained)\b|\bat move-?in\b|\b(move|check)-?in (report|photos?|inspection|checklist)\b|\bnormal wear\b|\bwear and tear\b|\bnot (my|our) fault\b|\b(did not|didn'?t|never) (break|damage|crack|cause|stain)\b|\bwas like that\b/i
const SEVERITY: Array<[RegExp, number]> = [
  [/\b(destroy\w*|flood\w*|fire|structural|uninhabitable)\b/i, 5],
  [/\b(burn\w*|hole in the wall|water damage|replace (the )?(floor|carpet|appliance|door))\b/i, 4],
  [/\b(minor|small|scratch\w*|chip\w*|scuff\w*|tiny)\b/i, 2],
]
const RENT_CLAIM =
  /\b(left early|moved out early|abandon\w*|broke the lease|without (any )?notice|no notice|early terminat\w*|terminated early|owes? (me )?(the )?rent|unpaid rent|rent (is )?owed|rest of the (term|lease))\b/i
const TENANT_ADMITS_RENT = /\b(i|we) (left|moved out)( early| without (any )?notice)\b|\b(i|we) did not give notice\b/i
const TENANT_DENIES_RENT = /\b(gave|given|sent|with)\b[^.]{0,25}\bnotice\b|\bagreed to (end|terminate)\b|\bmutual(ly)?\s+agree\w*\b/i

// Restoration items the Tokyo rules pack covers (rules/tokyo.ts). Other things (a window, a key)
// get no item entry and are judged on the overall damage answer (rubric v1), as before the pack.
const MATERIAL_WORDS: Array<[Material, RegExp]> = [
  ['cushion_floor', /\bcushion[- ]?floor\w*/i],
  ['wallpaper', /\b(wall ?paper|walls?)\b/i],
  ['carpet', /\bcarpets?\b/i],
  ['tatami_surface', /\btatami\b/i],
  ['fusuma_shoji', /\b(fusuma|shoji)\b/i],
  ['flooring_spot', /\b(floor(ing|boards?)?)\b/i],
]
const NORMAL_USE = /\b(furniture (marks?|dents?)|dents? from (the )?furniture|behind the (fridge|refrigerator)|pin ?holes?|posters?)\b/i
const AGEING = /\b(sun(light)?|fad\w*|yellow\w*|discolou?r\w*|aged|ageing|aging|old|years of use|worn)\b/i
const AGE_YEARS = /\b(\d{1,2}(?:\.\d+)?)\s*(?:years?\s*old|-year-old|years? of use)\b/i

function sentencesAbout(text: string, re: RegExp): string[] {
  return text.split(/(?<=[.!?])\s+|\n/).filter((x) => re.test(x))
}

/** One entry per restoration material the landlord claims for, classified like the prompt asks. */
function classifyItems(L: string, T: string, damageAdmitted: boolean, damageDenied: boolean): ClaimedItem[] {
  const items: ClaimedItem[] = []
  for (const [material, re] of MATERIAL_WORDS) {
    if (items.some((i) => re.test(i.item))) continue // "cushion floor" is not also "floor"
    const claim = sentencesAbout(L, re)
    if (claim.length === 0) continue
    const text = claim.join(' ')
    const name = text.match(re)![0].toLowerCase()
    const depreciable = USEFUL_LIFE_YEARS[material] !== undefined
    let cause: ClaimedItem['cause']
    let confidence: number
    let rules: RuleId[]
    if (NORMAL_USE.test(text)) [cause, confidence, rules] = ['normal_use', 0.85, ['TKY-1']]
    else if (DAMAGE.test(text)) {
      if (damageAdmitted) [cause, confidence] = ['tenant_damage', 0.9]
      else if (damageDenied) [cause, confidence] = ['not_established', 0.5]
      else [cause, confidence] = ['tenant_damage', 0.6]
      rules = cause === 'tenant_damage' ? ['TKY-2', 'TKY-4', ...(depreciable ? (['TKY-5'] as RuleId[]) : [])] : ['TKY-7']
    } else if (AGEING.test(text)) [cause, confidence, rules] = ['ageing', 0.85, ['TKY-1']]
    else [cause, confidence, rules] = ['not_established', 0.6, ['TKY-7']]
    let severity = 3
    for (const [sre, sv] of SEVERITY) {
      if (sre.test(text)) {
        severity = sv
        break
      }
    }
    const age = (sentencesAbout(L, re).join(' ').match(AGE_YEARS) ?? sentencesAbout(T, re).join(' ').match(AGE_YEARS))?.[1]
    items.push({ item: name, material, cause, confidence, severity, ageYears: age ? Number(age) : null, rules })
    if (items.length === 6) break
  }
  return items
}

const CAUSE_TEXT: Record<ClaimedItem['cause'], string> = {
  ageing: "ageing, the landlord's cost",
  normal_use: "normal wear, the landlord's cost",
  tenant_damage: 'damage the tenant caused, charged at its depreciated value',
  not_established: 'not shown to be the tenant’s damage, not charged',
}

const yes = (confidence: number): YesNo => ({ answer: 'yes', confidence })
const no = (confidence: number): YesNo => ({ answer: 'no', confidence })
const ids = (items: EvidenceItem[]) => items.map((e) => e.id).join(', ')

export function mockAnswers(input: DisputeInput): JudgeAnswers {
  const landlord = input.evidence.filter((e) => e.party === 'landlord')
  const tenant = input.evidence.filter((e) => e.party === 'tenant')
  const L = landlord.map((e) => e.statement).join('\n')
  const T = tenant.map((e) => e.statement).join('\n')
  const why: string[] = []

  const manipulative = input.evidence.filter(manipulationIn)
  const damageClaim = DAMAGE.test(L)
  const damageAdmitted = damageClaim && TENANT_ADMITS_DAMAGE.test(T)
  const damageDenied = damageClaim && !damageAdmitted && TENANT_DENIES_DAMAGE.test(T)
  const rentClaim = RENT_CLAIM.test(L)
  const rentAdmitted = rentClaim && TENANT_ADMITS_RENT.test(T)
  const rentDenied = rentClaim && !rentAdmitted && TENANT_DENIES_RENT.test(T)

  let damage: YesNo
  if (!damageClaim) damage = no(0.9)
  else if (damageAdmitted) {
    damage = yes(0.9)
    why.push(`The tenant admits the damage the landlord describes (${ids([...landlord, ...tenant])}).`)
  } else if (damageDenied) {
    damage = no(0.5)
    why.push(`The landlord claims damage and the tenant disputes it; nothing independent tells them apart.`)
  } else {
    damage = yes(0.6)
    why.push(`The landlord's damage claim is not contested but is not corroborated either.`)
  }

  // Tokyo rules: classify each restoration item claimed; the overall damage answer follows the items.
  const items = classifyItems(L, T, damageAdmitted, damageDenied)
  const tenantItems = items.filter((i) => i.cause === 'tenant_damage')
  if (tenantItems.length > 0 && damage.answer === 'no') damage = yes(Math.min(...tenantItems.map((i) => i.confidence)))
  for (const i of items) why.push(`${i.item}: ${CAUSE_TEXT[i.cause]} (${i.rules.join(', ')}).`)

  let rent: YesNo
  if (!rentClaim) rent = no(0.9)
  else if (rentAdmitted) {
    rent = yes(0.85)
    why.push('The tenant admits leaving early without notice, so the rest of the term is owed.')
  } else if (rentDenied) {
    rent = no(0.5)
    why.push('The landlord claims the rest of the rent; the tenant says notice was given.')
  } else {
    rent = yes(0.6)
    why.push(`The landlord's rent claim is uncontested but unproven.`)
  }

  let sufficient: YesNo
  if (input.evidence.length === 0) {
    sufficient = no(0.95)
    why.push('Neither party submitted a statement.')
  } else if (manipulative.length > 0) {
    sufficient = no(0.9)
    why.unshift(
      `Statement(s) ${ids(manipulative)} try to instruct the judge or claim the case was already decided; treated as claims, sent to the human arbiter.`,
    )
  } else if (damageDenied || rentDenied) sufficient = no(0.8)
  else if ((damageClaim || rentClaim) && tenant.length === 0) {
    sufficient = no(0.8)
    why.push('The tenant has posted no statement, and silence is not an admission.')
  }
  else if (!damageClaim && !rentClaim && items.length === 0) {
    sufficient = yes(0.85)
    why.push('No damage or rent claim is made: deposit and unused rent go back to the tenant.')
  } else sufficient = yes(0.85)

  let severity = 1
  if (tenantItems.length > 0) severity = Math.max(...tenantItems.map((i) => i.severity))
  else if (damage.answer === 'yes') {
    severity = 3
    for (const [re, s] of SEVERITY) {
      if (re.test(L) || re.test(T)) {
        severity = s
        break
      }
    }
  }

  return {
    damageBeyondNormalWear: damage,
    rentClaimValid: rent,
    evidenceSufficient: sufficient,
    severity,
    rationale: why.join(' ').slice(0, 800) || 'No claims beyond the lease facts.',
    ...(items.length > 0 ? { rules: [...new Set(items.flatMap((i) => i.rules))].sort() as RuleId[], items } : {}),
  }
}

export class MockProvider implements JudgeProvider {
  readonly name = 'mock'
  readonly model = MOCK_MODEL

  async judge(input: DisputeInput): Promise<ProviderResult> {
    return { answers: mockAnswers(input), model: MOCK_MODEL, attempts: 1, notes: ['deterministic mock provider'] }
  }
}
