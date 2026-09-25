import { getAddress, isAddress, isAddressEqual, zeroAddress, type Address } from 'viem'

export const SEPOLIA_CHAIN_ID = 11_155_111

/**
 * What the app takes from the repo-root deployments.json. script/DeployEscrow.s.sol writes the "sepolia" entry
 * (rentEscrow, leaseShare1155, humanGate, token, arbiter); script/DeployAIArbiter.s.sol writes
 * "sepoliaAIArbiter" (aiArbiter, human, agent, challengeWindow, fromBlock). Every field is optional: a missing
 * file, entry or key just means "not deployed".
 */
export type Deployments = {
  rentEscrow?: Address
  leaseShare1155?: Address
  humanGate?: Address
  token?: Address
  arbiter?: Address
  aiArbiter?: Address
  /** A block at or before the AIArbiter deploy: where log scans for Evidence / Proposed start. */
  aiFromBlock?: bigint
}

/** A non-zero address, checksummed; anything else (missing, malformed, zero) is undefined. */
export function asAddress(value: unknown): Address | undefined {
  if (typeof value !== 'string') return undefined
  const v = value.trim()
  if (!isAddress(v, { strict: false })) return undefined
  const address = getAddress(v)
  return address === zeroAddress ? undefined : address
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined
}

/** An entry counts only on Ethereum Sepolia; the scripts always write chainId. */
function sepoliaEntry(value: unknown): Record<string, unknown> | undefined {
  const entry = asRecord(value)
  if (!entry) return undefined
  return entry.chainId === undefined || Number(entry.chainId) === SEPOLIA_CHAIN_ID ? entry : undefined
}

function asBlock(value: unknown): bigint | undefined {
  if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) return BigInt(value)
  if (typeof value === 'string' && /^\d+$/.test(value.trim())) return BigInt(value.trim())
  return undefined
}

/** Reads the "sepolia" and "sepoliaAIArbiter" entries of a parsed deployments.json. Never throws. */
export function parseDeployments(raw: unknown): Deployments {
  const root = asRecord(raw)
  const core = sepoliaEntry(root?.sepolia)
  const ai = sepoliaEntry(root?.sepoliaAIArbiter)
  return {
    rentEscrow: asAddress(core?.rentEscrow),
    leaseShare1155: asAddress(core?.leaseShare1155),
    humanGate: asAddress(core?.humanGate),
    token: asAddress(core?.token),
    arbiter: asAddress(core?.arbiter),
    aiArbiter: asAddress(ai?.aiArbiter),
    aiFromBlock: ai ? asBlock(ai.fromBlock) : undefined,
  }
}

/** VITE_* overrides, already parsed with asAddress. */
export type EnvAddresses = {
  escrow?: Address
  leaseShare?: Address
  token?: Address
  aiArbiter?: Address
}

export type ConfiguredContracts = {
  escrow?: Address
  leaseShare?: Address
  token?: Address
  /** Hints until the escrow is read: RentEscrow.humanGate() / arbiter() are the source of truth. */
  humanGate?: Address
  arbiter?: Address
  aiArbiter?: Address
  aiFromBlock?: bigint
}

/**
 * Env wins over deployments.json. The record's leaseShare / token / humanGate / arbiter describe the recorded
 * escrow, so they're dropped when VITE_ESCROW_ADDRESS points somewhere else; likewise the record's fromBlock
 * belongs to the recorded AIArbiter only.
 */
export function resolveContracts(env: EnvAddresses, deployed: Deployments): ConfiguredContracts {
  const same = (a: Address | undefined, b: Address | undefined) => !!a && !!b && isAddressEqual(a, b)
  const escrow = env.escrow ?? deployed.rentEscrow
  const recordedEscrow = !env.escrow || same(env.escrow, deployed.rentEscrow)
  const aiArbiter = env.aiArbiter ?? deployed.aiArbiter
  return {
    escrow,
    leaseShare: env.leaseShare ?? (recordedEscrow ? deployed.leaseShare1155 : undefined),
    token: env.token ?? (recordedEscrow ? deployed.token : undefined),
    humanGate: recordedEscrow ? deployed.humanGate : undefined,
    arbiter: recordedEscrow ? deployed.arbiter : undefined,
    aiArbiter,
    aiFromBlock: same(aiArbiter, deployed.aiArbiter) ? deployed.aiFromBlock : undefined,
  }
}
