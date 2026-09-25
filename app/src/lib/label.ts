import { isAddress } from 'viem'
import { normalize } from 'viem/ens'

export type LabelCheck = { ok: true; label: string } | { ok: false; reason: string }

/** Same rule as RentoutsSubnames._validateLabel: a strict subset of ENSIP-15 normalized labels. */
const LABEL_RE = /^[a-z0-9-]{3,32}$/

/**
 * Validates a subname label the way the contract will: first ENS normalization (viem `normalize`,
 * ENSIP-15), then the contract's rule (3-32 of [a-z0-9-], no leading/trailing hyphen, no "--" at
 * positions 3-4). Returns the normalized label to send on-chain.
 */
export function checkLabel(input: string): LabelCheck {
  const raw = input.trim()
  if (raw === '') return { ok: false, reason: 'Enter a name.' }
  if (raw.includes('.')) return { ok: false, reason: 'Enter only the first part of the name, without dots.' }
  // ENSIP-15 rejects this too, but with a less helpful message, so check it first.
  if (raw.length >= 4 && raw[2] === '-' && raw[3] === '-') {
    return { ok: false, reason: 'Hyphens in positions 3 and 4 are reserved by ENS.' }
  }

  let label: string
  try {
    label = normalize(raw)
  } catch {
    return { ok: false, reason: 'ENS can’t normalize this name. Use lowercase letters, digits and hyphens.' }
  }

  if (label.length < 3) return { ok: false, reason: 'Use at least 3 characters.' }
  if (label.length > 32) return { ok: false, reason: 'Use at most 32 characters.' }
  if (!LABEL_RE.test(label)) return { ok: false, reason: 'Use only lowercase letters a–z, digits and hyphens.' }
  if (label.startsWith('-') || label.endsWith('-')) {
    return { ok: false, reason: 'A name can’t start or end with a hyphen.' }
  }
  if (label[2] === '-' && label[3] === '-') {
    return { ok: false, reason: 'Hyphens in positions 3 and 4 are reserved by ENS.' }
  }
  return { ok: true, label }
}

/**
 * True for input that should be resolved as an ENS name rather than parsed as an address. Decided by
 * address shape, not by a "0x" prefix: `0xrent` is a valid label, so `0xrent.rentouts.eth` is a name.
 */
export function looksLikeEnsName(input: string): boolean {
  const v = input.trim()
  return v.includes('.') && !isAddress(v, { strict: false })
}
