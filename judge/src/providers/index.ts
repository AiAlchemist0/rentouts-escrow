import { GlmProvider, openAIChatClient } from './glm.ts'
import { MockProvider } from './mock.ts'
import type { JudgeProvider } from './types.ts'

export type ProviderName = 'glm' | 'mock'
export const PROVIDERS: readonly ProviderName[] = ['glm', 'mock']

export const GLM_DEFAULTS = {
  baseURL: 'https://api.z.ai/api/paas/v4/',
  model: 'glm-5.3',
  reasoningEffort: 'low',
  maxTokens: 2000,
} as const

export function isProviderName(value: string): value is ProviderName {
  return (PROVIDERS as readonly string[]).includes(value)
}

/**
 * Builds a provider from the environment. glm: ZAI_API_KEY (required), ZAI_BASE_URL, ZAI_MODEL,
 * JUDGE_REASONING_EFFORT (low | high | max), JUDGE_MAX_TOKENS. The key is only handed to the SDK,
 * never logged.
 */
export function createProvider(
  name: ProviderName,
  env: NodeJS.ProcessEnv,
  log?: (line: string) => void,
): JudgeProvider {
  if (name === 'mock') return new MockProvider()
  const apiKey = env.ZAI_API_KEY?.trim()
  if (!apiKey) {
    throw new Error('ZAI_API_KEY is not set (run via ./run.sh to load the secrets file), or use --provider mock')
  }
  const maxTokens = Number(env.JUDGE_MAX_TOKENS || GLM_DEFAULTS.maxTokens)
  if (!Number.isInteger(maxTokens) || maxTokens < 256) throw new Error('JUDGE_MAX_TOKENS must be an integer >= 256')
  return new GlmProvider({
    client: openAIChatClient({ apiKey, baseURL: env.ZAI_BASE_URL || GLM_DEFAULTS.baseURL }),
    model: env.ZAI_MODEL || GLM_DEFAULTS.model,
    reasoningEffort: env.JUDGE_REASONING_EFFORT || GLM_DEFAULTS.reasoningEffort,
    maxTokens,
    log,
  })
}

export type { JudgeProvider, ProviderResult } from './types.ts'
