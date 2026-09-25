import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback, useEffect, useState } from 'react'
import {
  getAbiItem,
  getAddress,
  keccak256,
  toBytes,
  zeroAddress,
  type Abi,
  type Address,
  type ContractFunctionArgs,
  type ContractFunctionName,
  type Hash,
  type TransactionReceipt,
} from 'viem'
import { normalize } from 'viem/ens'
import { useAccount, usePublicClient, useReadContract, useWriteContract } from 'wagmi'
import { sepolia } from 'wagmi/chains'
import { aiArbiterAbi } from './abi/aiArbiter'
import { erc20Abi } from './abi/erc20'
import { humanGateAbi } from './abi/humanGate'
import { rentEscrowAbi } from './abi/rentEscrow'
import { rentoutsSubnamesAbi } from './abi/rentoutsSubnames'
import { CREDENTIAL_KEYS, ENS, ENV_CONTRACTS } from './config'
import { parseAddressInput, resolveAddressInput, type ResolvedInput } from './lib/addressInput'
import { aiArbiterProblem, type ArbiterLog, type Ruling } from './lib/aiJudge'
import { labelUnder, type CredentialRecords } from './lib/credential'
import { errorMessage } from './lib/errors'
import type { HumanGateView } from './lib/humanGate'
import { recordTx } from './txLog'

export function useSepoliaClient() {
  const client = usePublicClient({ chainId: sepolia.id })
  if (!client) throw new Error('Sepolia client missing from wagmi config')
  return client
}

/** Unix seconds, ticking. */
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), intervalMs)
    return () => clearInterval(id)
  }, [intervalMs])
  return now
}

export function useDebounced<T>(value: T, ms = 400): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const id = setTimeout(() => setDebounced(value), ms)
    return () => clearTimeout(id)
  }, [value, ms])
  return debounced
}

/** Connected to the right chain with an account. */
export function useWallet() {
  const { address, chainId, isConnected } = useAccount()
  return { address, isConnected, onSepolia: chainId === sepolia.id, ready: isConnected && chainId === sepolia.id }
}

// ------------------------------------------------------------------ contracts

export type AppContracts = {
  escrow?: Address
  token: Address
  leaseShare?: Address
  credentialSync?: Address
  arbiter?: Address
  /** RentEscrow.humanGate(), checked in fundLease. undefined = funding not gated (or not read yet). */
  humanGate?: Address
  minPeriod?: number
  sharesPerLease?: bigint
  tokenDecimals: number
  tokenSymbol: string
  /** Set when VITE_ESCROW_ADDRESS is configured but can't be read. */
  escrowError?: string
}

/**
 * Env addresses, upgraded with what the escrow itself reports: when RentEscrow is configured, its
 * token() and leaseShare() are the source of truth, and humanGate() comes only from the escrow.
 */
export function useContracts(): AppContracts {
  const client = useSepoliaClient()
  const escrow = ENV_CONTRACTS.escrow

  const escrowConfig = useQuery({
    queryKey: ['escrow-config', escrow],
    enabled: !!escrow,
    staleTime: Infinity,
    retry: 2,
    queryFn: async () => {
      const at = { address: escrow!, abi: rentEscrowAbi } as const
      const [token, leaseShare, arbiter, humanGate, minPeriod, sharesPerLease] = await Promise.all([
        client.readContract({ ...at, functionName: 'token' }),
        client.readContract({ ...at, functionName: 'leaseShare' }),
        client.readContract({ ...at, functionName: 'arbiter' }),
        client.readContract({ ...at, functionName: 'humanGate' }),
        client.readContract({ ...at, functionName: 'MIN_PERIOD' }),
        client.readContract({ ...at, functionName: 'SHARES_PER_LEASE' }),
      ])
      return { token, leaseShare, arbiter, humanGate, minPeriod, sharesPerLease }
    },
  })

  const onChain = escrowConfig.data
  const token = onChain?.token ?? ENV_CONTRACTS.token
  const leaseShare = onChain && onChain.leaseShare !== zeroAddress ? onChain.leaseShare : ENV_CONTRACTS.leaseShare
  // Until the escrow is read, deployments.json's record of the same escrow stands in.
  const humanGate = onChain ? (onChain.humanGate !== zeroAddress ? onChain.humanGate : undefined) : ENV_CONTRACTS.humanGate

  const tokenMeta = useQuery({
    queryKey: ['token-meta', token],
    staleTime: Infinity,
    queryFn: async () => {
      const [decimals, symbol] = await Promise.all([
        client.readContract({ address: token, abi: erc20Abi, functionName: 'decimals' }),
        client.readContract({ address: token, abi: erc20Abi, functionName: 'symbol' }),
      ])
      return { decimals, symbol }
    },
  })

  return {
    escrow: escrow && !escrowConfig.isError ? escrow : undefined,
    token,
    leaseShare,
    credentialSync: ENV_CONTRACTS.credentialSync,
    arbiter: onChain?.arbiter ?? ENV_CONTRACTS.arbiter,
    humanGate,
    minPeriod: onChain?.minPeriod,
    sharesPerLease: onChain?.sharesPerLease,
    tokenDecimals: tokenMeta.data?.decimals ?? 6,
    tokenSymbol: tokenMeta.data?.symbol ?? 'USDC',
    escrowError: escrowConfig.isError
      ? `Couldn’t read RentEscrow at ${escrow}. Check VITE_ESCROW_ADDRESS or deployments.json. (${errorMessage(escrowConfig.error)})`
      : undefined,
  }
}

// ------------------------------------------------------------------ transactions

export type TxState =
  | { status: 'idle' }
  | { status: 'simulating' }
  | { status: 'signing' }
  | { status: 'pending'; hash: Hash }
  | { status: 'success'; hash: Hash }
  | { status: 'error'; message: string; hash?: Hash }

type WriteParams<
  abi extends Abi,
  functionName extends ContractFunctionName<abi, 'nonpayable' | 'payable'>,
> = {
  address: Address
  abi: abi
  functionName: functionName
  args: ContractFunctionArgs<abi, 'nonpayable' | 'payable', functionName>
}

/**
 * simulate -> sign -> wait, with one status for the UI. The simulation runs first so reverts show up
 * as a readable message before MetaMask opens. Every query is refetched after a confirmed transaction.
 */
export function useTx() {
  const client = useSepoliaClient()
  const { address, ready } = useWallet()
  const { writeContractAsync } = useWriteContract()
  const queryClient = useQueryClient()
  const [state, setState] = useState<TxState>({ status: 'idle' })

  const run = useCallback(
    async <const abi extends Abi, functionName extends ContractFunctionName<abi, 'nonpayable' | 'payable'>>(
      params: WriteParams<abi, functionName>,
      label: string = String(params.functionName),
    ): Promise<TransactionReceipt | undefined> => {
      if (!address) {
        setState({ status: 'error', message: 'Connect MetaMask first.' })
        return
      }
      if (!ready) {
        setState({ status: 'error', message: 'Switch MetaMask to Ethereum Sepolia first.' })
        return
      }
      let hash: Hash | undefined
      try {
        setState({ status: 'simulating' })
        // viem's generics can't follow the call through this wrapper; callers are type-checked by WriteParams.
        const call = { ...params, account: address } as unknown as Parameters<typeof client.simulateContract>[0]
        await client.simulateContract(call)
        setState({ status: 'signing' })
        hash = await writeContractAsync({
          ...params,
          chainId: sepolia.id,
        } as unknown as Parameters<typeof writeContractAsync>[0])
        setState({ status: 'pending', hash })
        recordTx({ hash, label, status: 'pending' })
        const receipt = await client.waitForTransactionReceipt({ hash })
        recordTx({ hash, label, status: receipt.status === 'success' ? 'success' : 'reverted' })
        if (receipt.status !== 'success') throw new Error('The transaction reverted on-chain.')
        setState({ status: 'success', hash })
        await queryClient.invalidateQueries()
        return receipt
      } catch (error) {
        setState({ status: 'error', message: errorMessage(error), hash })
        return
      }
    },
    [address, ready, client, writeContractAsync, queryClient],
  )

  const reset = useCallback(() => setState({ status: 'idle' }), [])
  const busy = state.status === 'simulating' || state.status === 'signing' || state.status === 'pending'
  return { state, run, reset, busy }
}

// ------------------------------------------------------------------ ENS

/** Parent name (e.g. rentouts.eth), read from RentoutsSubnames rather than hard-coded. */
export function useParentName(): string | undefined {
  const { data } = useReadContract({
    address: ENS.subnames,
    abi: rentoutsSubnamesAbi,
    functionName: 'parentName',
    chainId: sepolia.id,
    query: { staleTime: Infinity },
  })
  return data
}

/** The connected (or any) account's RentOuts name, "" if none. */
export function useRentoutsName(account: Address | undefined) {
  return useReadContract({
    address: ENS.subnames,
    abi: rentoutsSubnamesAbi,
    functionName: 'nameOf',
    args: account ? [account] : undefined,
    chainId: sepolia.id,
    query: { enabled: !!account },
  })
}

/** RentOuts names for a set of addresses (one multicall). */
export function useRentoutsNames(addresses: readonly Address[]) {
  const client = useSepoliaClient()
  const unique = [...new Set(addresses.map((a) => getAddress(a)))].sort()
  const { data } = useQuery({
    queryKey: ['rentouts-names', unique],
    enabled: unique.length > 0,
    staleTime: 60_000,
    queryFn: async () => {
      const names = await client.multicall({
        allowFailure: false,
        contracts: unique.map((a) => ({
          address: ENS.subnames,
          abi: rentoutsSubnamesAbi,
          functionName: 'nameOf' as const,
          args: [a] as const,
        })),
      })
      return Object.fromEntries(unique.map((a, i) => [a, names[i]]))
    },
  })
  return (address: Address) => data?.[getAddress(address)] || undefined
}

export type Credential = {
  name: string
  address: Address | null
  records: CredentialRecords
  /** RentoutsSubnames.holderOf(labelhash) for names under the parent, else null. */
  expectedHolder: Address | null
}

/** Reads a name's addr + rentouts.* records through the ENSv2 Universal Resolver. */
export function useCredential(name: string | undefined) {
  const client = useSepoliaClient()
  const parent = useParentName()
  return useQuery({
    queryKey: ['credential', name, parent],
    enabled: !!name && !!parent,
    staleTime: 15_000,
    queryFn: async (): Promise<Credential> => {
      const normalized = normalize(name!)
      const universalResolverAddress = ENS.universalResolver
      const label = labelUnder(normalized, parent!)
      const [address, texts, holder] = await Promise.all([
        client.getEnsAddress({ name: normalized, universalResolverAddress }),
        Promise.all(CREDENTIAL_KEYS.map((key) => client.getEnsText({ name: normalized, key, universalResolverAddress }))),
        label
          ? client.readContract({
              address: ENS.subnames,
              abi: rentoutsSubnamesAbi,
              functionName: 'holderOf',
              args: [BigInt(keccak256(toBytes(label)))],
            })
          : Promise.resolve(null),
      ])
      const records = Object.fromEntries(CREDENTIAL_KEYS.map((k, i) => [k, texts[i]])) as CredentialRecords
      const expectedHolder = holder && holder !== '0x0000000000000000000000000000000000000000' ? holder : null
      return { name: normalized, address, records, expectedHolder }
    },
  })
}

/** The Claimed event (and so the claim transaction) for a holder, scanning from the subnames deploy block. */
export function useClaimTx(holder: Address | undefined) {
  const client = useSepoliaClient()
  return useQuery({
    queryKey: ['claim-tx', holder],
    enabled: !!holder,
    staleTime: 60_000,
    queryFn: async () => {
      const latest = await client.getBlockNumber()
      // Public RPCs cap eth_getLogs ranges (publicnode: 50k blocks).
      const floor = latest > 49_000n ? latest - 49_000n : 0n
      const fromBlock = ENS.subnamesDeployBlock > floor ? ENS.subnamesDeployBlock : floor
      const logs = await client.getLogs({
        address: ENS.subnames,
        event: rentoutsSubnamesAbi.find((i) => i.type === 'event' && i.name === 'Claimed')!,
        args: { holder },
        fromBlock,
        toBlock: latest,
      })
      return logs.at(-1)?.transactionHash ?? null
    },
  })
}

export type { ResolvedInput } from './lib/addressInput'

/**
 * An input that takes an ENS name (resolved via the Universal Resolver) or a raw 0x address. Names are
 * looked up 350 ms after the last keystroke, and the result is `pending` until then (see resolveAddressInput).
 */
export function useAddressInput(input: string): ResolvedInput {
  const client = useSepoliaClient()
  const live = input.trim()
  const value = useDebounced(live, 350)
  const parsed = parseAddressInput(value)
  const normalized = parsed.kind === 'name' ? parsed.name : null
  const lookup = useQuery({
    queryKey: ['resolve', normalized],
    enabled: !!normalized,
    staleTime: 30_000,
    queryFn: () => client.getEnsAddress({ name: normalized!, universalResolverAddress: ENS.universalResolver }),
  })
  return resolveAddressInput(live, value, lookup)
}

// ------------------------------------------------------------------ escrow

/**
 * The escrow's human gate as it applies to `account`: isVerified(account), and whether HumanGate is open
 * (verifier() == address(0), everyone passes). Both are undefined until read, or if the read fails.
 */
export function useHumanGate(account: Address | undefined): HumanGateView {
  const { humanGate } = useContracts()
  const verified = useReadContract({
    address: humanGate,
    abi: humanGateAbi,
    functionName: 'isVerified',
    args: account ? [account] : undefined,
    chainId: sepolia.id,
    query: { enabled: !!humanGate && !!account },
  })
  const verifier = useReadContract({
    address: humanGate,
    abi: humanGateAbi,
    functionName: 'verifier',
    chainId: sepolia.id,
    // Any IHumanGate may sit here; only HumanGate has verifier().
    query: { enabled: !!humanGate, retry: false },
  })
  return {
    gate: humanGate,
    verified: humanGate && account ? verified.data : undefined,
    open: humanGate && verifier.data !== undefined ? verifier.data === zeroAddress : undefined,
  }
}

export type LeaseRow = {
  id: bigint
  landlord: Address
  tenant: Address
  deposit: bigint
  rentPerPeriod: bigint
  periodSeconds: number
  periods: number
  periodsClaimed: number
  startTime: bigint
  state: number
  claimablePeriods: number
  claimableAmount: bigint
  escrowBalance: bigint
}

const MAX_LEASES = 200

/**
 * Every lease, newest first: nextLeaseId, then getLease / claimable / escrowBalance for ids 1..n-1 in
 * three multicalls. Iterating ids avoids eth_getLogs range limits on public RPCs.
 */
export function useLeases(escrow: Address | undefined) {
  const client = useSepoliaClient()
  return useQuery({
    queryKey: ['leases', escrow],
    enabled: !!escrow,
    refetchInterval: 12_000,
    queryFn: async (): Promise<LeaseRow[]> => {
      const at = { address: escrow!, abi: rentEscrowAbi } as const
      const next = await client.readContract({ ...at, functionName: 'nextLeaseId' })
      const first = next - 1n > BigInt(MAX_LEASES) ? next - BigInt(MAX_LEASES) : 1n
      const ids: bigint[] = []
      for (let id = next - 1n; id >= first; id--) ids.push(id)
      if (ids.length === 0) return []
      const [leases, claimables, balances] = await Promise.all([
        client.multicall({
          allowFailure: false,
          contracts: ids.map((id) => ({ ...at, functionName: 'getLease' as const, args: [id] as const })),
        }),
        client.multicall({
          allowFailure: false,
          contracts: ids.map((id) => ({ ...at, functionName: 'claimable' as const, args: [id] as const })),
        }),
        client.multicall({
          allowFailure: false,
          contracts: ids.map((id) => ({ ...at, functionName: 'escrowBalance' as const, args: [id] as const })),
        }),
      ])
      return ids.map((id, i) => ({
        id,
        ...leases[i],
        claimablePeriods: claimables[i][0],
        claimableAmount: claimables[i][1],
        escrowBalance: balances[i],
      }))
    },
  })
}

// ------------------------------------------------------------------ AI dispute judge

export type AiArbiterInfo = {
  address: Address
  /** The human arbiter: resolves directly, handles appeals, overrides proposals. */
  human: Address
  /** The AI judge service key; undefined = AI proposals switched off. */
  agent?: Address
  challengeWindow: number
  /** AIArbiter.escrow(); undefined until the human calls bindEscrow. */
  boundEscrow?: Address
  maxStatementBytes: number
  maxStatementsPerParty: number
  /** Where log scans start, if deployments.json recorded it. */
  fromBlock?: bigint
}

export type AiArbiterState = {
  info?: AiArbiterInfo
  /** Why AI rulings can't settle this escrow's disputes (not bound, bound elsewhere, not the escrow's arbiter). */
  problem?: string
  /** A configured AIArbiter (env / deployments.json) that can't be read. */
  error?: string
}

/**
 * The AIArbiter: VITE_AI_ARBITER_ADDRESS, else deployments.json "sepoliaAIArbiter", else RentEscrow.arbiter()
 * if that turns out to be one (it answers escrow(), human(), agent() ...). A plain-account arbiter just
 * yields no info, and the lease screen falls back to direct resolveDispute.
 */
export function useAiArbiter(): AiArbiterState {
  const client = useSepoliaClient()
  const { escrow, arbiter } = useContracts()
  const configured = ENV_CONTRACTS.aiArbiter
  const candidate = configured ?? arbiter
  const query = useQuery({
    queryKey: ['ai-arbiter', candidate],
    enabled: !!candidate,
    staleTime: 60_000,
    retry: configured ? 2 : false,
    queryFn: async (): Promise<AiArbiterInfo> => {
      const at = { address: candidate!, abi: aiArbiterAbi } as const
      const [bound, human, agent, challengeWindow, maxBytes, maxStatements] = await client.multicall({
        allowFailure: false,
        contracts: [
          { ...at, functionName: 'escrow' },
          { ...at, functionName: 'human' },
          { ...at, functionName: 'agent' },
          { ...at, functionName: 'challengeWindow' },
          { ...at, functionName: 'MAX_STATEMENT_BYTES' },
          { ...at, functionName: 'MAX_STATEMENTS_PER_PARTY' },
        ],
      })
      return {
        address: candidate!,
        human,
        agent: agent === zeroAddress ? undefined : agent,
        challengeWindow,
        boundEscrow: bound === zeroAddress ? undefined : bound,
        maxStatementBytes: Number(maxBytes),
        maxStatementsPerParty: Number(maxStatements),
        // Set only when the candidate is the AIArbiter deployments.json recorded.
        fromBlock: ENV_CONTRACTS.aiFromBlock,
      }
    },
  })
  const info = query.data
  if (!info) {
    return query.isError && configured
      ? { error: `Couldn’t read the AI judge contract at ${configured}. Check VITE_AI_ARBITER_ADDRESS or deployments.json. (${errorMessage(query.error)})` }
      : {}
  }
  const problem = aiArbiterProblem({ aiArbiter: info.address, boundEscrow: info.boundEscrow, escrow, escrowArbiter: arbiter })
  return { info, problem: problem ?? undefined }
}

/** Public RPCs cap eth_getLogs ranges (publicnode: 50k blocks). */
const LOG_WINDOW = 49_000n

const ARBITER_EVENTS = [
  getAbiItem({ abi: aiArbiterAbi, name: 'Evidence' }),
  getAbiItem({ abi: aiArbiterAbi, name: 'Proposed' }),
  getAbiItem({ abi: aiArbiterAbi, name: 'Appealed' }),
] as const

/**
 * Every Evidence / Proposed / Appealed log of the AIArbiter, in one getLogs shared by all lease cards: statements
 * and the judge's summary live only in events. Scans from the recorded deploy block, or the last 49k blocks.
 */
export function useArbiterLogs(info: AiArbiterInfo | undefined) {
  const client = useSepoliaClient()
  return useQuery({
    queryKey: ['ai-arbiter-logs', info?.address],
    enabled: !!info,
    refetchInterval: 12_000,
    queryFn: async (): Promise<ArbiterLog[]> => {
      const latest = await client.getBlockNumber()
      const floor = latest > LOG_WINDOW ? latest - LOG_WINDOW : 0n
      const fromBlock = info!.fromBlock !== undefined && info!.fromBlock > floor ? info!.fromBlock : floor
      const logs = await client.getLogs({
        address: info!.address,
        events: ARBITER_EVENTS,
        fromBlock,
        toBlock: latest,
        strict: true,
      })
      const typed: ArbiterLog[] = logs
      return typed
    },
  })
}

/**
 * getRuling(leaseId) plus how many statements each party has used, in one multicall. Polled while the lease is
 * disputed; a closed lease's ruling is final (it still refetches after this app's own transactions).
 */
export function useRuling(info: AiArbiterInfo | undefined, lease: { id: bigint; tenant: Address; landlord: Address }, live: boolean) {
  const client = useSepoliaClient()
  return useQuery({
    // `live` in the key: when the lease closes (from any wallet) the ruling is read afresh, never left stale.
    queryKey: ['ai-ruling', info?.address, String(lease.id), live],
    enabled: !!info,
    refetchInterval: live ? 12_000 : false,
    staleTime: live ? 0 : 60_000,
    placeholderData: keepPreviousData, // no flicker while the closed-lease read replaces the live one
    queryFn: async (): Promise<{ ruling: Ruling; tenantStatements: number; landlordStatements: number }> => {
      const at = { address: info!.address, abi: aiArbiterAbi } as const
      const [ruling, tenantStatements, landlordStatements] = await client.multicall({
        allowFailure: false,
        contracts: [
          { ...at, functionName: 'getRuling', args: [lease.id] },
          { ...at, functionName: 'evidenceCount', args: [lease.id, lease.tenant] },
          { ...at, functionName: 'evidenceCount', args: [lease.id, lease.landlord] },
        ],
      })
      return { ruling, tenantStatements: Number(tenantStatements), landlordStatements: Number(landlordStatements) }
    },
  })
}
