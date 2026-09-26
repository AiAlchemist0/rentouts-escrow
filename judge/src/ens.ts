import { getAddress, isAddress, isAddressEqual, type PublicClient } from 'viem'
import { normalize } from 'viem/ens'
import { SEPOLIA } from './chain.ts'
import type { Address } from './types.ts'

/**
 * The judge's own ENS identity. Before a proposal is sent, the judge resolves its name through the ENSv2
 * Universal Resolver and refuses to send unless the name is the key that signs AND the key AIArbiter lets
 * propose. With JUDGE_RELAY (src/EnsAgentRelay.sol as AIArbiter's agent) the chain enforces the same rule.
 */
export const DEFAULT_JUDGE_ENS_NAME = 'judge.rentouts.eth'
const OFF = new Set(['off', 'none', 'false', '0', 'disabled'])

/** src/EnsAgentRelay.sol: the views the judge reads and propose(), same signature as AIArbiter.propose. */
export const ensAgentRelayAbi = [
  { type: 'function', name: 'judge', stateMutability: 'view', inputs: [], outputs: [{ name: 'holder', type: 'address' }] },
  { type: 'function', name: 'name', stateMutability: 'view', inputs: [], outputs: [{ name: '', type: 'string' }] },
  { type: 'function', name: 'arbiter', stateMutability: 'view', inputs: [], outputs: [{ name: '', type: 'address' }] },
  {
    type: 'function',
    name: 'propose',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'leaseId', type: 'uint256' },
      { name: 'tenantBps', type: 'uint16' },
      { name: 'rulingHash', type: 'bytes32' },
      { name: 'confidenceBps', type: 'uint16' },
      { name: 'summary', type: 'string' },
    ],
    outputs: [],
  },
  { type: 'error', name: 'NotEnsJudge', inputs: [{ name: 'caller', type: 'address' }, { name: 'holder', type: 'address' }] },
  { type: 'error', name: 'EnsNameNotLive', inputs: [{ name: 'caller', type: 'address' }, { name: 'registryOwner', type: 'address' }] },
  { type: 'error', name: 'PartyCannotArbitrate', inputs: [{ name: 'leaseId', type: 'uint256' }, { name: 'judge', type: 'address' }] },
] as const

export class JudgeEnsError extends Error {
  name = 'JudgeEnsError'
}

/** JUDGE_ENS_NAME: default judge.rentouts.eth; "off" (or none / false / 0) disables the ENS check, e.g. for local mock runs. */
export function judgeEnsNameFromEnv(env: NodeJS.ProcessEnv): string | null {
  const raw = env.JUDGE_ENS_NAME?.trim()
  if (raw === undefined || raw === '') return DEFAULT_JUDGE_ENS_NAME
  if (OFF.has(raw.toLowerCase())) return null
  return normalize(raw)
}

/** JUDGE_RELAY: the EnsAgentRelay to send proposals through, or null to call AIArbiter directly. */
export function judgeRelayFromEnv(env: NodeJS.ProcessEnv): Address | null {
  const raw = env.JUDGE_RELAY?.trim()
  if (!raw) return null
  if (!isAddress(raw, { strict: false })) throw new JudgeEnsError(`JUDGE_RELAY is not an address: ${raw}`)
  return getAddress(raw)
}

/** What the ENS check reads: the name's address (Universal Resolver) and, with a relay, relay.judge(). */
export type EnsReader = Pick<PublicClient, 'getEnsAddress' | 'readContract'>

/** Forward resolution through the ENSv2 Universal Resolver; null when the name has no address (or no resolver). */
export async function resolveJudgeName(client: EnsReader, name: string): Promise<Address | null> {
  try {
    const a = await client.getEnsAddress({ name: normalize(name), universalResolverAddress: SEPOLIA.universalResolver })
    return a ? getAddress(a) : null
  } catch (err) {
    const msg = (err as Error).message?.split('\n')[0] ?? String(err)
    // An unregistered name makes the Universal Resolver revert (ResolverNotFound and friends): no address.
    if (/ResolverNotFound|ResolverNotContract|UnsupportedResolverProfile|reverted/i.test(msg)) return null
    throw new JudgeEnsError(`cannot resolve ${name}: ${msg}`)
  }
}

export interface ProposalTarget {
  /** Where propose() goes: AIArbiter, or the relay. */
  address: Address
  via: 'arbiter' | 'relay'
  /** Report lines ("judge ENS ..."). */
  lines: string[]
}

export interface TargetOptions {
  signer: Address
  /** AIArbiter.agent(), read on chain. */
  agent: Address
  arbiter: Address
  relay: Address | null
  /** null: the ENS check is off (JUDGE_ENS_NAME=off). */
  ensName: string | null
}

const same = (a: Address | null | undefined, b: Address | null | undefined) => !!a && !!b && isAddressEqual(a, b)

/**
 * The last check before signing. Throws JudgeEnsError unless:
 * - without a relay: the signer is AIArbiter.agent();
 * - with JUDGE_RELAY: AIArbiter.agent() is that relay and relay.judge() (the name's holder on chain) is the signer;
 * - and, unless the check is off: `ensName` forward-resolves to the signer, which is (per the above) the key
 *   AIArbiter.agent() lets propose. So a proposal only leaves this machine signed by the key its name names.
 */
export async function proposalTarget(client: EnsReader, o: TargetOptions): Promise<ProposalTarget> {
  const lines: string[] = []
  if (o.relay) {
    if (!same(o.agent, o.relay)) {
      throw new JudgeEnsError(`JUDGE_RELAY is ${o.relay}, but AIArbiter.agent() is ${o.agent}: the human has not switched the relay on (setAgent)`)
    }
    const relayJudge = getAddress(
      (await client.readContract({ address: o.relay, abi: ensAgentRelayAbi, functionName: 'judge' })) as Address,
    )
    if (!same(relayJudge, o.signer)) {
      throw new JudgeEnsError(`the relay's ENS judge is ${relayJudge}, not this key ${o.signer}: the relay would refuse the proposal`)
    }
  } else if (!same(o.signer, o.agent)) {
    throw new JudgeEnsError(`this key is ${o.signer}, but AIArbiter's agent is ${o.agent}`)
  }

  if (o.ensName === null) {
    lines.push('  judge ENS     check off (JUDGE_ENS_NAME=off)')
  } else {
    const resolved = await resolveJudgeName(client, o.ensName)
    if (!resolved) throw new JudgeEnsError(`${o.ensName} does not resolve: refusing to propose (register it, or JUDGE_ENS_NAME=off for a local run)`)
    if (!same(resolved, o.signer)) {
      throw new JudgeEnsError(`${o.ensName} resolves to ${resolved}, not this key ${o.signer}: refusing to propose`)
    }
    lines.push(`  judge ENS     ${o.ensName} -> ${resolved} = signer = ${o.relay ? `the relay's judge (AIArbiter.agent() = relay ${o.relay})` : 'AIArbiter.agent()'} ✓`)
  }
  return o.relay ? { address: o.relay, via: 'relay', lines } : { address: o.arbiter, via: 'arbiter', lines }
}

/**
 * A read-only preview for every live run (no key needed): does `ensName` resolve to the key AIArbiter lets
 * propose (the agent, or the relay's judge)? Never throws; returns one report line.
 */
export async function previewJudgeEns(client: EnsReader, o: { ensName: string | null; agent: Address; relay: Address | null }): Promise<string> {
  if (o.ensName === null) return '  judge ENS     check off (JUDGE_ENS_NAME=off)'
  try {
    const resolved = await resolveJudgeName(client, o.ensName)
    if (!resolved) return `  judge ENS     ${o.ensName} does not resolve yet: --propose will refuse`
    let expected = o.agent
    let what = 'AIArbiter.agent()'
    if (o.relay && same(o.agent, o.relay)) {
      expected = getAddress((await client.readContract({ address: o.relay, abi: ensAgentRelayAbi, functionName: 'judge' })) as Address)
      what = `the relay's judge`
    }
    return same(resolved, expected)
      ? `  judge ENS     ${o.ensName} -> ${resolved} = ${what} ✓`
      : `  judge ENS     ${o.ensName} -> ${resolved}, but ${what} is ${expected}: --propose will refuse`
  } catch (err) {
    return `  judge ENS     could not check ${o.ensName}: ${(err as Error).message.split('\n')[0]}`
  }
}
