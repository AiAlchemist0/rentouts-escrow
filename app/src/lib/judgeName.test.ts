import { describe, expect, it } from 'vitest'
import { judgeNameVerified } from './judgeName'

const JUDGE = '0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA'
const OTHER = '0x798b01Cef62b889943Ce1D3C5011a755B297e486'
const RELAY = '0x1111111111111111111111111111111111111111'

describe('judgeNameVerified', () => {
  it('true only when the name resolves to AIArbiter.agent()', () => {
    expect(judgeNameVerified({ agent: JUDGE, resolved: JUDGE })).toBe(true)
    expect(judgeNameVerified({ agent: JUDGE, resolved: JUDGE.toLowerCase() as `0x${string}` })).toBe(true)
    expect(judgeNameVerified({ agent: JUDGE, resolved: OTHER })).toBe(false)
  })

  it('degrades to false before the name is live or when the lookup failed', () => {
    expect(judgeNameVerified({ agent: JUDGE, resolved: null })).toBe(false)
    expect(judgeNameVerified({ agent: JUDGE, resolved: undefined })).toBe(false)
    expect(judgeNameVerified({ agent: undefined, resolved: JUDGE })).toBe(false)
  })

  it("with the EnsAgentRelay as agent: true when the name resolves to the relay's judge", () => {
    expect(judgeNameVerified({ agent: RELAY, resolved: JUDGE, relayJudge: JUDGE })).toBe(true)
    expect(judgeNameVerified({ agent: RELAY, resolved: JUDGE, relayJudge: OTHER })).toBe(false)
    expect(judgeNameVerified({ agent: RELAY, resolved: JUDGE, relayJudge: null })).toBe(false)
  })
})
