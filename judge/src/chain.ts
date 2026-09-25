import { erc20Abi, isAddressEqual, zeroAddress, type PublicClient } from 'viem'
import { normalize } from 'viem/ens'
import { aiArbiterAbi, rentEscrowAbi, rentoutsSubnamesAbi } from './abi.ts'
import type { Address, DisputeInput, EvidenceItem, Hex, LeaseFacts, Party, TenantCredential } from './types.ts'

/** Ethereum Sepolia addresses the judge reads (ens/deployments/sepolia.json on ens-integration). */
export const SEPOLIA = {
  chainId: 11155111,
  universalResolver: '0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe' as Address,
  rentoutsSubnames: '0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60' as Address,
}

/** rentouts.* records read for the human reviewer. Only name / status / resolution reach the model. */
export const CREDENTIAL_KEYS = [
  'rentouts.credential',
  'rentouts.status',
  'rentouts.leasesCompleted',
  'rentouts.disputes',
  'rentouts.rentPaid',
  'rentouts.depositReturnRate',
  'rentouts.rating',
] as const

export const LEASE_STATE = ['NONE', 'CREATED', 'ACTIVE', 'DISPUTED', 'CLOSED', 'CANCELLED'] as const
export const RULING_STATUS = ['NONE', 'PROPOSED', 'APPEALED', 'EXECUTED', 'HUMAN_RESOLVED'] as const
const DISPUTED = 3

export interface OnchainLease {
  landlord: Address
  tenant: Address
  deposit: bigint
  rentPerPeriod: bigint
  periodSeconds: number
  periods: number
  periodsClaimed: number
  startTime: bigint
  state: number
}

export interface ArbiterState {
  escrow: Address
  agent: Address
  human: Address
  challengeWindow: number
  ruling: {
    status: (typeof RULING_STATUS)[number]
    tenantBps: number
    confidenceBps: number
    proposedAt: bigint
    deadline: bigint
    rulingHash: Hex
  }
}

export class NotDisputedError extends Error {
  name = 'NotDisputedError'
}

/**
 * Splits a disputed lease's remaining escrow into deposit / earned-unreleased rent / unearned
 * rent, the way RentEscrow does: rent stops accruing when the dispute is opened, and the periods
 * earned then are min(periods, (disputeOpenedAt - startTime) / periodSeconds).
 */
export function leaseFacts(args: {
  leaseId: bigint
  lease: OnchainLease
  escrowBalance: bigint
  disputeOpenedAt: number
  disputeOpenedBy: Address
  token: LeaseFacts['token']
}): LeaseFacts {
  const { lease: l } = args
  const start = Number(l.startTime)
  const elapsed = Math.floor(Math.max(0, args.disputeOpenedAt - start) / l.periodSeconds)
  const earned = Math.min(l.periods, elapsed)
  const earnedUnreleased = BigInt(Math.max(0, earned - l.periodsClaimed)) * l.rentPerPeriod
  const unearned = BigInt(l.periods - Math.max(earned, l.periodsClaimed)) * l.rentPerPeriod
  if (l.deposit + earnedUnreleased + unearned !== args.escrowBalance) {
    throw new Error(
      `lease ${args.leaseId}: escrowBalance ${args.escrowBalance} != deposit + unreleased rent (${l.deposit + earnedUnreleased + unearned})`,
    )
  }
  return {
    leaseId: args.leaseId.toString(),
    landlord: l.landlord,
    tenant: l.tenant,
    token: args.token,
    deposit: l.deposit.toString(),
    rentPerPeriod: l.rentPerPeriod.toString(),
    periodSeconds: l.periodSeconds,
    periods: l.periods,
    periodsClaimed: l.periodsClaimed,
    startTime: start,
    disputeOpenedAt: args.disputeOpenedAt,
    disputeOpenedBy: partyOf(args.disputeOpenedBy, l),
    periodsEarnedAtDispute: earned,
    remainingEscrow: args.escrowBalance.toString(),
    earnedRentUnreleased: earnedUnreleased.toString(),
    unearnedRent: unearned.toString(),
  }
}

export function partyOf(who: Address, l: { tenant: Address; landlord: Address }): Party {
  if (isAddressEqual(who, l.tenant)) return 'tenant'
  if (isAddressEqual(who, l.landlord)) return 'landlord'
  throw new Error(`${who} is neither the tenant nor the landlord`)
}

export async function readArbiter(client: PublicClient, arbiter: Address, leaseId: bigint): Promise<ArbiterState> {
  const read = <T>(functionName: string, args: readonly unknown[] = []) =>
    client.readContract({ address: arbiter, abi: aiArbiterAbi, functionName, args } as never) as Promise<T>
  const [escrow, agent, human, challengeWindow, r] = await Promise.all([
    read<Address>('escrow'),
    read<Address>('agent'),
    read<Address>('human'),
    read<number>('challengeWindow'),
    read<{
      status: number
      tenantBps: number
      confidenceBps: number
      proposedAt: bigint
      deadline: bigint
      rulingHash: Hex
    }>('getRuling', [leaseId]),
  ])
  return {
    escrow,
    agent,
    human,
    challengeWindow: Number(challengeWindow),
    ruling: { ...r, status: RULING_STATUS[r.status] ?? 'NONE' },
  }
}

/** getLogs in fixed-size block ranges (public RPCs cap the range of one query). */
async function scan<T>(
  from: bigint,
  to: bigint,
  chunk: bigint,
  fetchRange: (fromBlock: bigint, toBlock: bigint) => Promise<T[]>,
): Promise<T[]> {
  const out: T[] = []
  for (let start = from; start <= to; start += chunk) {
    const end = start + chunk - 1n < to ? start + chunk - 1n : to
    out.push(...(await fetchRange(start, end)))
  }
  return out
}

export interface LoadOptions {
  /** First block to scan for DisputeOpened / Evidence (the AIArbiter deploy block or earlier). */
  fromBlock?: bigint
  logChunk?: bigint
  log?: (line: string) => void
}

/** Everything the judge reads from chain for one disputed lease, as a DisputeInput. */
export async function loadDisputeInput(
  client: PublicClient,
  arbiter: Address,
  leaseId: bigint,
  opts: LoadOptions = {},
): Promise<{ input: DisputeInput; arbiterState: ArbiterState }> {
  const log = opts.log ?? (() => {})
  const chunk = opts.logChunk ?? 10_000n
  const chainId = await client.getChainId()
  const arbiterState = await readArbiter(client, arbiter, leaseId)
  const escrow = arbiterState.escrow
  if (isAddressEqual(escrow, zeroAddress)) {
    throw new Error(`AIArbiter ${arbiter} has no escrow bound yet (the human arbiter calls bindEscrow)`)
  }

  const [lease, escrowBalance, escrowArbiter, tokenAddress] = await Promise.all([
    client.readContract({ address: escrow, abi: rentEscrowAbi, functionName: 'getLease', args: [leaseId] }),
    client.readContract({ address: escrow, abi: rentEscrowAbi, functionName: 'escrowBalance', args: [leaseId] }),
    client.readContract({ address: escrow, abi: rentEscrowAbi, functionName: 'arbiter' }),
    client.readContract({ address: escrow, abi: rentEscrowAbi, functionName: 'token' }),
  ])
  if (!isAddressEqual(escrowArbiter, arbiter)) {
    throw new Error(`escrow ${escrow} has arbiter ${escrowArbiter}, not ${arbiter}`)
  }
  if (lease.state !== DISPUTED) {
    throw new NotDisputedError(`lease ${leaseId} is ${LEASE_STATE[lease.state] ?? lease.state}, not DISPUTED`)
  }
  const [symbol, decimals] = await Promise.all([
    client.readContract({ address: tokenAddress, abi: erc20Abi, functionName: 'symbol' }),
    client.readContract({ address: tokenAddress, abi: erc20Abi, functionName: 'decimals' }),
  ])

  const latest = await client.getBlockNumber()
  const fromBlock = opts.fromBlock ?? (latest > 50_000n ? latest - 50_000n : 0n)
  log(`scanning blocks ${fromBlock}..${latest} for the dispute and its evidence`)
  const opened = await scan(fromBlock, latest, chunk, (f, t) =>
    client.getContractEvents({
      address: escrow,
      abi: rentEscrowAbi,
      eventName: 'DisputeOpened',
      args: { leaseId },
      fromBlock: f,
      toBlock: t,
    }),
  )
  const openedLog = opened.at(-1)
  if (!openedLog || openedLog.blockNumber === null) {
    throw new Error(`no DisputeOpened event for lease ${leaseId} since block ${fromBlock}: pass --from-block`)
  }
  const openedBlock = await client.getBlock({ blockNumber: openedLog.blockNumber })

  const evidenceLogs = await scan(openedLog.blockNumber, latest, chunk, (f, t) =>
    client.getContractEvents({
      address: arbiter,
      abi: aiArbiterAbi,
      eventName: 'Evidence',
      args: { leaseId },
      fromBlock: f,
      toBlock: t,
    }),
  )
  const evidence: EvidenceItem[] = evidenceLogs.map((e, i) => {
    const args = e.args as { party: Address; statement: string }
    return {
      id: `E${i + 1}`,
      party: partyOf(args.party, lease),
      author: args.party,
      statement: args.statement,
      txHash: e.transactionHash as Hex,
      blockNumber: String(e.blockNumber),
      logIndex: Number(e.logIndex),
    }
  })

  const tenantCredential = await readTenantCredential(client, lease.tenant, log)

  const input: DisputeInput = {
    version: 1,
    chainId,
    escrow,
    arbiter,
    lease: leaseFacts({
      leaseId,
      lease: { ...lease, startTime: BigInt(lease.startTime) },
      escrowBalance,
      disputeOpenedAt: Number(openedBlock.timestamp),
      disputeOpenedBy: (openedLog.args as { by: Address }).by,
      token: { address: tokenAddress, symbol, decimals },
    }),
    evidence,
    tenantCredential,
  }
  return { input, arbiterState }
}

/**
 * The tenant's RentOuts name (RentoutsSubnames.nameOf) and its rentouts.* records through the
 * ENSv2 Universal Resolver. A failed lookup is recorded, never fatal: the judge can rule without it.
 */
export async function readTenantCredential(
  client: PublicClient,
  tenant: Address,
  log: (line: string) => void = () => {},
): Promise<TenantCredential> {
  try {
    const name = await client.readContract({
      address: SEPOLIA.rentoutsSubnames,
      abi: rentoutsSubnamesAbi,
      functionName: 'nameOf',
      args: [tenant],
    })
    if (!name) return { name: null, status: null, resolvesToTenant: false, records: {} }
    const normalized = normalize(name)
    const universalResolverAddress = SEPOLIA.universalResolver
    const [address, ...texts] = await Promise.all([
      client.getEnsAddress({ name: normalized, universalResolverAddress }),
      ...CREDENTIAL_KEYS.map((key) => client.getEnsText({ name: normalized, key, universalResolverAddress })),
    ])
    const records = Object.fromEntries(CREDENTIAL_KEYS.map((k, i) => [k, (texts[i] as string | null) ?? null]))
    return {
      name: normalized,
      status: records['rentouts.status'] ?? null,
      resolvesToTenant: !!address && isAddressEqual(address as Address, tenant),
      records,
    }
  } catch (err) {
    log(`ENS lookup for the tenant failed: ${(err as Error).message.split('\n')[0]}`)
    return { name: null, status: null, resolvesToTenant: false, records: {}, error: 'ENS lookup failed' }
  }
}
