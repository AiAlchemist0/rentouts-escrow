import { useState } from 'react'
import { isAddressEqual, type Address } from 'viem'
import { useReadContract } from 'wagmi'
import { sepolia } from 'wagmi/chains'
import { leaseShareAbi } from '../abi/leaseShare'
import { LeaseState, rentEscrowAbi } from '../abi/rentEscrow'
import { SyncButton } from '../components/CredentialCard'
import { AddressLink, Empty, NotConfigured, Notice, TxStatus } from '../components/ui'
import {
  useAiArbiter,
  useContracts,
  useLeases,
  useNow,
  useRentoutsNames,
  useTx,
  useWallet,
  type AiArbiterState,
  type LeaseRow,
} from '../hooks'
import { formatCountdown, formatDuration, formatToken } from '../lib/format'
import { STATE_LABELS, leaseTiming } from '../lib/lease'
import { AiJudgePanel } from './AiJudgePanel'

const same = (a: Address | undefined, b: Address | undefined) => !!a && !!b && isAddressEqual(a, b)

/** One segment per period: released, unlocked (claimable) or still ahead. */
function PeriodBar({ lease, elapsed }: { lease: LeaseRow; elapsed: number }) {
  return (
    <ol className="periods" aria-label={`${lease.periodsClaimed} of ${lease.periods} rent periods released`}>
      {Array.from({ length: Math.min(lease.periods, 48) }, (_, i) => {
        const kind = i < lease.periodsClaimed ? 'paid' : i < elapsed ? 'open' : 'ahead'
        return <li key={i} className={`period period-${kind}`} />
      })}
    </ol>
  )
}

/** Direct resolveDispute, for an escrow whose arbiter is a plain account (not the AI judge contract). */
function ResolveDispute({ lease }: { lease: LeaseRow }) {
  const { escrow } = useContracts()
  const [percent, setPercent] = useState(50)
  const tx = useTx()
  return (
    <div className="resolve">
      <label htmlFor={`bps-${lease.id}`}>
        Tenant gets <strong>{percent}%</strong> of the remaining escrow, the landlord {100 - percent}%
      </label>
      <input
        id={`bps-${lease.id}`}
        type="range"
        min={0}
        max={100}
        step={5}
        value={percent}
        onChange={(e) => setPercent(Number(e.target.value))}
      />
      <button
        type="button"
        className="btn btn-primary"
        disabled={tx.busy}
        onClick={() =>
          tx.run(
            { address: escrow!, abi: rentEscrowAbi, functionName: 'resolveDispute', args: [lease.id, percent * 100] },
            `Resolve dispute on lease #${lease.id} (${percent}% to tenant)`,
          )
        }
      >
        Resolve dispute
      </button>
      <TxStatus state={tx.state} done="Dispute resolved and escrow paid out." />
    </div>
  )
}

function ShareLine({ lease }: { lease: LeaseRow }) {
  const { leaseShare } = useContracts()
  const { data: held } = useReadContract({
    address: leaseShare,
    abi: leaseShareAbi,
    functionName: 'balanceOf',
    args: [lease.landlord, lease.id],
    chainId: sepolia.id,
    query: { enabled: !!leaseShare },
  })
  const { data: supply } = useReadContract({
    address: leaseShare,
    abi: leaseShareAbi,
    functionName: 'totalSupply',
    args: [lease.id],
    chainId: sepolia.id,
    query: { enabled: !!leaseShare },
  })
  if (!leaseShare || held === undefined || supply === undefined || supply === 0n) return null
  return (
    <p className="hint">
      Lease shares: the landlord holds {String(held)} of {String(supply)}. Transfer them under{' '}
      <a href="#shares">Lease shares</a>.
    </p>
  )
}

function LeaseCard({ lease, account, ai }: { lease: LeaseRow; account: Address | undefined; ai: AiArbiterState }) {
  const { escrow, arbiter, tokenDecimals, tokenSymbol } = useContracts()
  const nameOf = useRentoutsNames([lease.landlord, lease.tenant, ...(ai.info ? [ai.info.human] : [])])
  const now = useNow()
  const tx = useTx()
  const timing = leaseTiming(lease, now)
  const fmt = (v: bigint) => `${formatToken(v, tokenDecimals)} ${tokenSymbol}`

  const isLandlord = same(account, lease.landlord)
  const isTenant = same(account, lease.tenant)
  const isArbiter = same(account, arbiter)
  const isHuman = same(account, ai.info?.human)
  const active = lease.state === LeaseState.ACTIVE
  const verbs = { claimRent: 'Release rent on', closeLease: 'Close', openDispute: 'Open dispute on', cancelLease: 'Cancel' }
  const call = (functionName: keyof typeof verbs) =>
    tx.run({ address: escrow!, abi: rentEscrowAbi, functionName, args: [lease.id] }, `${verbs[functionName]} lease #${lease.id}`)

  const canClose = active && !!timing?.ended && (isLandlord || now >= timing.publicCloseAt)
  const role = isLandlord
    ? 'You’re the landlord'
    : isTenant
      ? 'You’re the tenant'
      : isHuman
        ? 'You’re the human arbiter'
        : isArbiter
          ? 'You’re the arbiter'
          : null

  let clock: string | null = null
  if (lease.state === LeaseState.CREATED) clock = 'Waiting for the tenant to fund it.'
  else if (active && timing?.nextUnlock) clock = `Next rent unlocks in ${formatCountdown(timing.nextUnlock - now)}.`
  else if (active && timing?.ended) {
    clock =
      now >= timing.publicCloseAt || isLandlord
        ? 'Term over. The lease can be closed.'
        : `Term over. The landlord can close it now; anyone can in ${formatCountdown(timing.publicCloseAt - now)}.`
  } else if (lease.state === LeaseState.DISPUTED) {
    clock = ai.info
      ? 'Frozen while the dispute is settled: the AI judge proposes, the human arbiter has the last word.'
      : 'Frozen until the escrow’s arbiter resolves the dispute.'
  }

  return (
    <li className={`lease lease-${STATE_LABELS[lease.state]?.toLowerCase().replace(/\s+/g, '-')}`}>
      <div className="lease-head">
        <h3>Lease #{String(lease.id)}</h3>
        <span className={`state state-${lease.state}`}>{STATE_LABELS[lease.state] ?? 'Unknown'}</span>
        {role ? <span className="role">{role}</span> : null}
      </div>

      <dl className="lease-grid">
        <div>
          <dt>Landlord</dt>
          <dd>
            <AddressLink address={lease.landlord} name={nameOf(lease.landlord)} />
          </dd>
        </div>
        <div>
          <dt>Tenant</dt>
          <dd>
            <AddressLink address={lease.tenant} name={nameOf(lease.tenant)} />
          </dd>
        </div>
        <div>
          <dt>Rent</dt>
          <dd>
            {fmt(lease.rentPerPeriod)} every {formatDuration(lease.periodSeconds)}
          </dd>
        </div>
        <div>
          <dt>Deposit</dt>
          <dd>{fmt(lease.deposit)}</dd>
        </div>
        <div>
          <dt>In escrow</dt>
          <dd>{fmt(lease.escrowBalance)}</dd>
        </div>
        <div>
          <dt>Claimable now</dt>
          <dd>
            {lease.claimablePeriods > 0 ? `${fmt(lease.claimableAmount)} (${lease.claimablePeriods} period${lease.claimablePeriods > 1 ? 's' : ''})` : '—'}
          </dd>
        </div>
      </dl>

      {timing ? (
        <div className="lease-progress">
          <PeriodBar lease={lease} elapsed={timing.elapsed} />
          <p className="hint">
            {lease.periodsClaimed} of {lease.periods} period{lease.periods === 1 ? '' : 's'} released to the landlord.
          </p>
        </div>
      ) : null}
      {clock ? <p className="clock">{clock}</p> : null}

      <div className="actions">
        {active ? (
          <button type="button" className="btn" disabled={tx.busy || lease.claimablePeriods === 0} onClick={() => call('claimRent')}>
            {lease.claimablePeriods > 0 ? `Release ${fmt(lease.claimableAmount)} rent` : 'Release rent'}
          </button>
        ) : null}
        {active ? (
          <button type="button" className="btn" disabled={tx.busy || !canClose} onClick={() => call('closeLease')}>
            Close lease
          </button>
        ) : null}
        {active && (isLandlord || isTenant) ? (
          <button type="button" className="btn btn-danger" disabled={tx.busy} onClick={() => call('openDispute')}>
            Open dispute
          </button>
        ) : null}
        {lease.state === LeaseState.CREATED && isLandlord ? (
          <button type="button" className="btn" disabled={tx.busy} onClick={() => call('cancelLease')}>
            Cancel lease
          </button>
        ) : null}
        {lease.state === LeaseState.CREATED && isTenant ? (
          <a className="btn btn-primary" href="#fund">
            Fund this lease
          </a>
        ) : null}
      </div>
      <TxStatus state={tx.state} />

      {ai.info && (lease.state === LeaseState.DISPUTED || lease.state === LeaseState.CLOSED) ? (
        <AiJudgePanel lease={lease} account={account} info={ai.info} problem={ai.problem} now={now} nameOf={nameOf} />
      ) : null}
      {/* A contract arbiter never connects a wallet, so this is only for a plain-account arbiter. */}
      {lease.state === LeaseState.DISPUTED && isArbiter ? <ResolveDispute lease={lease} /> : null}
      {lease.state === LeaseState.DISPUTED && !ai.info && !isArbiter && arbiter ? (
        <p className="hint">
          Arbiter: <AddressLink address={arbiter} />. It settles the dispute with a split of the remaining escrow.
        </p>
      ) : null}

      {lease.state === LeaseState.CLOSED ? (
        <div className="lease-sync">
          <p className="hint">Closed leases count toward the tenant’s ENS credential once it’s synced.</p>
          <SyncButton tenant={lease.tenant} label="Sync tenant’s credential to ENS" />
        </div>
      ) : null}

      <ShareLine lease={lease} />
    </li>
  )
}

export function LeasesPanel() {
  const { escrow, arbiter, escrowError } = useContracts()
  const ai = useAiArbiter()
  const { address } = useWallet()
  const leases = useLeases(escrow)
  const [showAll, setShowAll] = useState(false)

  const all = leases.data ?? []
  const isArbiter = same(address, arbiter) || same(address, ai.info?.human)
  const mine = all.filter((l) => same(address, l.landlord) || same(address, l.tenant))
  // A dispute the arbiter has seen stays listed after it closes, so its ruling doesn't vanish on success.
  const [seenDisputes, setSeenDisputes] = useState<ReadonlySet<bigint>>(new Set())
  const disputed = all.filter((l) => l.state === LeaseState.DISPUTED)
  if (isArbiter && disputed.some((l) => !seenDisputes.has(l.id))) {
    setSeenDisputes(new Set([...seenDisputes, ...disputed.map((l) => l.id)]))
  }
  const arbiterView = all.filter((l) => l.state === LeaseState.DISPUTED || seenDisputes.has(l.id))
  const visible = showAll || !address ? all : isArbiter ? arbiterView.concat(mine.filter((l) => !arbiterView.includes(l))) : mine

  return (
    <div className="stack">
      <div>
        <h2>Run the lease</h2>
        <p className="lede">
          Rent unlocks period by period and anyone can release it; it can only go to the landlord. After the term the
          lease closes: remaining rent to the landlord, deposit back to the tenant. Either side can freeze it instead
          and take it to the AI judge contract, where a human arbiter has the last word.
        </p>
      </div>
      {escrowError ? <Notice tone="error">{escrowError}</Notice> : null}
      {ai.error ? <Notice tone="error">{ai.error}</Notice> : null}
      {!escrow ? (
        <NotConfigured what="The escrow" envVar="VITE_ESCROW_ADDRESS" />
      ) : leases.isPending ? (
        <p className="hint">Reading leases from the escrow…</p>
      ) : leases.isError ? (
        <Notice tone="error">Couldn’t read leases. {leases.error.message}</Notice>
      ) : (
        <>
          {address ? (
            <div className="filter" role="group" aria-label="Which leases">
              <button type="button" className={`chip${!showAll ? ' chip-on' : ''}`} aria-pressed={!showAll} onClick={() => setShowAll(false)}>
                {isArbiter ? 'Disputes and mine' : 'Mine'}
              </button>
              <button type="button" className={`chip${showAll ? ' chip-on' : ''}`} aria-pressed={showAll} onClick={() => setShowAll(true)}>
                All leases ({all.length})
              </button>
            </div>
          ) : null}
          {visible.length === 0 ? (
            <Empty title={all.length === 0 ? 'No leases yet' : 'None of these leases involve your wallet'}>
              <p>
                {all.length === 0 ? (
                  <>
                    Start one under <a href="#create">Create a lease</a>.
                  </>
                ) : (
                  <>Switch to “All leases” to see everyone’s, or create one under <a href="#create">Create a lease</a>.</>
                )}
              </p>
            </Empty>
          ) : (
            <ul className="list">
              {visible.map((lease) => (
                <LeaseCard key={String(lease.id)} lease={lease} account={address} ai={ai} />
              ))}
            </ul>
          )}
        </>
      )}
    </div>
  )
}
