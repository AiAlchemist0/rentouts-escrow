import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { canonicalHash } from '../src/canonical.ts'
import { fixture } from './helpers.ts'

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
    expect(r.stderr).toMatch(/rent claim valid\s+no\s+\(p=0\.90\)\s+not counted in confidence: leaves the unearned rent with the tenant/)
    const printed = JSON.parse(r.stdout)
    const saved = JSON.parse(readFileSync(out, 'utf8'))
    expect(saved.ruling).toEqual(printed)
    expect(saved.rulingHash).toBe(canonicalHash(printed))
    const v = judge(['--verify', out])
    expect(v.status).toBe(0)
    expect(v.stdout).toMatch(/matches the saved hash/)
  })

  it('--verify refuses a saved file whose input was edited after the ruling (INPUT MISMATCH, exit 1)', () => {
    const out = join(dir, 'to-tamper.json')
    expect(judge(['--input', 'fixtures/damage-admitted.json', '--provider', 'mock', '--out', out]).status).toBe(0)
    const saved = JSON.parse(readFileSync(out, 'utf8'))
    const v = judge(['--verify', out])
    expect(v.status).toBe(0)
    expect(v.stdout).toMatch(/inputHash\s+0x[0-9a-f]{64}\s+\(matches ruling\.inputHash/)

    // Same ruling and rulingHash, different evidence: the ruling still hashes fine, the input does not.
    const tampered = structuredClone(saved)
    tampered.input.evidence[0].statement = 'The tenant smashed every window and flooded the flat.'
    tampered.input.lease.deposit = '900000'
    const bad = join(dir, 'tampered.json')
    writeFileSync(bad, JSON.stringify(tampered))
    const t = judge(['--verify', bad])
    expect(t.status).toBe(1)
    expect(t.stdout).toMatch(/rulingHash .*matches the saved hash/)
    expect(t.stdout).toMatch(/INPUT MISMATCH: the ruling was made on 0x[0-9a-f]{64}/)

    // A file without its rulingHash (or without its input) proves nothing.
    const { rulingHash: _h, ...noHash } = saved
    const nh = join(dir, 'no-hash.json')
    writeFileSync(nh, JSON.stringify(noHash))
    const n = judge(['--verify', nh])
    expect(n.status).toBe(1)
    expect(n.stdout).toMatch(/not a saved ruling: missing rulingHash/)
    const { input: _i, ...noInput } = saved
    writeFileSync(nh, JSON.stringify(noInput))
    expect(judge(['--verify', nh]).status).toBe(1)
  })

  it('every run keeps its own record: a later run on the same lease never overwrites an earlier ruling', () => {
    const outDir = join(dir, 'records')
    const args = ['--input', 'fixtures/damage-admitted.json', '--provider', 'mock', '--out-dir', outDir]
    const first = judge(args) // proposes
    const rerun = judge(args, { JUDGE_MIN_CONFIDENCE: '0.95' }) // same lease, abstains: a different ruling
    expect(first.status).toBe(0)
    expect(rerun.status).toBe(0)
    expect(rerun.stdout).toMatch(/ABSTAIN/)
    const hashOf = (stdout: string) => stdout.match(/rulingHash\s+(0x[0-9a-f]{64})/)![1]!
    const [a, b] = [hashOf(first.stdout), hashOf(rerun.stdout)]
    expect(a).not.toBe(b)

    const f = fixture('damage-admitted')
    const stem = `ruling-${f.chainId}-${f.arbiter.toLowerCase()}-${f.lease.leaseId}`
    // Both preimages are kept. No per-lease file: that one is written only after a confirmed --propose.
    expect(readdirSync(outDir).sort()).toEqual([`${stem}-${a}.json`, `${stem}-${b}.json`].sort())
    const kept = join(outDir, `${stem}-${a}.json`)
    expect(JSON.parse(readFileSync(kept, 'utf8')).rulingHash).toBe(a)
    expect(judge(['--verify', kept]).status).toBe(0)
  })

  it('--onchain only goes with --verify', () => {
    const r = judge(['--input', 'fixtures/damage-admitted.json', '--provider', 'mock', '--onchain'])
    expect(r.status).toBe(2)
    expect(r.stderr).toMatch(/--onchain goes with --verify/)
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
