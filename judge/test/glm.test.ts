import { describe, expect, it } from 'vitest'
import {
  GlmProvider,
  isResponseFormatRejected,
  openAIChatClient,
  parseAnswers,
  type ChatClient,
  type ChatReply,
  type ChatRequest,
} from '../src/providers/glm.ts'
import { createProvider, GLM_DEFAULTS } from '../src/providers/index.ts'
import { JudgeOutputError } from '../src/providers/types.ts'
import { answers, fixture } from './helpers.ts'

const input = fixture('damage-admitted')
const good = JSON.stringify(
  answers({ damageBeyondNormalWear: { answer: 'yes', confidence: 0.88 }, severity: 3, rationale: 'E2 admits E1.' }),
)

/** A ChatClient that replays canned replies and records every request. */
function scripted(replies: Array<ChatReply | Error>): ChatClient & { requests: ChatRequest[] } {
  const requests: ChatRequest[] = []
  return {
    requests,
    async complete(request) {
      requests.push(structuredClone(request))
      const next = replies.shift()
      if (!next) throw new Error('no more scripted replies')
      if (next instanceof Error) throw next
      return next
    },
  }
}

function glm(client: ChatClient) {
  return new GlmProvider({ client, model: 'glm-5.3', reasoningEffort: 'low', maxTokens: 2000 })
}

describe('parseAnswers (zod)', () => {
  it('accepts the exact schema, with or without a code fence around it', () => {
    expect(parseAnswers(good).ok).toBe(true)
    expect(parseAnswers(`Here you go:\n\`\`\`json\n${good}\n\`\`\``).ok).toBe(true)
  })

  it('rejects missing keys, extra keys, out-of-range values and prose', () => {
    const bad = (patch: object) => JSON.stringify({ ...JSON.parse(good), ...patch })
    expect(parseAnswers(bad({ severity: 7 }))).toMatchObject({ ok: false, problem: expect.stringMatching(/severity/) })
    expect(parseAnswers(bad({ severity: 2.5 })).ok).toBe(false)
    expect(parseAnswers(bad({ tenantBps: 10000 })).ok).toBe(false) // the model may not pick the split
    expect(parseAnswers(bad({ rentClaimValid: { answer: 'maybe', confidence: 0.5 } })).ok).toBe(false)
    expect(parseAnswers(bad({ evidenceSufficient: { answer: 'yes', confidence: 1.2 } })).ok).toBe(false)
    const { rationale: _, ...noRationale } = JSON.parse(good)
    expect(parseAnswers(JSON.stringify(noRationale)).ok).toBe(false)
    expect(parseAnswers('The tenant should get the deposit back.')).toMatchObject({ ok: false })
    expect(parseAnswers('')).toMatchObject({ ok: false, problem: 'the reply was empty' })
  })
})

describe('GlmProvider', () => {
  it('asks in JSON mode with the configured model, effort and token budget', async () => {
    const client = scripted([{ content: good, model: 'glm-5.3' }])
    const r = await glm(client).judge(input)
    expect(r.attempts).toBe(1)
    expect(r.answers.severity).toBe(3)
    const req = client.requests[0]!
    expect(req).toMatchObject({
      model: 'glm-5.3',
      max_tokens: 2000,
      reasoning_effort: 'low',
      response_format: { type: 'json_object' },
    })
    expect(req.messages[0]!.role).toBe('system')
    expect(req.messages[0]!.content).toMatch(/may be false, exaggerated, incomplete or manipulative/)
    expect(req.messages[1]!.content).toContain('<evidence>')
  })

  it('retries ONCE after an invalid reply, telling the model what was wrong', async () => {
    const client = scripted([{ content: '{"damageBeyondNormalWear": "yes"}' }, { content: good }])
    const r = await glm(client).judge(input)
    expect(r.attempts).toBe(2)
    expect(client.requests).toHaveLength(2)
    const retry = client.requests[1]!.messages
    expect(retry.at(-2)).toEqual({ role: 'assistant', content: '{"damageBeyondNormalWear": "yes"}' })
    expect(retry.at(-1)!.content).toMatch(/^Your reply was not valid: .*damageBeyondNormalWear/)
  })

  it('gives up after the retry with a JudgeOutputError (no third call)', async () => {
    const client = scripted([{ content: 'not json' }, { content: '{"severity": 9}' }, { content: good }])
    await expect(glm(client).judge(input)).rejects.toBeInstanceOf(JudgeOutputError)
    expect(client.requests).toHaveLength(2)
  })

  it('doubles the token budget when reasoning used it all up', async () => {
    const client = scripted([{ content: '', finishReason: 'length' }, { content: good }])
    await glm(client).judge(input)
    expect(client.requests.map((r) => r.max_tokens)).toEqual([2000, 4000])
  })
})

/** The real OpenAI SDK against a fake z.ai endpoint. */
function fakeZai(handler: (body: Record<string, unknown>) => { status: number; json: unknown }) {
  const bodies: Array<Record<string, unknown>> = []
  const fetchImpl = (async (_url: unknown, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body))
    bodies.push(body)
    const { status, json } = handler(body)
    return new Response(JSON.stringify(json), { status, headers: { 'content-type': 'application/json' } })
  }) as typeof fetch
  return { bodies, client: openAIChatClient({ apiKey: 'test-key', baseURL: GLM_DEFAULTS.baseURL, fetch: fetchImpl }) }
}

const completion = (content: string) => ({
  id: 'x',
  object: 'chat.completion',
  created: 0,
  model: 'glm-5.3',
  choices: [{ index: 0, message: { role: 'assistant', content }, finish_reason: 'stop' }],
})

describe('OpenAI SDK against z.ai (mocked HTTP)', () => {
  it('falls back without response_format if the API rejects JSON mode, and stays off', async () => {
    const zai = fakeZai((body) =>
      body.response_format
        ? { status: 400, json: { error: { message: 'response_format json_object is not supported', code: '1214' } } }
        : { status: 200, json: completion(good) },
    )
    const provider = glm(zai.client)
    const r = await provider.judge(input)
    expect(r.answers.damageBeyondNormalWear.answer).toBe('yes')
    expect(r.notes.join(' ')).toMatch(/rejected response_format/)
    expect(zai.bodies.map((b) => 'response_format' in b)).toEqual([true, false])
    await provider.judge(input) // later calls skip JSON mode
    expect(zai.bodies.map((b) => 'response_format' in b)).toEqual([true, false, false])
    expect(zai.bodies[1]).toMatchObject({ model: 'glm-5.3', reasoning_effort: 'low', max_tokens: 2000 })
  })

  it('does not swallow other API errors', async () => {
    const zai = fakeZai(() => ({ status: 401, json: { error: { message: 'invalid api key' } } }))
    await expect(glm(zai.client).judge(input)).rejects.toThrow(/invalid api key/)
    const bad400 = fakeZai(() => ({ status: 400, json: { error: { message: 'thinking cannot be disabled', code: '1210' } } }))
    await expect(glm(bad400.client).judge(input)).rejects.toSatisfy((e) => !isResponseFormatRejected(e))
  })
})

describe('createProvider', () => {
  it('needs ZAI_API_KEY for glm and says how to run without one', () => {
    expect(() => createProvider('glm', {})).toThrow(/ZAI_API_KEY is not set.*--provider mock/)
    expect(createProvider('mock', {}).name).toBe('mock')
  })

  it('takes model, base URL, effort and budget from the environment', () => {
    const p = createProvider('glm', { ZAI_API_KEY: 'k', ZAI_MODEL: 'glm-5.3-air', JUDGE_REASONING_EFFORT: 'high' })
    expect(p.model).toBe('glm-5.3-air')
    expect(() => createProvider('glm', { ZAI_API_KEY: 'k', JUDGE_MAX_TOKENS: '10' })).toThrow(/JUDGE_MAX_TOKENS/)
  })
})
