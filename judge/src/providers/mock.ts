import { manipulationIn } from '../screen.ts'
import type { DisputeInput, EvidenceItem, JudgeAnswers, YesNo } from '../types.ts'
import type { JudgeProvider, ProviderResult } from './types.ts'

/**
 * Deterministic keyword judge, for tests and for demos without an API key. Same input, same
 * answers, no network. It is NOT a real judge: it only recognises a few obvious patterns (a
 * damage claim the tenant admits or denies, an early-termination claim, manipulation attempts).
 * It follows the same rules as the LLM prompt: a claim contested with nothing to tell the sides
 * apart is "insufficient", a one-sided claim gets a low confidence, and any statement that tries
 * to instruct the judge or claims the case was already decided sends the case to the human.
 */
export const MOCK_MODEL = 'mock-keywords-v1'

const DAMAGE = /\b(damag\w*|broken|broke|smashed|cracked|crack|holes?|burn\w*|stain\w*|missing|destroy\w*|flood\w*|mou?ld)\b/i
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
  else if (!damageClaim && !rentClaim) {
    sufficient = yes(0.85)
    why.push('No damage or rent claim is made: deposit and unused rent go back to the tenant.')
  } else sufficient = yes(tenant.length === 0 ? 0.6 : 0.85)

  let severity = 1
  if (damage.answer === 'yes') {
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
  }
}

export class MockProvider implements JudgeProvider {
  readonly name = 'mock'
  readonly model = MOCK_MODEL

  async judge(input: DisputeInput): Promise<ProviderResult> {
    return { answers: mockAnswers(input), model: MOCK_MODEL, attempts: 1, notes: ['deterministic mock provider'] }
  }
}
