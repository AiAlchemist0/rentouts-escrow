import { isAddressEqual, type Address } from 'viem'

/** The AI judge's ENS name (ens/script/JudgeName.s.sol registers it to AIArbiter's agent). */
export const DEFAULT_JUDGE_ENS_NAME = 'judge.rentouts.eth'

/**
 * Whether to show the proposal as made by the judge's ENS name. Only when the name forward-resolves
 * (ENSv2 Universal Resolver) to the key AIArbiter lets propose: `agent` itself, or, when `agent` is the
 * EnsAgentRelay, the relay's current `judge()`. Anything missing (name not registered yet, lookup failed,
 * a mismatch) is false, and the panel shows the raw address instead.
 */
export function judgeNameVerified(p: {
  agent: Address | undefined
  resolved: Address | null | undefined
  relayJudge?: Address | null
}): boolean {
  const { agent, resolved, relayJudge } = p
  if (!agent || !resolved) return false
  if (isAddressEqual(resolved, agent)) return true
  return !!relayJudge && isAddressEqual(resolved, relayJudge)
}
