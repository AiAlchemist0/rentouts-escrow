import { getAddress, isAddress, type Address } from 'viem'
import { normalize } from 'viem/ens'
import { errorMessage } from './errors'
import { looksLikeEnsName } from './label'

export type ResolvedInput =
  | { kind: 'empty' }
  /** The text changed and the debounced lookup hasn't caught up yet. Nothing may be sent. */
  | { kind: 'pending' }
  | { kind: 'loading'; name: string }
  | { kind: 'address'; address: Address }
  | { kind: 'name'; name: string; address: Address }
  | { kind: 'error'; message: string }

export type ParsedInput =
  | { kind: 'empty' }
  | { kind: 'address'; address: Address }
  | { kind: 'name'; name: string }
  | { kind: 'error'; message: string }

/** What the text is, before any network lookup: an address, a normalized ENS name, or neither. */
export function parseAddressInput(text: string): ParsedInput {
  const value = text.trim()
  if (value === '') return { kind: 'empty' }
  if (isAddress(value, { strict: false })) return { kind: 'address', address: getAddress(value) }
  if (!looksLikeEnsName(value)) return { kind: 'error', message: 'Enter an ENS name (name.eth) or a 0x address.' }
  try {
    return { kind: 'name', name: normalize(value) }
  } catch {
    return { kind: 'error', message: 'That isn’t a valid ENS name.' }
  }
}

/** The parts of the Universal Resolver query that the result depends on. */
export type NameLookup = {
  isPending: boolean
  isError: boolean
  error: unknown
  data: Address | null | undefined
}

/**
 * Combines the live text, the debounced text that the name lookup ran on, and that lookup. A raw address
 * is taken from the live text straight away. Anything else is `pending` until the debounce catches up, so
 * a submit right after an edit can never send the previously entered recipient.
 */
export function resolveAddressInput(live: string, debounced: string, lookup: NameLookup): ResolvedInput {
  const now = parseAddressInput(live)
  if (now.kind === 'empty' || now.kind === 'address') return now
  if (live.trim() !== debounced.trim()) return { kind: 'pending' }
  if (now.kind === 'error') return now
  if (lookup.isPending) return { kind: 'loading', name: now.name }
  if (lookup.isError) return { kind: 'error', message: errorMessage(lookup.error) }
  if (!lookup.data) return { kind: 'error', message: `${now.name} doesn’t resolve to an address.` }
  return { kind: 'name', name: now.name, address: lookup.data }
}
