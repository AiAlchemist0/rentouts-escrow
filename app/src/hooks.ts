import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback, useEffect, useState } from 'react'
import {
  getAddress,
  keccak256,
  toBytes,
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
import { erc20Abi } from './abi/erc20'
import { rentEscrowAbi } from './abi/rentEscrow'
import { rentoutsSubnamesAbi } from './abi/rentoutsSubnames'
import { CREDENTIAL_KEYS, ENS, ENV_CONTRACTS } from './config'
import { parseAddressInput, resolveAddressInput, type ResolvedInput } from './lib/addressInput'
import { labelUnder, type CredentialRecords } from './lib/credential'
import { errorMessage } from './lib/errors'
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
  minPeriod?: number
  sharesPerLease?: bigint
  tokenDecimals: number
  tokenSymbol: string
  /** Set when VITE_ESCROW_ADDRESS is configured but can't be read. */
  escrowError?: string
}

/**
 * Env addresses, upgraded with what the escrow itself reports: when RentEscrow is configured, its
 * token() and leaseShare() are the source of truth.
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
      const [token, leaseShare, arbiter, minPeriod, sharesPerLease] = await Promise.all([
        client.readContract({ ...at, functionName: 'token' }),
        client.readContract({ ...at, functionName: 'leaseShare' }),
        client.readContract({ ...at, functionName: 'arbiter' }),
        client.readContract({ ...at, functionName: 'MIN_PERIOD' }),
        client.readContract({ ...at, functionName: 'SHARES_PER_LEASE' }),
      ])
      return { token, leaseShare, arbiter, minPeriod, sharesPerLease }
    },
  })

  const onChain = escrowConfig.data
  const token = onChain?.token ?? ENV_CONTRACTS.token
  const leaseShare =
    onChain && onChain.leaseShare !== '0x0000000000000000000000000000000000000000'
      ? onChain.leaseShare
      : ENV_CONTRACTS.leaseShare

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
    arbiter: onChain?.arbiter,
    minPeriod: onChain?.minPeriod,
    sharesPerLease: onChain?.sharesPerLease,
    tokenDecimals: tokenMeta.data?.decimals ?? 6,
    tokenSymbol: tokenMeta.data?.symbol ?? 'USDC',
    escrowError: escrowConfig.isError
      ? `Couldn’t read RentEscrow at ${escrow}. Check VITE_ESCROW_ADDRESS. (${errorMessage(escrowConfig.error)})`
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
