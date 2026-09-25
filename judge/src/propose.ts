import { readFileSync } from 'node:fs'
import { createWalletClient, http, isAddressEqual, parseEventLogs, type PublicClient } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { sepolia } from 'viem/chains'
import { aiArbiterAbi } from './abi.ts'
import type { ArbiterState } from './chain.ts'
import type { Decision, Ruling } from './decide.ts'
import { decryptKeystore, keystorePath, promptHidden, KeystoreError } from './keystore.ts'
import type { Address, Hex } from './types.ts'

/** AIArbiter.MAX_SUMMARY_BYTES */
export const MAX_SUMMARY_BYTES = 1000

/** Cuts `text` to at most `maxBytes` UTF-8 bytes without splitting a character. */
export function truncateUtf8(text: string, maxBytes: number): string {
  const enc = new TextEncoder()
  if (enc.encode(text).length <= maxBytes) return text
  let out = ''
  let size = 0
  for (const ch of text) {
    const n = enc.encode(ch).length
    if (size + n > maxBytes - 3) break
    out += ch
    size += n
  }
  return `${out}...`
}

/** Starts the on-chain summary of a proposal made by the mock provider (keyword matching, not a judge). */
export const MOCK_SUMMARY_PREFIX = '[mock judge, keyword matching] '

/**
 * The `summary` sent with AIArbiter.propose: the rationale, cut to MAX_SUMMARY_BYTES. A mock ruling
 * is labelled, because the Proposed event carries no provider (only the ruling file and its hash do).
 */
export function proposalSummary(ruling: Pick<Ruling, 'judge' | 'answers'>): string {
  const prefix = ruling.judge.provider === 'mock' ? MOCK_SUMMARY_PREFIX : ''
  return prefix + truncateUtf8(ruling.answers?.rationale ?? '', MAX_SUMMARY_BYTES - new TextEncoder().encode(prefix).length)
}

/** Exit code when the judge abstains but an earlier AI proposal on the lease still stands. */
export const EXIT_STANDING_PROPOSAL = 3

export type ProposalPlan = { send: true; lines: string[] } | { send: false; exitCode: number; lines: string[] }

/**
 * What the CLI does once the judge has decided, given the lease's current AIArbiter ruling.
 *
 * The agent can only propose: it cannot withdraw an open proposal. So when the judge now abstains
 * (e.g. after new evidence) while an earlier proposal is still PROPOSED, that proposal still
 * executes at its deadline unless a party appeals or the human arbiter calls resolveByHuman. The
 * plan says so (with or without --propose), and with --propose exits EXIT_STANDING_PROPOSAL instead
 * of reporting that "the human arbiter decides".
 *
 * Throws when a proposal can no longer be made: the lease was appealed, or the open proposal's
 * challenge window is over.
 */
export function planProposal(
  ruling: Pick<Ruling, 'decision'>,
  onchain: ArbiterState['ruling'] | null,
  opts: { propose: boolean; now: bigint },
): ProposalPlan {
  const lines: string[] = []
  const open = onchain?.status === 'PROPOSED'
  const standing = ruling.decision === 'abstain' && open
  if (standing) {
    const over = opts.now >= onchain.deadline
    const at = new Date(Number(onchain.deadline) * 1000).toISOString()
    lines.push(
      `  WARNING       an earlier AI proposal is still open: tenantBps ${onchain.tenantBps} (${(onchain.tenantBps / 100).toFixed(2)}% to the tenant), rulingHash ${onchain.rulingHash}`,
      over
        ? '                its window is over: ANYONE can execute it now, unless the human arbiter calls resolveByHuman first'
        : `                it executes at ${at} unless a party appeals before then or the human arbiter calls resolveByHuman`,
    )
  }
  if (!opts.propose) return { send: false, exitCode: 0, lines }

  if (ruling.decision !== 'propose') {
    if (standing) {
      lines.push('  --propose     not sent: the judge abstained, and the agent cannot withdraw the open proposal. Tell the human arbiter.')
      return { send: false, exitCode: EXIT_STANDING_PROPOSAL, lines }
    }
    lines.push(
      onchain?.status === 'APPEALED'
        ? '  --propose     not sent: the judge abstained; the lease is appealed, the human arbiter decides'
        : '  --propose     not sent: the judge abstained, the human arbiter decides',
    )
    return { send: false, exitCode: 0, lines }
  }
  if (!onchain) throw new Error('--propose needs the lease read from the chain')
  if (onchain.status === 'APPEALED') throw new Error('the lease was appealed: only the human arbiter can rule now')
  if (open && opts.now >= onchain.deadline) {
    throw new Error("the open proposal's challenge window is over: it can only be executed or overridden by the human")
  }
  if (open) lines.push('  note          this replaces the open proposal and restarts its challenge window')
  return { send: true, lines }
}

export interface ProposeOptions {
  publicClient: PublicClient
  rpcUrl: string
  arbiter: Address
  leaseId: bigint
  decision: Decision
  expectedAgent: Address
  keystore: string
  /** Directory holding the keystore (JUDGE_KEYSTORE_DIR); default ~/.foundry/keystores. */
  keystoreDir?: string
  /** From JUDGE_KEYSTORE_PASSWORD; otherwise an interactive hidden prompt. */
  password?: string
  log: (line: string) => void
}

/**
 * Sends AIArbiter.propose(leaseId, tenantBps, rulingHash, confidenceBps, summary), signed with the
 * judge's Foundry keystore. Simulates first so a revert (not the agent, window over, appealed...)
 * is reported before anything is sent.
 */
export async function sendProposal(opts: ProposeOptions): Promise<{ txHash: Hex; deadline: bigint | null }> {
  const { ruling, rulingHash } = opts.decision
  if (ruling.decision !== 'propose' || ruling.tenantBps === null) throw new Error('nothing to propose: the judge abstained')

  const file = keystorePath(opts.keystore, opts.keystoreDir)
  let json: unknown
  try {
    json = JSON.parse(readFileSync(file, 'utf8'))
  } catch {
    throw new KeystoreError(`cannot read keystore ${file} (create it: cast wallet import ${opts.keystore} --interactive)`)
  }
  const password = opts.password ?? (await promptHidden(`Password for keystore "${opts.keystore}": `))
  const account = privateKeyToAccount(decryptKeystore(json, password))
  if (!isAddressEqual(account.address, opts.expectedAgent)) {
    throw new Error(`keystore "${opts.keystore}" is ${account.address}, but AIArbiter's agent is ${opts.expectedAgent}`)
  }

  const summary = proposalSummary(ruling)
  const { request } = await opts.publicClient.simulateContract({
    account,
    address: opts.arbiter,
    abi: aiArbiterAbi,
    functionName: 'propose',
    args: [opts.leaseId, ruling.tenantBps, rulingHash, ruling.confidenceBps, summary],
  })
  const wallet = createWalletClient({ account, chain: sepolia, transport: http(opts.rpcUrl) })
  const txHash = await wallet.writeContract(request)
  opts.log(`  sent          ${txHash} (waiting for the receipt)`)
  const receipt = await opts.publicClient.waitForTransactionReceipt({ hash: txHash })
  if (receipt.status !== 'success') throw new Error(`propose reverted in ${txHash}`)
  const [proposed] = parseEventLogs({ abi: aiArbiterAbi, eventName: 'Proposed', logs: receipt.logs })
  return { txHash, deadline: proposed ? (proposed.args as { deadline: bigint }).deadline : null }
}
