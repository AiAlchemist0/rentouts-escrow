import type { Address } from 'viem'
import { useReadContract } from 'wagmi'
import { sepolia } from 'wagmi/chains'
import { credentialSyncAbi } from '../abi/credentialSync'
import { rentEscrowAbi } from '../abi/rentEscrow'
import { ENS, type CredentialKey } from '../config'
import { useClaimTx, useContracts, useCredential, useTx } from '../hooks'
import { evaluateCredential, formatRecord, staleCredentialKeys } from '../lib/credential'
import { errorMessage } from '../lib/errors'
import { addressUrl, ensAppUrl, formatToken, shortAddress, txUrl } from '../lib/format'
import { AddressLink, ExtLink, Notice, TxStatus } from './ui'

const STATS: { key: CredentialKey; label: string }[] = [
  { key: 'rentouts.leasesCompleted', label: 'Leases completed' },
  { key: 'rentouts.disputes', label: 'Disputes' },
  { key: 'rentouts.rentPaid', label: 'Rent paid' },
  { key: 'rentouts.depositReturnRate', label: 'Deposit returned' },
  { key: 'rentouts.rating', label: 'Rating' },
]

/** Permissionless CredentialSync.sync(tenant): rewrites the tenant's rentouts.* records from escrow stats. */
export function SyncButton({ tenant, label = 'Sync credential to ENS' }: { tenant: Address; label?: string }) {
  const { credentialSync } = useContracts()
  const tx = useTx()
  if (!credentialSync) {
    return <p className="hint">Credential sync isn’t configured (VITE_CREDENTIAL_SYNC_ADDRESS).</p>
  }
  return (
    <div className="sync">
      <button
        type="button"
        className="btn"
        disabled={tx.busy}
        onClick={() =>
          tx.run(
            { address: credentialSync, abi: credentialSyncAbi, functionName: 'sync', args: [tenant] },
            `Sync ENS credential for ${shortAddress(tenant)}`,
          )
        }
      >
        {label}
      </button>
      <TxStatus state={tx.state} done="Credential synced. The card now shows the new ENS records." />
    </div>
  )
}

/** Compares what ENS says with what the escrow says, and offers a sync when they differ. */
function EscrowComparison({ holder, records }: { holder: Address; records: Record<CredentialKey, string | null> }) {
  const { escrow, tokenDecimals, tokenSymbol } = useContracts()
  const { data: stats } = useReadContract({
    address: escrow,
    abi: rentEscrowAbi,
    functionName: 'tenantStats',
    args: [holder],
    chainId: sepolia.id,
    query: { enabled: !!escrow },
  })
  if (!escrow || !stats) return null
  // Every record CredentialSync writes: a rent claim or a dispute resolution changes only rentPaid / the deposit rate.
  const behind = staleCredentialKeys(records, stats).length > 0
  return (
    <div className="pass-escrow">
      <p>
        Escrow record right now: {stats.leasesCompleted} completed, {stats.leasesDisputed} disputed,{' '}
        {formatToken(stats.rentPaid, tokenDecimals)} {tokenSymbol} rent paid.
        {behind ? ' ENS hasn’t caught up yet.' : ' ENS is up to date.'}
      </p>
      {behind ? <SyncButton tenant={holder} /> : null}
    </div>
  )
}

export function CredentialCard({ name, compact = false }: { name: string; compact?: boolean }) {
  const credential = useCredential(name)
  const claimTx = useClaimTx(credential.data?.expectedHolder ?? undefined)

  if (credential.isPending) {
    return (
      <article className="pass pass-loading" aria-busy="true">
        <p className="pass-kind">Reading {name} through the ENS Universal Resolver…</p>
      </article>
    )
  }
  if (credential.isError) {
    return <Notice tone="error">Couldn’t read {name} from ENS. {errorMessage(credential.error)}</Notice>
  }

  const { address, records, expectedHolder } = credential.data
  const trust = evaluateCredential({ address, status: records['rentouts.status'], expectedHolder })
  const status = records['rentouts.status']

  return (
    <article className={`pass${trust.verified ? ' pass-verified' : ''}${compact ? ' pass-compact' : ''}`}>
      <div className="pass-top">
        <span className="pass-kind">RentOuts tenant credential on ENS</span>
        <span className={`seal ${trust.verified ? 'seal-ok' : 'seal-warn'}`}>
          {trust.verified ? 'Verified on-chain' : status === 'revoked' ? 'Revoked' : 'Not verified'}
        </span>
      </div>

      <h3 className="pass-name">{credential.data.name}</h3>
      <p className="pass-addr">
        {address ? (
          <>
            Resolves to <AddressLink address={address} />
            {records['rentouts.credential'] ? <> with credential {records['rentouts.credential']}</> : null}
          </>
        ) : (
          'Doesn’t resolve to an address.'
        )}
      </p>

      {trust.verified ? (
        <>
          <dl className="pass-stats">
            {STATS.map(({ key, label }) => (
              <div key={key} className="stat">
                <dt>{label}</dt>
                <dd>{formatRecord(key, records[key])}</dd>
              </div>
            ))}
          </dl>
          {STATS.every(({ key }) => !records[key]) ? (
            <p className="hint">No lease history on this credential yet. It fills in when a finished lease is synced.</p>
          ) : null}
        </>
      ) : (
        <p className="pass-reason">{trust.reason} Its rentouts.* records are hidden.</p>
      )}

      {!compact && trust.verified && address ? <EscrowComparison holder={address} records={records} /> : null}

      {!compact ? (
        <p className="pass-links">
          <ExtLink href={ensAppUrl(credential.data.name)}>Open in the ENS app</ExtLink>
          {claimTx.data ? <ExtLink href={txUrl(claimTx.data)}>Claim transaction</ExtLink> : null}
          <ExtLink href={addressUrl(ENS.resolver)}>Resolver contract</ExtLink>
        </p>
      ) : null}
      {!compact ? (
        <p className="hint">
          Read live through the ENSv2 Universal Resolver. The ENS app may not display ENSv2 beta names yet; Etherscan
          always shows the transactions.
        </p>
      ) : null}
    </article>
  )
}
