import { isAddressEqual, keccak256, stringToBytes, type Address } from 'viem'
import type { CredentialKey } from '../config'

export type CredentialRecords = Record<CredentialKey, string | null>

export type Trust = { verified: true } | { verified: false; reason: string }

/**
 * The frontend trust check from ens/README.md: show rentouts.* values only when the name is an active
 * RentOuts credential AND it resolves to the holder RentoutsSubnames has on record for the label.
 */
export function evaluateCredential(input: {
  address: Address | null
  status: string | null
  expectedHolder: Address | null
}): Trust {
  const { address, status, expectedHolder } = input
  if (status === 'revoked') return { verified: false, reason: 'This credential was revoked by RentOuts.' }
  if (!address) return { verified: false, reason: 'This name doesn’t resolve to an address.' }
  if (!expectedHolder) return { verified: false, reason: 'RentOuts has no holder on record for this name.' }
  if (!isAddressEqual(address, expectedHolder)) {
    return { verified: false, reason: 'The name resolves to a different address than its RentOuts holder.' }
  }
  if (status !== 'active') return { verified: false, reason: 'This name has no active RentOuts credential.' }
  return { verified: true }
}

/** Display form of a credential text record. Numbers get their unit; anything else is shown as written. */
export function formatRecord(key: CredentialKey, value: string | null): string {
  if (value === null || value.trim() === '') return '—'
  const v = value.trim()
  const numeric = /^\d+(\.\d+)?$/.test(v)
  if (key === 'rentouts.rentPaid' && numeric) return `${v} USDC`
  if (key === 'rentouts.depositReturnRate' && numeric) return `${v}%`
  return v
}

/** "alice.rentouts.eth" + "rentouts.eth" -> "alice"; null if the name isn't a direct child of the parent. */
export function labelUnder(name: string, parent: string): string | null {
  const suffix = `.${parent}`
  if (!name.endsWith(suffix)) return null
  const label = name.slice(0, -suffix.length)
  return label && !label.includes('.') ? label : null
}

/**
 * RentoutsSubnames' labelId, uint256(keccak256(bytes(label))): the key of holderOf. The label is hashed as UTF-8
 * text. (viem's toBytes would read a label like "0xdead" as hex and hash two bytes instead.)
 */
export function labelId(label: string): bigint {
  return BigInt(keccak256(stringToBytes(label)))
}
