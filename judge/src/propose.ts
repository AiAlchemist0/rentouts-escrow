import { readFileSync } from 'node:fs'
import { createWalletClient, http, isAddressEqual, parseEventLogs, type PublicClient } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { sepolia } from 'viem/chains'
import { aiArbiterAbi } from './abi.ts'
import type { Decision } from './decide.ts'
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

  const summary = truncateUtf8(ruling.answers?.rationale ?? '', MAX_SUMMARY_BYTES)
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
