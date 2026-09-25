import OpenAI, { APIError } from 'openai'
import { SYSTEM_PROMPT, buildUserPrompt } from '../prompt.ts'
import { JudgeAnswersSchema, type DisputeInput, type JudgeAnswers } from '../types.ts'
import { JudgeOutputError, type JudgeProvider, type ProviderResult } from './types.ts'

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant'
  content: string
}

export interface ChatRequest {
  model: string
  messages: ChatMessage[]
  max_tokens: number
  reasoning_effort?: string
  response_format?: { type: 'json_object' }
}

export interface ChatReply {
  content: string
  model?: string
  finishReason?: string | null
}

/** The one call the judge makes. Wraps the OpenAI SDK so tests can inject a fake. */
export interface ChatClient {
  complete(request: ChatRequest): Promise<ChatReply>
}

/** An OpenAI-compatible client (z.ai GLM by default) behind the ChatClient seam. */
export function openAIChatClient(opts: {
  apiKey: string
  baseURL: string
  timeoutMs?: number
  fetch?: typeof fetch
}): ChatClient {
  const client = new OpenAI({
    apiKey: opts.apiKey,
    baseURL: opts.baseURL,
    timeout: opts.timeoutMs ?? 90_000,
    maxRetries: 1, // transport-level (429 / 5xx / network); output validation is retried below
    ...(opts.fetch ? { fetch: opts.fetch } : {}),
  })
  return {
    async complete(request) {
      // z.ai takes reasoning_effort "low" | "high" | "max" and json_object mode; both are
      // OpenAI-shaped, so the SDK passes them through as-is.
      const res = await client.chat.completions.create(
        request as unknown as OpenAI.Chat.ChatCompletionCreateParamsNonStreaming,
      )
      const choice = res.choices[0]
      return { content: choice?.message?.content ?? '', model: res.model, finishReason: choice?.finish_reason }
    },
  }
}

export interface GlmOptions {
  client: ChatClient
  model: string
  /** z.ai: "low" (fast, the demo default) | "high" | "max". Reasoning cannot be switched off. */
  reasoningEffort: string
  /** Reasoning tokens count against this; below ~2000 the answer can come back empty. */
  maxTokens: number
  log?: (line: string) => void
}

type Parsed = { ok: true; value: JudgeAnswers } | { ok: false; problem: string }

/** Pulls the JSON object out of a reply (tolerates code fences / prose around it) and validates it. */
export function parseAnswers(content: string): Parsed {
  const text = content.trim()
  if (!text) return { ok: false, problem: 'the reply was empty' }
  const start = text.indexOf('{')
  const end = text.lastIndexOf('}')
  if (start < 0 || end <= start) return { ok: false, problem: 'no JSON object found in the reply' }
  let json: unknown
  try {
    json = JSON.parse(text.slice(start, end + 1))
  } catch (err) {
    return { ok: false, problem: `the JSON did not parse (${(err as Error).message})` }
  }
  const result = JudgeAnswersSchema.safeParse(json)
  if (result.success) return { ok: true, value: result.data }
  const problem = result.error.issues
    .slice(0, 6)
    .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
    .join('; ')
  return { ok: false, problem }
}

/** True when the API refused the request because of response_format (JSON mode unsupported). */
export function isResponseFormatRejected(err: unknown): boolean {
  if (!(err instanceof APIError)) return false
  if (err.status !== 400 && err.status !== 422) return false
  const text = `${err.message} ${err.param ?? ''} ${JSON.stringify(err.error ?? '')}`
  return /response_format|json_object|json mode/i.test(text)
}

/**
 * GLM (z.ai, OpenAI-compatible) judge. Asks for JSON mode; if the API rejects response_format it
 * falls back to plain text (the system prompt already demands a bare JSON object). The reply is
 * validated with zod; an invalid reply gets ONE retry that tells the model what was wrong.
 */
export class GlmProvider implements JudgeProvider {
  readonly name = 'glm'
  readonly model: string
  private readonly opts: GlmOptions
  private jsonMode = true

  constructor(opts: GlmOptions) {
    this.opts = opts
    this.model = opts.model
  }

  async judge(input: DisputeInput): Promise<ProviderResult> {
    const notes: string[] = []
    const messages: ChatMessage[] = [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: buildUserPrompt(input) },
    ]
    let maxTokens = this.opts.maxTokens
    let problem = ''
    for (let attempt = 1; attempt <= 2; attempt++) {
      const reply = await this.call(messages, maxTokens, notes)
      const parsed = parseAnswers(reply.content)
      if (parsed.ok) return { answers: parsed.value, model: reply.model || this.model, attempts: attempt, notes }

      problem = parsed.problem
      notes.push(`attempt ${attempt}: invalid reply (${problem})`)
      this.opts.log?.(`judge: model reply invalid (${problem})${attempt === 1 ? ', retrying once' : ''}`)
      // Reasoning tokens ate the budget: give the retry more room.
      if (reply.finishReason === 'length' || !reply.content.trim()) maxTokens *= 2
      messages.push(
        { role: 'assistant', content: reply.content.trim() || '(empty reply)' },
        {
          role: 'user',
          content: `Your reply was not valid: ${problem}. Reply again with ONLY the JSON object, exactly the keys and value types given in the instructions.`,
        },
      )
    }
    throw new JudgeOutputError(`model reply still invalid after a retry: ${problem}`)
  }

  private async call(messages: ChatMessage[], maxTokens: number, notes: string[]): Promise<ChatReply> {
    const request: ChatRequest = {
      model: this.model,
      messages,
      max_tokens: maxTokens,
      reasoning_effort: this.opts.reasoningEffort,
    }
    if (this.jsonMode) {
      try {
        return await this.opts.client.complete({ ...request, response_format: { type: 'json_object' } })
      } catch (err) {
        if (!isResponseFormatRejected(err)) throw err
        this.jsonMode = false
        notes.push('the API rejected response_format: retried without JSON mode')
        this.opts.log?.('judge: API rejected response_format (JSON mode); retrying without it')
      }
    }
    return this.opts.client.complete(request)
  }
}
