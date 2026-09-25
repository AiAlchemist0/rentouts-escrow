import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { canonicalHash } from '../src/canonical.ts'

const cwd = new URL('..', import.meta.url).pathname
const dir = mkdtempSync(join(tmpdir(), 'judge-cli-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))

function judge(args: string[], env: Record<string, string> = {}) {
  const { ZAI_API_KEY: _drop, ...rest } = process.env
  return spawnSync(process.execPath, ['src/cli.ts', ...args], { cwd, encoding: 'utf8', env: { ...rest, ...env } })
}

describe('npm run judge (offline --input, mock provider)', () => {
  it('proposes for the demo fixture, prints the latency, and saves a ruling that verifies', () => {
    const out = join(dir, 'ruling.json')
    const r = judge(['--input', 'fixtures/damage-admitted.json', '--provider', 'mock', '--json', '--out', out])
    expect(r.status).toBe(0)
    expect(r.stderr).toMatch(/latency\s+\d+ ms/)
    expect(r.stderr).toMatch(/PROPOSE tenantBps 7500/)
    const printed = JSON.parse(r.stdout)
    const saved = JSON.parse(readFileSync(out, 'utf8'))
    expect(saved.ruling).toEqual(printed)
    expect(saved.rulingHash).toBe(canonicalHash(printed))
    const v = judge(['--verify', out])
    expect(v.status).toBe(0)
    expect(v.stdout).toMatch(/matches the saved hash/)
  })

  it('abstains on the injection fixture: escalated to human arbiter', () => {
    const r = judge(['--input', 'fixtures/injection.json', '--provider', 'mock', '--out', join(dir, 'inj.json')])
    expect(r.status).toBe(0)
    expect(r.stdout).toMatch(/ABSTAIN/)
    expect(r.stdout).toMatch(/escalated to human arbiter/)
  })

  it('--propose is refused for an offline input', () => {
    const r = judge(['--input', 'fixtures/damage-admitted.json', '--provider', 'mock', '--propose'])
    expect(r.status).toBe(2)
    expect(r.stderr).toMatch(/--propose needs a lease read from the chain/)
  })

  it('glm without a key fails clearly', () => {
    const r = judge(['--input', 'fixtures/damage-admitted.json'])
    expect(r.status).toBe(1)
    expect(r.stderr).toMatch(/ZAI_API_KEY is not set/)
  })

  it('--help', () => {
    expect(execFileSync(process.execPath, ['src/cli.ts', '--help'], { cwd, encoding: 'utf8' })).toMatch(/--provider/)
  })
})
