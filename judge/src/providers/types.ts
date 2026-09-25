import type { DisputeInput, JudgeAnswers } from '../types.ts'

/**
 * A judge model. Every provider answers the same typed checklist (JudgeAnswersSchema) for the same
 * DisputeInput; nothing else about the ruling depends on which provider ran. To add a model,
 * implement this and register it in providers/index.ts.
 */
export interface JudgeProvider {
  readonly name: string
  readonly model: string
  judge(input: DisputeInput): Promise<ProviderResult>
}

export interface ProviderResult {
  answers: JudgeAnswers
  /** Model id as reported by the API (or the configured one). */
  model: string
  /** 1, or 2 if the first reply failed validation and the model was asked again. */
  attempts: number
  notes: string[]
}

/** The model's reply was still invalid after the retry. */
export class JudgeOutputError extends Error {
  name = 'JudgeOutputError'
}
