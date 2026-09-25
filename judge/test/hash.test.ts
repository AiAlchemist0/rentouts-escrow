import { keccak256, stringToBytes } from 'viem'
import { describe, expect, it } from 'vitest'
import { canonicalHash, canonicalJson } from '../src/canonical.ts'
import { decide } from '../src/decide.ts'
import { mockAnswers } from '../src/providers/mock.ts'
import type { DisputeInput } from '../src/types.ts'
import { fixture } from './helpers.ts'

/** Rebuilds an object with its keys in reverse order, recursively. */
function reversed<T>(value: T): T {
  if (Array.isArray(value)) return value.map(reversed) as T
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).reverse().map(([k, v]) => [k, reversed(v)])) as T
  }
  return value
}

const judge = { provider: 'mock', model: 'mock-keywords-v1' }

describe('canonical JSON', () => {
  it('sorts keys, drops undefined, writes bigint as a string, no whitespace', () => {
    expect(canonicalJson({ b: 1, a: [true, null, 'x'], c: undefined, d: { z: 2n, y: 0.85 } })).toBe(
      '{"a":[true,null,"x"],"b":1,"d":{"y":0.85,"z":"2"}}',
    )
  })

  it('does not depend on key order', () => {
    const v = { lease: { b: '1', a: '2' }, list: [{ y: 1, x: 2 }], n: 3 }
    expect(canonicalJson(reversed(v))).toBe(canonicalJson(v))
    expect(canonicalHash(reversed(v))).toBe(canonicalHash(v))
  })

  it('refuses values JSON cannot represent', () => {
    expect(() => canonicalJson({ x: Number.NaN })).toThrow(/non-finite/)
    expect(() => canonicalJson({ f: () => 1 })).toThrow(/cannot serialize/)
  })

  it('hash = keccak256 of the UTF-8 canonical string (non-ASCII too)', () => {
    const v = { statement: '窓が割れていました', n: 1 }
    expect(canonicalHash(v)).toBe(keccak256(stringToBytes('{"n":1,"statement":"窓が割れていました"}')))
  })
})

describe('rulingHash', () => {
  const input = fixture('damage-admitted')

  it('is stable: same input and answers give the same hash, whatever the key order', () => {
    const a = decide(input, mockAnswers(input), judge, 0.7)
    const b = decide(reversed(input), reversed(mockAnswers(input)), judge, 0.7)
    expect(b.rulingHash).toBe(a.rulingHash)
    expect(canonicalHash(a.ruling)).toBe(a.rulingHash)
  })

  it('is pinned for the demo fixture (a change here means old rulings no longer verify)', () => {
    const d = decide(input, mockAnswers(input), judge, 0.7)
    expect(d.ruling.inputHash).toBe(canonicalHash(input))
    expect(d.rulingHash).toBe('0x3bb329e59c487d3032a08e6f58c4a71f2d811cff6c8361ffae464112afbbd530')
  })

  it('commits to every statement: editing one character changes it', () => {
    const edited: DisputeInput = structuredClone(input)
    edited.evidence[0]!.statement = edited.evidence[0]!.statement.replace('0.15', '0.16')
    const a = decide(input, mockAnswers(input), judge, 0.7)
    const b = decide(edited, mockAnswers(input), judge, 0.7)
    expect(b.ruling.inputHash).not.toBe(a.ruling.inputHash)
    expect(b.rulingHash).not.toBe(a.rulingHash)
  })

  it('commits to the answers, the model and the threshold', () => {
    const base = decide(input, mockAnswers(input), judge, 0.7).rulingHash
    const other = { ...mockAnswers(input), severity: 4 }
    expect(decide(input, other, judge, 0.7).rulingHash).not.toBe(base)
    expect(decide(input, mockAnswers(input), { provider: 'glm', model: 'glm-5.3' }, 0.7).rulingHash).not.toBe(base)
    expect(decide(input, mockAnswers(input), judge, 0.8).rulingHash).not.toBe(base)
  })
})
