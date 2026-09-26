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
  if (status === 'revoked') return { verified: false, reason: 'This credential was revoked by Dignity.' }
  if (!address) return { verified: false, reason: 'This name doesn’t resolve to an address.' }
  if (!expectedHolder) return { verified: false, reason: 'Dignity has no holder on record for this name.' }
  if (!isAddressEqual(address, expectedHolder)) {
    return { verified: false, reason: 'The name resolves to a different address than its Dignity holder.' }
  }
  if (status !== 'active') return { verified: false, reason: 'This name has no active Dignity credential.' }
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

/** The RentEscrow.tenantStats fields CredentialSync.sync turns into records. */
export type SyncedStats = {
  leasesCompleted: number
  leasesDisputed: number
  rentPaid: bigint
  depositsPosted: bigint
  depositsReturned: bigint
}

type SyncedKey = 'rentouts.leasesCompleted' | 'rentouts.disputes' | 'rentouts.rentPaid' | 'rentouts.depositReturnRate'

/** The records CredentialSync.sync(tenant) writes for these stats, formatted exactly as it does. */
export function syncedRecords(stats: SyncedStats): Record<SyncedKey, string> {
  // CredentialSync._usdc: 6-decimal USDC as "whole.cc", truncated to cents.
  const cents = (stats.rentPaid % 1_000_000n) / 10_000n
  // CredentialSync._rate: whole percent returned, rounded down, capped at 100; "n/a" before any deposit.
  const rate =
    stats.depositsPosted === 0n ? 'n/a' : String(Math.min(100, Number((stats.depositsReturned * 100n) / stats.depositsPosted)))
  return {
    'rentouts.leasesCompleted': String(stats.leasesCompleted),
    'rentouts.disputes': String(stats.leasesDisputed),
    'rentouts.rentPaid': `${stats.rentPaid / 1_000_000n}.${String(cents).padStart(2, '0')}`,
    'rentouts.depositReturnRate': rate,
  }
}

const NO_HISTORY = syncedRecords({ leasesCompleted: 0, leasesDisputed: 0, rentPaid: 0n, depositsPosted: 0n, depositsReturned: 0n })

/**
 * The escrow-derived records that a sync would change right now. A record that was never written counts as
 * an empty history. Rent claims and dispute resolutions move rentPaid and the deposit rate on their own.
 */
export function staleCredentialKeys(records: Partial<Record<CredentialKey, string | null>>, stats: SyncedStats): SyncedKey[] {
  const now = syncedRecords(stats)
  return (Object.keys(now) as SyncedKey[]).filter((key) => (records[key] ?? NO_HISTORY[key]) !== now[key])
}
