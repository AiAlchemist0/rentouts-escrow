import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import type { PublicClient } from 'viem'
import { aiArbiterAbi } from './abi.ts'
import { canonicalHash } from './canonical.ts'
import { RULING_STATUS } from './chain.ts'
import type { Ruling } from './decide.ts'
import type { DisputeInput, Hex } from './types.ts'

/** What the CLI saves for every run: the ruling, its hash, the input it was made on, run metadata. */
export interface SavedRuling {
  rulingHash: Hex
  ruling: Ruling
  input: DisputeInput
  meta?: Record<string, unknown>
}

function leaseStem(ruling: Pick<Ruling, 'chainId' | 'arbiter' | 'leaseId'>): string {
  return `ruling-${ruling.chainId}-${ruling.arbiter.toLowerCase()}-${ruling.leaseId}`
}

/**
 * Where every run saves its ruling: `ruling-<chainId>-<arbiter>-<lease>-<rulingHash>.json`. The name
 * holds the hash, so a later run (a dry run, an abstention, a rerun that GLM answers differently)
 * never overwrites the preimage of a hash that may already be on-chain. Same name = same ruling.
 */
export function recordPath(outDir: string, ruling: Pick<Ruling, 'chainId' | 'arbiter' | 'leaseId'>, rulingHash: Hex): string {
  return join(outDir, `${leaseStem(ruling)}-${rulingHash.toLowerCase()}.json`)
}

/**
 * `ruling-<chainId>-<arbiter>-<lease>.json`: written only after AIArbiter.propose is confirmed, so it
 * always holds the ruling behind this machine's latest proposal for the lease.
 */
export function proposedPath(outDir: string, ruling: Pick<Ruling, 'chainId' | 'arbiter' | 'leaseId'>): string {
  return join(outDir, `${leaseStem(ruling)}.json`)
}

export function writeRecord(path: string, saved: SavedRuling): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, `${JSON.stringify(saved, null, 2)}\n`)
}

export interface Check {
  ok: boolean
  lines: string[]
}

/**
 * Offline checks of a saved ruling file. Both must hold, or the file does not show what was judged:
 *   - the ruling hashes to the saved `rulingHash`;
 *   - the saved input (lease facts and every statement) hashes to the ruling's `inputHash`.
 * A file that passes is internally consistent. Only `verifyOnchain` shows it is the ruling that was
 * proposed (anyone can recompute both hashes after editing a file).
 */
export function verifySaved(saved: unknown): Check {
  const s = (saved ?? {}) as Partial<SavedRuling>
  const missing = (['rulingHash', 'ruling', 'input'] as const).filter((k) => s[k] === undefined || s[k] === null)
  if (missing.length > 0) return { ok: false, lines: [`not a saved ruling: missing ${missing.join(', ')}`] }
  const { ruling, input } = s as SavedRuling

  const rulingHash = canonicalHash(ruling)
  const rulingOk = rulingHash === s.rulingHash
  const inputHash = canonicalHash(input)
  const inputOk = inputHash === ruling.inputHash
  return {
    ok: rulingOk && inputOk,
    lines: [
      `rulingHash ${rulingHash}${rulingOk ? '  (matches the saved hash)' : `  (MISMATCH: saved ${s.rulingHash})`}`,
      `inputHash  ${inputHash}${
        inputOk
          ? '  (matches ruling.inputHash: this is the evidence that was judged)'
          : `  (INPUT MISMATCH: the ruling was made on ${ruling.inputHash}; the saved lease facts or statements were changed)`
      }`,
    ],
  }
}

/**
 * Compares a saved ruling with AIArbiter.getRuling(leaseId) on its chain: the on-chain rulingHash
 * must be this ruling's hash, and while the AI's proposal stands (PROPOSED / APPEALED / EXECUTED)
 * its tenantBps and confidenceBps must be the ruling's. After a human ruling (HUMAN_RESOLVED) the
 * contract keeps the AI's last rulingHash, and tenantBps is the human's.
 */
export async function verifyOnchain(
  client: Pick<PublicClient, 'getChainId' | 'readContract'>,
  ruling: Ruling,
  rulingHash: Hex,
): Promise<Check> {
  const chainId = await client.getChainId()
  if (chainId !== ruling.chainId) {
    return { ok: false, lines: [`on-chain   the RPC is chain ${chainId}, but the ruling is for chain ${ruling.chainId}`] }
  }
  const r = (await client.readContract({
    address: ruling.arbiter,
    abi: aiArbiterAbi,
    functionName: 'getRuling',
    args: [BigInt(ruling.leaseId)],
  } as never)) as { status: number; tenantBps: number; confidenceBps: number; rulingHash: Hex }
  const status = RULING_STATUS[r.status] ?? 'NONE'
  const where = `AIArbiter ${ruling.arbiter} getRuling(${ruling.leaseId})`
  if (status === 'NONE') return { ok: false, lines: [`on-chain   ${where}: no proposal was ever made for this lease`] }
  if (r.rulingHash.toLowerCase() !== rulingHash.toLowerCase()) {
    return {
      ok: false,
      lines: [
        `on-chain   MISMATCH: ${where}.rulingHash is ${r.rulingHash} (status ${status}); this file is not the ruling behind the on-chain proposal`,
      ],
    }
  }
  if (status !== 'HUMAN_RESOLVED' && (r.tenantBps !== ruling.tenantBps || r.confidenceBps !== ruling.confidenceBps)) {
    return {
      ok: false,
      lines: [
        `on-chain   MISMATCH: the hash matches, but on-chain tenantBps ${r.tenantBps} / confidenceBps ${r.confidenceBps} are not the ruling's ${ruling.tenantBps} / ${ruling.confidenceBps}`,
      ],
    }
  }
  return {
    ok: true,
    lines: [
      `on-chain   ${where}.rulingHash matches (status ${status}, tenantBps ${r.tenantBps}${status === 'HUMAN_RESOLVED' ? ', set by the human' : ''})`,
    ],
  }
}
