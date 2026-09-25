import { describe, expect, it } from 'vitest'
import { decide } from '../src/decide.ts'
import { mockAnswers } from '../src/providers/mock.ts'
import { proposedPath, recordPath, verifyOnchain, verifySaved } from '../src/record.ts'
import type { Hex } from '../src/types.ts'
import { fixture } from './helpers.ts'

const input = fixture('damage-admitted')
const d = decide(input, mockAnswers(input), { provider: 'mock', model: 'mock-keywords-v1' }, 0.7)
const STATUS = { NONE: 0, PROPOSED: 1, APPEALED: 2, EXECUTED: 3, HUMAN_RESOLVED: 4 } as const

/** A read-only client stub answering getChainId and AIArbiter.getRuling. */
function chain(onchain: { status: number; tenantBps?: number; confidenceBps?: number; rulingHash?: Hex }, chainId = input.chainId) {
  const calls: unknown[] = []
  return {
    calls,
    client: {
      getChainId: async () => chainId,
      readContract: async (args: unknown) => {
        calls.push(args)
        return {
          tenantBps: d.ruling.tenantBps,
          confidenceBps: d.ruling.confidenceBps,
          rulingHash: d.rulingHash,
          proposedAt: 0n,
          deadline: 0n,
          ...onchain,
        }
      },
    } as never,
  }
}

describe('record paths', () => {
  it('one file per ruling hash; the per-lease file is a separate name', () => {
    const stem = `ruling-11155111-${input.arbiter.toLowerCase()}-${input.lease.leaseId}`
    expect(recordPath('/o', d.ruling, d.rulingHash)).toBe(`/o/${stem}-${d.rulingHash}.json`)
    expect(recordPath('/o', d.ruling, `0x${'cd'.repeat(32)}`)).not.toBe(recordPath('/o', d.ruling, d.rulingHash))
    expect(proposedPath('/o', d.ruling)).toBe(`/o/${stem}.json`)
  })
})

describe('verifySaved', () => {
  it('passes the file the CLI writes, and names the tampered part', () => {
    const saved = { rulingHash: d.rulingHash, ruling: d.ruling, input }
    expect(verifySaved(saved).ok).toBe(true)
    const edited = structuredClone(saved)
    edited.input.evidence[1]!.statement = 'I never touched the window.'
    const r = verifySaved(edited)
    expect(r.ok).toBe(false)
    expect(r.lines.join('\n')).toMatch(/INPUT MISMATCH/)
    const reruled = structuredClone(saved)
    reruled.ruling.tenantBps = 0
    expect(verifySaved(reruled).lines.join('\n')).toMatch(/rulingHash .*MISMATCH: saved/)
    expect(verifySaved(null).ok).toBe(false)
  })
})

describe('verifyOnchain', () => {
  it('matches AIArbiter.getRuling(leaseId) on the ruling arbiter', async () => {
    const { client, calls } = chain({ status: STATUS.PROPOSED })
    const r = await verifyOnchain(client, d.ruling, d.rulingHash)
    expect(r).toMatchObject({ ok: true })
    expect(r.lines[0]).toMatch(/rulingHash matches \(status PROPOSED, tenantBps 7500\)/)
    expect(calls[0]).toMatchObject({ address: d.ruling.arbiter, functionName: 'getRuling', args: [BigInt(input.lease.leaseId)] })
  })

  it('fails when the chain holds another ruling (e.g. the file of a later dry run)', async () => {
    const other = `0x${'ab'.repeat(32)}` as Hex
    const r = await verifyOnchain(chain({ status: STATUS.PROPOSED, rulingHash: other }).client, d.ruling, d.rulingHash)
    expect(r.ok).toBe(false)
    expect(r.lines[0]).toMatch(/MISMATCH: .*rulingHash is 0xabab/)
  })

  it('fails on a split or confidence that is not the ruling, unless the human ruled', async () => {
    expect((await verifyOnchain(chain({ status: STATUS.EXECUTED, tenantBps: 0 }).client, d.ruling, d.rulingHash)).ok).toBe(false)
    const human = await verifyOnchain(chain({ status: STATUS.HUMAN_RESOLVED, tenantBps: 5000 }).client, d.ruling, d.rulingHash)
    expect(human.ok).toBe(true)
    expect(human.lines[0]).toMatch(/set by the human/)
  })

  it('fails with no proposal on-chain, or on the wrong chain', async () => {
    expect((await verifyOnchain(chain({ status: STATUS.NONE }).client, d.ruling, d.rulingHash)).lines[0]).toMatch(/no proposal/)
    const wrong = await verifyOnchain(chain({ status: STATUS.PROPOSED }, 1).client, d.ruling, d.rulingHash)
    expect(wrong.ok).toBe(false)
    expect(wrong.lines[0]).toMatch(/chain 1, but the ruling is for chain 11155111/)
  })
})
