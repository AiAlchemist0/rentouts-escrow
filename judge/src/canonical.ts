import { keccak256, stringToBytes } from 'viem'
import type { Hex } from './types.ts'

/**
 * Canonical JSON in the spirit of RFC 8785 (JCS): object keys sorted by UTF-16 code units, no
 * whitespace, JavaScript number formatting, `undefined` object members dropped. bigint values are
 * written as decimal strings. Two objects with the same content always give the same string, in
 * whatever order their keys were built, so the hash of a ruling is reproducible by anyone.
 */
export function canonicalJson(value: unknown): string {
  return serialize(value)
}

function serialize(value: unknown): string {
  if (value === null) return 'null'
  switch (typeof value) {
    case 'boolean':
      return value ? 'true' : 'false'
    case 'number':
      if (!Number.isFinite(value)) throw new Error(`canonicalJson: non-finite number ${value}`)
      return JSON.stringify(value)
    case 'bigint':
      return JSON.stringify(value.toString())
    case 'string':
      return JSON.stringify(value)
    case 'object': {
      if (Array.isArray(value)) return `[${value.map((v) => serialize(v === undefined ? null : v)).join(',')}]`
      const entries = Object.entries(value as Record<string, unknown>)
        .filter(([, v]) => v !== undefined)
        .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${serialize(v)}`).join(',')}}`
    }
    default:
      throw new Error(`canonicalJson: cannot serialize ${typeof value}`)
  }
}

/** keccak256 of the UTF-8 bytes of canonicalJson(value). */
export function canonicalHash(value: unknown): Hex {
  return keccak256(stringToBytes(canonicalJson(value)))
}
