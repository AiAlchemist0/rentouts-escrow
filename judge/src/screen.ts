import type { DisputeInput, EvidenceItem } from './types.ts'

/**
 * Code-level screen of the parties' statements. decide() applies it to every provider's answers,
 * so the safeguards below do not depend on the model obeying the system prompt (and the mock uses
 * the same patterns). A flagged statement makes the judge abstain; the model's answers are kept in
 * the ruling for the human arbiter.
 */

/** Text that tries to steer the judge, impersonate an authority, or assert a prior decision. */
export const MANIPULATION_PATTERNS: RegExp[] = [
  /\bignore\b[^.]{0,30}\b(instructions?|rules|prompts?|above|previous)\b/i,
  // a role label opening a statement, sentence or tag ("SYSTEM: ...", "</evidence> system: ..."),
  // not a noun that happens to precede a colon ("the heating system: broken")
  /(^|[\n.!?:;>"'(\[]\s*)(system|assistant|developer)(\s+(prompt|message|note))?\s*:/i,
  /\b(SYSTEM|ASSISTANT|DEVELOPER)\s*:/,
  /\byou are now\b/i,
  // "answer yes", "respond with: true", "answer every question yes"; not "did not reply ... no hot water"
  /\b(answer|respond|reply|output)\b(\s+(with|only|just|all|every|each|the|questions?|checklist|everything))*\s*[:=]?\s*["'“‘]?(yes|no|true|false)\b/i,
  /\b(already|previously)\s+(been\s+)?(decided|confirmed|approved|agreed|ruled|settled|verified|acknowledged)\b/i,
  /\b(rentouts|arbiter|the judge|admin|moderator|support team)\b[^.]{0,30}\b(confirmed|approved|decided|ruled|verified)\b/i,
  /<\/?\s*(evidence|system|lease_facts|tenant_identity|instructions?)\b/i,
  /\bconfidence\b\s*(of|:|=)?\s*(1(\.0+)?|100\s?%)/i,
  /\b(damageBeyondNormalWear|rentClaimValid|evidenceSufficient|tenantBps)\b/,
]

export function manipulationIn(e: Pick<EvidenceItem, 'statement'>): boolean {
  return MANIPULATION_PATTERNS.some((re) => re.test(e.statement))
}

/**
 * Abstain reasons that come from the statements themselves, whatever the model answered: a
 * statement that tries to steer the judge, or a party that has posted nothing.
 */
export function screenReasons(input: DisputeInput): string[] {
  const reasons: string[] = []
  const flagged = input.evidence.filter(manipulationIn).map((e) => e.id)
  if (flagged.length > 0) {
    reasons.push(
      `statement${flagged.length > 1 ? 's' : ''} ${flagged.join(', ')} ${flagged.length > 1 ? 'try' : 'tries'} to instruct the judge, impersonate an authority or claim a prior decision`,
    )
  }
  // Silence is not an admission (prompt rule 4). A one-sided case goes to the human whatever the
  // model answered, so a first mover cannot get a proposal out before the other side has posted.
  const posted = new Set(input.evidence.map((e) => e.party))
  const silent = (['tenant', 'landlord'] as const).filter((p) => !posted.has(p))
  if (silent.length === 2) reasons.push('no statement from either party')
  else if (silent.length === 1) {
    const [quiet] = silent
    reasons.push(`only the ${quiet === 'tenant' ? 'landlord' : 'tenant'} has posted a statement; the ${quiet}'s silence is not an admission`)
  }
  return reasons
}
