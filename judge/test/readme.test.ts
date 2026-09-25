import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

describe('README demo commands', () => {
  it('every cast send / cast call names its RPC (foundry.toml has no default: cast would use localhost:8545)', () => {
    const readme = readFileSync(new URL('../README.md', import.meta.url), 'utf8')
    const casts = readme.split('\n').filter((line) => /^\s*cast (send|call)\b/.test(line))
    expect(casts.length).toBeGreaterThanOrEqual(6)
    for (const line of casts) expect(line, line).toMatch(/--rpc-url \S+/)
  })
})
