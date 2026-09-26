import { describe, expect, it } from 'vitest'
import {
  DEFAULT_JUDGE_ENS_NAME,
  JudgeEnsError,
  judgeEnsNameFromEnv,
  judgeRelayFromEnv,
  previewJudgeEns,
  proposalTarget,
  resolveJudgeName,
  type EnsReader,
} from '../src/ens.ts'
import { SEPOLIA } from '../src/chain.ts'
import type { Address } from '../src/types.ts'

const JUDGE = '0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA' as Address
const OTHER = '0x798b01Cef62b889943Ce1D3C5011a755B297e486' as Address
const ARBITER = '0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5' as Address
const RELAY = '0x1111111111111111111111111111111111111111' as Address

/** A mock Universal Resolver (name -> address, or throws like an unregistered name) and relay.judge(). */
function mockClient(opts: { names?: Record<string, Address | null>; relayJudge?: Address; resolveError?: string } = {}) {
  const calls: { name?: string; universalResolverAddress?: string; functionName?: string }[] = []
  const client = {
    getEnsAddress: async (args: { name: string; universalResolverAddress?: string }) => {
      calls.push(args)
      if (opts.resolveError) throw new Error(opts.resolveError)
      return opts.names?.[args.name] ?? null
    },
    readContract: async (args: { functionName: string }) => {
      calls.push(args)
      return opts.relayJudge ?? '0x0000000000000000000000000000000000000000'
    },
  } as unknown as EnsReader
  return { client, calls }
}

const live = { [DEFAULT_JUDGE_ENS_NAME]: JUDGE }

describe('config', () => {
  it('JUDGE_ENS_NAME defaults to judge.rentouts.eth, normalizes, and "off" disables the check', () => {
    expect(judgeEnsNameFromEnv({})).toBe('judge.rentouts.eth')
    expect(judgeEnsNameFromEnv({ JUDGE_ENS_NAME: '' })).toBe('judge.rentouts.eth')
    expect(judgeEnsNameFromEnv({ JUDGE_ENS_NAME: 'Judge2.RentOuts.eth' })).toBe('judge2.rentouts.eth')
    for (const off of ['off', 'OFF', 'none', 'false', '0']) expect(judgeEnsNameFromEnv({ JUDGE_ENS_NAME: off })).toBeNull()
  })

  it('JUDGE_RELAY is optional and must be an address', () => {
    expect(judgeRelayFromEnv({})).toBeNull()
    expect(judgeRelayFromEnv({ JUDGE_RELAY: RELAY.toLowerCase() })).toBe(RELAY)
    expect(() => judgeRelayFromEnv({ JUDGE_RELAY: 'judge.rentouts.eth' })).toThrow(JudgeEnsError)
  })
})

describe('resolveJudgeName', () => {
  it('asks the ENSv2 Universal Resolver', async () => {
    const { client, calls } = mockClient({ names: live })
    expect(await resolveJudgeName(client, 'judge.rentouts.eth')).toBe(JUDGE)
    expect(calls[0]).toMatchObject({ name: 'judge.rentouts.eth', universalResolverAddress: SEPOLIA.universalResolver })
  })

  it('an unregistered name (the UR reverts) has no address; a network failure is an error', async () => {
    expect(await resolveJudgeName(mockClient({ resolveError: 'The contract function "resolve" reverted. ResolverNotFound' }).client, 'judge.rentouts.eth')).toBeNull()
    await expect(resolveJudgeName(mockClient({ resolveError: 'fetch failed' }).client, 'judge.rentouts.eth')).rejects.toThrow(/cannot resolve/)
  })
})

describe('proposalTarget: the ENS gate before signing (no relay)', () => {
  const base = { signer: JUDGE, agent: JUDGE, arbiter: ARBITER, relay: null, ensName: DEFAULT_JUDGE_ENS_NAME }

  it('sends to AIArbiter when the name resolves to the signer and the signer is AIArbiter.agent()', async () => {
    const t = await proposalTarget(mockClient({ names: live }).client, base)
    expect(t).toMatchObject({ address: ARBITER, via: 'arbiter' })
    expect(t.lines.join('\n')).toMatch(/judge\.rentouts\.eth -> 0x4a44.* = signer = AIArbiter\.agent\(\) ✓/)
  })

  it('refuses when the name resolves to another address', async () => {
    const { client } = mockClient({ names: { [DEFAULT_JUDGE_ENS_NAME]: OTHER } })
    await expect(proposalTarget(client, base)).rejects.toThrow(/resolves to 0x798b.*not this key.*refusing to propose/)
  })

  it('refuses when the name does not resolve (not registered yet, or revoked)', async () => {
    await expect(proposalTarget(mockClient({ names: {} }).client, base)).rejects.toThrow(/does not resolve: refusing/)
    await expect(proposalTarget(mockClient({ resolveError: 'reverted: ResolverNotFound' }).client, base)).rejects.toThrow(JudgeEnsError)
  })

  it('refuses when the signer is not AIArbiter.agent(), even if the name matches the signer', async () => {
    const { client } = mockClient({ names: { [DEFAULT_JUDGE_ENS_NAME]: OTHER } })
    await expect(proposalTarget(client, { ...base, signer: OTHER })).rejects.toThrow(/AIArbiter's agent is 0x4a44/)
  })

  it('JUDGE_ENS_NAME=off: no ENS lookup, the agent check still applies', async () => {
    const { client, calls } = mockClient()
    const t = await proposalTarget(client, { ...base, ensName: null })
    expect(t.address).toBe(ARBITER)
    expect(t.lines.join('\n')).toMatch(/check off/)
    expect(calls).toHaveLength(0)
    await expect(proposalTarget(client, { ...base, ensName: null, signer: OTHER })).rejects.toThrow(/agent/)
  })
})

describe('proposalTarget: through the EnsAgentRelay (JUDGE_RELAY)', () => {
  const base = { signer: JUDGE, agent: RELAY, arbiter: ARBITER, relay: RELAY, ensName: DEFAULT_JUDGE_ENS_NAME }

  it('sends to the relay when AIArbiter.agent() is the relay, relay.judge() is the signer, and the name resolves to it', async () => {
    const { client, calls } = mockClient({ names: live, relayJudge: JUDGE })
    const t = await proposalTarget(client, base)
    expect(t).toMatchObject({ address: RELAY, via: 'relay' })
    expect(calls.some((c) => c.functionName === 'judge')).toBe(true)
    expect(t.lines.join('\n')).toMatch(/the relay's judge \(AIArbiter\.agent\(\) = relay 0x1111/)
  })

  it('refuses when the human has not switched the relay on', async () => {
    const { client } = mockClient({ names: live, relayJudge: JUDGE })
    await expect(proposalTarget(client, { ...base, agent: JUDGE })).rejects.toThrow(/has not switched the relay on/)
  })

  it("refuses when the relay's ENS judge is someone else (the chain would refuse too)", async () => {
    const { client } = mockClient({ names: live, relayJudge: OTHER })
    await expect(proposalTarget(client, base)).rejects.toThrow(/relay's ENS judge is 0x798b/)
  })

  it('refuses when the name no longer resolves to the signer', async () => {
    const { client } = mockClient({ names: { [DEFAULT_JUDGE_ENS_NAME]: OTHER }, relayJudge: JUDGE })
    await expect(proposalTarget(client, base)).rejects.toThrow(/refusing to propose/)
  })
})

describe('previewJudgeEns: the read-only line on every live run', () => {
  it('says whether the name is the key AIArbiter lets propose, and never throws', async () => {
    expect(await previewJudgeEns(mockClient({ names: live }).client, { ensName: DEFAULT_JUDGE_ENS_NAME, agent: JUDGE, relay: null })).toMatch(/= AIArbiter\.agent\(\) ✓/)
    expect(await previewJudgeEns(mockClient({ names: {} }).client, { ensName: DEFAULT_JUDGE_ENS_NAME, agent: JUDGE, relay: null })).toMatch(/does not resolve yet: --propose will refuse/)
    expect(await previewJudgeEns(mockClient({ names: { [DEFAULT_JUDGE_ENS_NAME]: OTHER } }).client, { ensName: DEFAULT_JUDGE_ENS_NAME, agent: JUDGE, relay: null })).toMatch(/but AIArbiter\.agent\(\) is 0x4a44.*will refuse/)
    expect(await previewJudgeEns(mockClient({ names: live, relayJudge: JUDGE }).client, { ensName: DEFAULT_JUDGE_ENS_NAME, agent: RELAY, relay: RELAY })).toMatch(/the relay's judge ✓/)
    expect(await previewJudgeEns(mockClient({ resolveError: 'fetch failed' }).client, { ensName: DEFAULT_JUDGE_ENS_NAME, agent: JUDGE, relay: null })).toMatch(/could not check/)
    expect(await previewJudgeEns(mockClient().client, { ensName: null, agent: JUDGE, relay: null })).toMatch(/check off/)
  })
})
