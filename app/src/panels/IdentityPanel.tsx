import { useQuery } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import type { Address } from 'viem'
import { rentoutsSubnamesAbi } from '../abi/rentoutsSubnames'
import { CredentialCard } from '../components/CredentialCard'
import { Field, Notice, TxStatus } from '../components/ui'
import { ENS } from '../config'
import { useDebounced, useParentName, useRentoutsName, useSepoliaClient, useTx, useWallet } from '../hooks'
import { errorMessage } from '../lib/errors'
import { checkLabel } from '../lib/label'

/** Availability = would register(label, me) succeed right now? Covers taken, retired and one-per-address. */
function useClaimCheck(label: string | null, account: Address | undefined) {
  const client = useSepoliaClient()
  return useQuery({
    queryKey: ['claim-check', label, account],
    enabled: !!label && !!account,
    staleTime: 10_000,
    retry: false,
    queryFn: async () => {
      try {
        await client.simulateContract({
          address: ENS.subnames,
          abi: rentoutsSubnamesAbi,
          functionName: 'register',
          args: [label!, account!],
          account: account!,
        })
        return { available: true as const }
      } catch (error) {
        return { available: false as const, message: errorMessage(error) }
      }
    },
  })
}

/** EIP-7702 delegated accounts carry code (0xef0100…) and ENS's ERC-1155 mint can refuse them. */
function useDelegationWarning(account: Address | undefined) {
  const client = useSepoliaClient()
  const { data } = useQuery({
    queryKey: ['code', account],
    enabled: !!account,
    staleTime: Infinity,
    queryFn: () => client.getCode({ address: account! }),
  })
  return !!data && data !== '0x'
}

function ClaimForm({ account, parent }: { account: Address; parent: string }) {
  const [input, setInput] = useState('')
  const checked = checkLabel(input)
  const debouncedLabel = useDebounced(checked.ok ? checked.label : null, 400)
  const check = useClaimCheck(debouncedLabel, account)
  const hasCode = useDelegationWarning(account)
  const tx = useTx()

  const label = checked.ok ? checked.label : null
  const settled = label !== null && label === debouncedLabel && !check.isFetching
  const available = settled && check.data?.available === true

  async function onSubmit(event: FormEvent) {
    event.preventDefault()
    if (!label || !available) return
    await tx.run(
      { address: ENS.subnames, abi: rentoutsSubnamesAbi, functionName: 'register', args: [label, account] },
      `Claim ${label}.${parent}`,
    )
  }

  let status: { tone: 'hint' | 'ok' | 'bad'; text: string } | null = null
  if (input.trim() !== '' && !checked.ok) status = { tone: 'bad', text: checked.reason }
  else if (label && !settled) status = { tone: 'hint', text: 'Checking availability on-chain…' }
  else if (label && check.data && !check.data.available) status = { tone: 'bad', text: check.data.message }
  else if (available) status = { tone: 'ok', text: `${label}.${parent} is available.` }

  return (
    <form className="claim" onSubmit={onSubmit}>
      <h2>Claim your tenant name</h2>
      <p className="lede">
        A soulbound ENS subname on the ENSv2 beta. It can’t be transferred, and it carries your rental track record as
        text records that only RentOuts can write.
      </p>
      <Field label="Name" htmlFor="claim-label">
        <div className="name-input">
          <input
            id="claim-label"
            value={input}
            onChange={(e) => {
              setInput(e.target.value)
              tx.reset()
            }}
            placeholder="yourname"
            autoComplete="off"
            spellCheck={false}
            maxLength={64}
            aria-describedby="claim-status"
          />
          <span className="name-suffix">.{parent}</span>
        </div>
      </Field>
      <p id="claim-status" className={`status status-${status?.tone ?? 'hint'}`} aria-live="polite">
        {status?.text ?? '3–32 lowercase letters, digits or hyphens.'}
      </p>
      {hasCode ? (
        <Notice tone="warn">
          This account has contract code (an EIP-7702 smart-account upgrade). ENS may refuse to mint to it; a plain
          MetaMask account works.
        </Notice>
      ) : null}
      <button type="submit" className="btn btn-primary" disabled={!available || tx.busy}>
        {label ? `Claim ${label}.${parent}` : 'Claim name'}
      </button>
      <TxStatus state={tx.state} done="Name claimed." />
    </form>
  )
}

/** ?name=<ens name> pre-fills the lookup, so a credential can be shared as a link. */
function nameFromUrl(): string {
  return new URLSearchParams(window.location.search).get('name')?.trim().toLowerCase() ?? ''
}

function Lookup({ parent }: { parent: string }) {
  const [input, setInput] = useState(nameFromUrl)
  const [name, setName] = useState<string | null>(() => nameFromUrl() || null)
  return (
    <section className="lookup">
      <h2>Check any tenant’s credential</h2>
      <form
        className="row"
        onSubmit={(e) => {
          e.preventDefault()
          const v = input.trim().toLowerCase()
          setName(v ? (v.includes('.') ? v : `${v}.${parent}`) : null)
        }}
      >
        <label className="sr-only" htmlFor="lookup-name">
          ENS name
        </label>
        <input
          id="lookup-name"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder={`name.${parent}`}
          autoComplete="off"
          spellCheck={false}
        />
        <button type="submit" className="btn">
          Look up
        </button>
      </form>
      {name ? <CredentialCard key={name} name={name} /> : null}
    </section>
  )
}

export function IdentityPanel() {
  const { address, isConnected } = useWallet()
  const parent = useParentName()
  const myName = useRentoutsName(address)

  if (!parent) return <p className="hint">Reading the RentOuts ENS registry…</p>

  return (
    <div className="stack">
      {!isConnected || !address ? (
        <div className="claim">
          <h2>Claim your tenant name</h2>
          <p className="lede">
            Connect MetaMask on Sepolia to claim a soulbound <strong>name.{parent}</strong> that carries your rental
            track record. You can look up existing credentials without a wallet.
          </p>
        </div>
      ) : myName.isPending ? (
        <p className="hint">Checking whether this wallet already has a name…</p>
      ) : myName.data ? (
        <div className="stack">
          <h2>Your credential</h2>
          <CredentialCard name={myName.data} />
        </div>
      ) : (
        <ClaimForm account={address} parent={parent} />
      )}
      <Lookup parent={parent} />
    </div>
  )
}
