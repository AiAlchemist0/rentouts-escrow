import { useState, type FormEvent } from 'react'
import { parseEventLogs } from 'viem'
import { useReadContract } from 'wagmi'
import { sepolia } from 'wagmi/chains'
import { leaseShareAbi } from '../abi/leaseShare'
import { rentEscrowAbi } from '../abi/rentEscrow'
import { CredentialCard } from '../components/CredentialCard'
import { AddressLink, Field, Notice, NotConfigured, TxStatus } from '../components/ui'
import { LEASE_DEFAULTS } from '../config'
import { useAddressInput, useContracts, useParentName, useRentoutsNames, useTx, useWallet, type ResolvedInput } from '../hooks'
import { formatDuration, formatToken, parseToken, parseWhole } from '../lib/format'
import { leasePartyProblem, totalDue } from '../lib/lease'

const UINT16_MAX = 65_535
const UINT32_MAX = 4_294_967_295

function TenantResolution({ resolved }: { resolved: ResolvedInput }) {
  const nameOf = useRentoutsNames(resolved.kind === 'address' ? [resolved.address] : [])
  switch (resolved.kind) {
    case 'empty':
    case 'pending':
      return null
    case 'loading':
      return <p className="status status-hint">Resolving {resolved.name} through the ENS Universal Resolver…</p>
    case 'error':
      return <p className="status status-bad">{resolved.message}</p>
    case 'address': {
      const name = nameOf(resolved.address)
      return (
        <div className="stack-s">
          <p className="status status-hint">
            {name ? <>This address holds {name}.</> : 'This address has no RentOuts name.'}
          </p>
          {name ? <CredentialCard name={name} compact /> : null}
        </div>
      )
    }
    case 'name':
      return (
        <div className="stack-s">
          <p className="status status-ok">
            {resolved.name} resolves to <AddressLink address={resolved.address} />.
          </p>
          <CredentialCard name={resolved.name} compact />
        </div>
      )
  }
}

export function CreateLeasePanel() {
  const { escrow, leaseShare, arbiter, minPeriod, tokenDecimals, tokenSymbol, tokenMetaReady, tokenError, escrowError } = useContracts()
  const { address, ready } = useWallet()
  const parent = useParentName()
  const [tenantInput, setTenantInput] = useState('')
  const [deposit, setDeposit] = useState<string>(LEASE_DEFAULTS.deposit)
  const [rent, setRent] = useState<string>(LEASE_DEFAULTS.rentPerPeriod)
  const [period, setPeriod] = useState<string>(LEASE_DEFAULTS.periodSeconds)
  const [periods, setPeriods] = useState<string>(LEASE_DEFAULTS.periods)
  const [createdId, setCreatedId] = useState<bigint | null>(null)
  const tx = useTx()

  const resolved = useAddressInput(tenantInput)
  const tenant = resolved.kind === 'name' || resolved.kind === 'address' ? resolved.address : undefined

  const { data: landlordAllowlisted } = useReadContract({
    address: leaseShare,
    abi: leaseShareAbi,
    functionName: 'allowlisted',
    args: address ? [address] : undefined,
    chainId: sepolia.id,
    query: { enabled: !!leaseShare && !!address },
  })

  const depositUnits = parseToken(deposit, tokenDecimals)
  const rentUnits = parseToken(rent, tokenDecimals)
  const periodSeconds = parseWhole(period, UINT32_MAX)
  const periodCount = parseWhole(periods, UINT16_MAX)
  const tooShort = periodSeconds !== null && minPeriod !== undefined && periodSeconds < minPeriod
  const partyError = leasePartyProblem(address, tenant, arbiter)

  const termsValid =
    depositUnits !== null && rentUnits !== null && rentUnits > 0n && periodSeconds !== null && periodCount !== null && !tooShort
  // Amounts are parsed with tokenDecimals, so never before the escrow's token has been read.
  const canSubmit = !!escrow && ready && tokenMetaReady && !!tenant && termsValid && !partyError && !tx.busy

  async function onSubmit(event: FormEvent) {
    event.preventDefault()
    if (!canSubmit || !escrow || !tenant || depositUnits === null || rentUnits === null) return
    setCreatedId(null)
    const receipt = await tx.run({
      address: escrow,
      abi: rentEscrowAbi,
      functionName: 'createLease',
      args: [tenant, depositUnits, rentUnits, periodSeconds!, periodCount!],
    }, `Create lease for ${resolved.kind === 'name' ? resolved.name : tenant}`)
    if (receipt) {
      const [created] = parseEventLogs({ abi: rentEscrowAbi, eventName: 'LeaseCreated', logs: receipt.logs })
      setCreatedId(created?.args.leaseId ?? null)
    }
  }

  return (
    <form className="stack" onSubmit={onSubmit}>
      <div>
        <h2>Create a lease</h2>
        <p className="lede">
          The landlord proposes terms to a tenant, named by their ENS name. The tenant then prepays the deposit and every
          period’s rent into the escrow.
        </p>
      </div>

      {escrowError ? <Notice tone="error">{escrowError}</Notice> : null}
      {tokenError ? <Notice tone="error">{tokenError}</Notice> : null}

      <Field
        label="Tenant"
        htmlFor="tenant"
        hint="An ENS name or a 0x address. Names resolve through the ENSv2 Universal Resolver."
      >
        <input
          id="tenant"
          value={tenantInput}
          onChange={(e) => setTenantInput(e.target.value)}
          placeholder={parent ? `name.${parent}` : 'name.eth'}
          autoComplete="off"
          spellCheck={false}
        />
      </Field>
      <TenantResolution resolved={resolved} />
      {partyError ? <p className="status status-bad">{partyError}</p> : null}

      <div className="grid-2">
        <Field label={`Deposit (${tokenSymbol})`} htmlFor="deposit">
          <input id="deposit" inputMode="decimal" value={deposit} onChange={(e) => setDeposit(e.target.value)} />
        </Field>
        <Field label={`Rent per period (${tokenSymbol})`} htmlFor="rent">
          <input id="rent" inputMode="decimal" value={rent} onChange={(e) => setRent(e.target.value)} />
        </Field>
        <Field
          label="Period length (seconds)"
          htmlFor="period"
          hint={minPeriod !== undefined ? `Minimum ${minPeriod} s. Short periods keep the demo live.` : 'Short periods keep the demo live.'}
        >
          <input id="period" inputMode="numeric" value={period} onChange={(e) => setPeriod(e.target.value)} />
        </Field>
        <Field label="Number of periods" htmlFor="periods">
          <input id="periods" inputMode="numeric" value={periods} onChange={(e) => setPeriods(e.target.value)} />
        </Field>
      </div>

      {termsValid ? (
        <p className="summary">
          The tenant prepays <strong>{formatToken(totalDue(depositUnits!, rentUnits!, periodCount!), tokenDecimals)} {tokenSymbol}</strong>:
          a {formatToken(depositUnits!, tokenDecimals)} deposit plus {periodCount} × {formatToken(rentUnits!, tokenDecimals)} rent.
          Rent unlocks to you every {formatDuration(periodSeconds!)}, and the deposit goes back to the tenant after{' '}
          {formatDuration(periodSeconds! * periodCount!)}.
        </p>
      ) : (
        <p className="status status-bad">
          {tooShort
            ? `Periods must be at least ${minPeriod} seconds.`
            : `Enter amounts in ${tokenSymbol} (up to ${tokenDecimals} decimals, rent above zero) and whole numbers for the period and count.`}
        </p>
      )}

      {escrow && leaseShare && address && landlordAllowlisted === false ? (
        <Notice tone="warn">
          Your wallet isn’t on the lease-share compliance allowlist. Creating a lease mints its shares to the landlord,
          so the transaction will fail until the LeaseShare1155 owner allowlists you.
        </Notice>
      ) : null}

      {!escrow ? (
        <NotConfigured what="The escrow" envVar="VITE_ESCROW_ADDRESS">
          ENS resolution above already works.
        </NotConfigured>
      ) : (
        <div className="actions">
          <button type="submit" className="btn btn-primary" disabled={!canSubmit}>
            Create lease
          </button>
          {!ready ? (
            <span className="hint">Connect MetaMask on Sepolia to create a lease.</span>
          ) : !tokenMetaReady && !tokenError ? (
            <span className="hint">Reading the escrow’s token…</span>
          ) : null}
        </div>
      )}
      <TxStatus state={tx.state} done={createdId !== null ? `Lease #${createdId} created.` : 'Lease created.'} />
      {createdId !== null ? (
        <p className="hint">
          Next: the tenant funds it in <a href="#fund">Fund the lease</a>.
        </p>
      ) : null}
    </form>
  )
}
