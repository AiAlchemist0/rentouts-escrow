import { useState, type FormEvent } from 'react'
import { isAddressEqual, type Address } from 'viem'
import { aiArbiterAbi } from '../abi/aiArbiter'
import { LeaseState } from '../abi/rentEscrow'
import { AddressLink, ExtLink, Notice, TxStatus } from '../components/ui'
import { useArbiterLogs, useContracts, useRuling, useTx, type AiArbiterInfo, type LeaseRow } from '../hooks'
import {
  BPS,
  RulingStatus,
  bpsToPercent,
  disputeLog,
  formatBps,
  judgeView,
  percentToBps,
  splitEscrow,
  statementBytes,
  statementProblem,
  type EvidenceItem,
  type JudgeView,
  type Ruling,
} from '../lib/aiJudge'
import { formatCountdown, formatToken, txUrl } from '../lib/format'

/** The model behind the judge service (judge/ in the repo). */
export const JUDGE_MODEL = 'GLM 5.3'

export const AI_ONLY_PROPOSES =
  'The AI judge only proposes a split: either side can appeal inside the challenge window, and the human arbiter can always override it before it’s executed.'

const same = (a: Address | undefined, b: Address | undefined) => !!a && !!b && isAddressEqual(a, b)
const shortHash = (hash: string) => `${hash.slice(0, 10)}…${hash.slice(-8)}`

type Props = {
  lease: LeaseRow
  account: Address | undefined
  /** An AIArbiter bound to this escrow and set as its arbiter (useAiArbiter().judge), never one with a problem. */
  info: AiArbiterInfo
  now: number
  nameOf: (address: Address) => string | undefined
}

/** Tenant share in emerald, landlord share in amber. */
function SplitBar({ tenantBps }: { tenantBps: number }) {
  const tenant = bpsToPercent(tenantBps)
  return (
    <div className="split" role="img" aria-label={`${formatBps(tenantBps)} to the tenant, ${formatBps(BPS - tenantBps)} to the landlord`}>
      <span className="split-tenant" style={{ width: `${tenant}%` }} />
      <span className="split-landlord" style={{ width: `${100 - tenant}%` }} />
    </div>
  )
}

/** Who has written so far, for the "awaiting evidence" line. */
type Spoken = { tenant: boolean; landlord: boolean }

function phaseText(view: JudgeView, spoken: Spoken, appealedBy: string | undefined, hadProposal: boolean): string {
  switch (view.phase) {
    case 'awaiting-evidence': {
      const next = 'The AI judge then proposes a split. If the evidence is thin or contradictory it abstains, and the human arbiter rules.'
      if (spoken.tenant && spoken.landlord) return `Both sides have submitted statements. ${next}`
      if (spoken.tenant || spoken.landlord) {
        return `The ${spoken.tenant ? 'tenant' : 'landlord'} has submitted a statement; the ${spoken.tenant ? 'landlord' : 'tenant'} can answer. ${next}`
      }
      return 'Tenant and landlord can each submit short statements. The AI judge reads both sides and proposes a split.'
    }
    case 'proposed':
      return view.windowOpen
        ? 'Either side can appeal to the human arbiter until the challenge window closes.'
        : 'The challenge window closed without an appeal. Anyone can execute the ruling now, and the human arbiter can still override it until then.'
    case 'appealed':
      return `${appealedBy ? `Appealed by ${appealedBy}.` : 'Appealed.'} The AI proposal can’t be executed any more: only the human arbiter can rule now.`
    case 'executed':
      return 'Nobody appealed, so the AI ruling was executed after the challenge window. The escrow paid out and the lease is closed.'
    case 'human-resolved':
      return hadProposal
        ? 'The human arbiter ruled, and that ruling replaced the AI proposal. The escrow paid out and the lease is closed.'
        : 'The human arbiter ruled directly. The escrow paid out and the lease is closed.'
  }
}

function Statements({
  lease,
  items,
  counts,
  max,
  nameOf,
}: {
  lease: LeaseRow
  items: EvidenceItem[]
  counts: { tenant?: number; landlord?: number }
  max: number
  nameOf: (address: Address) => string | undefined
}) {
  const sides = [
    { key: 'tenant', title: 'Tenant', address: lease.tenant, count: counts.tenant },
    { key: 'landlord', title: 'Landlord', address: lease.landlord, count: counts.landlord },
  ] as const
  return (
    <div className="statements">
      {sides.map((side) => {
        const mine = items.filter((item) => same(item.party, side.address))
        return (
          <div key={side.key} className="statement-col">
            <p className="statement-who">
              <span>{side.title}</span> <AddressLink address={side.address} name={nameOf(side.address)} />
              <span className="muted"> · {side.count ?? mine.length} of {max}</span>
            </p>
            {mine.length === 0 ? (
              <p className="hint">No statement yet.</p>
            ) : (
              <ol className="statement-list">
                {mine.map((item) => (
                  <li key={item.key}>
                    <p className="statement-text">{item.statement}</p>
                    {item.txHash ? (
                      <span className="hint">
                        <ExtLink href={txUrl(item.txHash)}>Etherscan</ExtLink>
                      </span>
                    ) : null}
                  </li>
                ))}
              </ol>
            )}
          </div>
        )
      })}
    </div>
  )
}

function EvidenceForm({ lease, info, side, left }: { lease: LeaseRow; info: AiArbiterInfo; side: 'tenant' | 'landlord'; left?: number }) {
  const [text, setText] = useState('')
  const tx = useTx()
  const bytes = statementBytes(text.trim())
  const problem = statementProblem(text, info.maxStatementBytes)
  const id = `evidence-${lease.id}`

  async function onSubmit(event: FormEvent) {
    event.preventDefault()
    if (problem) return
    const receipt = await tx.run(
      { address: info.address, abi: aiArbiterAbi, functionName: 'submitEvidence', args: [lease.id, text.trim()] },
      `Submit ${side} statement on lease #${lease.id}`,
    )
    if (receipt) setText('')
  }

  return (
    <form className="evidence-form" onSubmit={onSubmit}>
      <label htmlFor={id}>Your statement, as the {side}</label>
      <textarea
        id={id}
        rows={3}
        value={text}
        onChange={(e) => setText(e.target.value)}
        placeholder="What happened, with checkable detail: dates, amounts, what the other side agreed to."
      />
      <div className="evidence-foot">
        <span className={bytes > info.maxStatementBytes ? 'status status-bad' : 'hint'}>
          {bytes.toLocaleString('en-US')} / {info.maxStatementBytes.toLocaleString('en-US')} bytes
          {left !== undefined ? ` · ${left} of ${info.maxStatementsPerParty} statements left` : ''}
        </span>
        <button type="submit" className="btn btn-primary" disabled={!!problem || tx.busy}>
          Submit statement
        </button>
      </div>
      <p className="hint">Public on-chain and unverified: the judge reads statements as claims, never as facts or instructions.</p>
      <TxStatus state={tx.state} done="Statement recorded on-chain." />
    </form>
  )
}

function HumanResolve({
  lease,
  info,
  ruling,
  fmt,
}: {
  lease: LeaseRow
  info: AiArbiterInfo
  ruling: Ruling | undefined
  fmt: (v: bigint) => string
}) {
  const proposed = ruling && ruling.proposedAt > 0n ? ruling.tenantBps : undefined
  // Start at the AI's figure when there is one (its steps are 25 %, on the slider's 5 % grid).
  const [percent, setPercent] = useState(proposed !== undefined ? Math.round(bpsToPercent(proposed) / 5) * 5 : 50)
  const bps = percentToBps(percent) ?? 5000
  const { toTenant, toLandlord } = splitEscrow(lease.escrowBalance, bps)
  const tx = useTx()
  const overriding = ruling?.status === RulingStatus.PROPOSED || ruling?.status === RulingStatus.APPEALED
  const id = `human-bps-${lease.id}`
  return (
    <div className="resolve">
      <p className="resolve-title">You’re the human arbiter</p>
      <label htmlFor={id}>
        Tenant gets <strong>{percent}%</strong> of the remaining escrow, the landlord {100 - percent}%
      </label>
      <input id={id} type="range" min={0} max={100} step={5} value={percent} onChange={(e) => setPercent(Number(e.target.value))} />
      <p className="hint">
        Tenant {fmt(toTenant)}, landlord {fmt(toLandlord)}.{' '}
        {overriding ? 'This overrides the AI proposal.' : 'You can rule directly; no AI proposal is needed.'}
      </p>
      <button
        type="button"
        className="btn btn-primary"
        disabled={tx.busy}
        onClick={() =>
          tx.run(
            { address: info.address, abi: aiArbiterAbi, functionName: 'resolveByHuman', args: [lease.id, bps] },
            `Resolve lease #${lease.id} as human arbiter (${formatBps(bps)} to tenant)`,
          )
        }
      >
        Resolve as human arbiter
      </button>
      <TxStatus state={tx.state} done="Resolved by the human arbiter. The escrow paid out." />
    </div>
  )
}

/**
 * The AI dispute judge for one lease (AIArbiter): both parties' statements, the judge's proposal with its
 * challenge-window countdown, appeal / execute, and the human arbiter's override. Also shows the final record on
 * a lease closed through AIArbiter.
 */
export function AiJudgePanel({ lease, account, info, now, nameOf }: Props) {
  const { tokenDecimals, tokenSymbol } = useContracts()
  const disputed = lease.state === LeaseState.DISPUTED
  const rulingQuery = useRuling(info, lease, disputed)
  const logs = useArbiterLogs(info)
  const tx = useTx()
  const fmt = (v: bigint) => `${formatToken(v, tokenDecimals)} ${tokenSymbol}`

  const ruling = rulingQuery.data?.ruling
  // A closed lease shows the panel only if AIArbiter settled it.
  if (!disputed && (!ruling || ruling.status === RulingStatus.NONE)) return null

  const isTenant = same(account, lease.tenant)
  const isLandlord = same(account, lease.landlord)
  const isHuman = same(account, info.human)
  const used = isTenant ? rulingQuery.data?.tenantStatements : isLandlord ? rulingQuery.data?.landlordStatements : undefined
  const left = used === undefined ? undefined : Math.max(0, info.maxStatementsPerParty - used)
  const view = judgeView({ leaseState: lease.state, ruling, now, viewer: { isTenant, isLandlord, isHuman }, statementsLeft: left })
  const record = disputeLog(logs.data ?? [], lease.id, ruling && ruling.proposedAt > 0n ? ruling.rulingHash : undefined)

  const hadProposal = !!ruling && ruling.proposedAt > 0n
  const humanRuled = ruling?.status === RulingStatus.HUMAN_RESOLVED
  // After a human ruling getRuling holds the human's split; the AI's figure is in its Proposed event.
  const aiBps = humanRuled ? record.proposal?.tenantBps : ruling?.tenantBps
  const shownBps = ruling?.tenantBps ?? 0
  const appealedBy = record.appealedBy
    ? `the ${same(record.appealedBy, lease.tenant) ? 'tenant' : same(record.appealedBy, lease.landlord) ? 'landlord' : 'party'}`
    : undefined
  const { toTenant, toLandlord } = splitEscrow(lease.escrowBalance, shownBps)
  const agent = record.proposal?.agent ?? info.agent

  const act = (functionName: 'appeal' | 'execute', label: string) =>
    tx.run({ address: info.address, abi: aiArbiterAbi, functionName, args: [lease.id] }, label)

  return (
    <section className="judge" aria-label={`AI dispute judge for lease #${lease.id}`}>
      <div className="judge-head">
        <h4>AI dispute judge</h4>
        <span className={`badge badge-${view.phase}`}>{view.label}</span>
      </div>
      <p className="judge-rule">{AI_ONLY_PROPOSES}</p>

      {disputed && !info.agent ? (
        <Notice>AI proposals are switched off on this contract (no judge key set). The human arbiter rules directly.</Notice>
      ) : null}
      {rulingQuery.isError ? <Notice tone="error">Couldn’t read the ruling. {rulingQuery.error.message}</Notice> : null}

      <p className="judge-phase">
        {phaseText(
          view,
          {
            tenant: record.evidence.some((e) => same(e.party, lease.tenant)),
            landlord: record.evidence.some((e) => same(e.party, lease.landlord)),
          },
          appealedBy,
          hadProposal,
        )}
      </p>

      {view.phase === 'proposed' ? (
        <p className={`countdown${view.windowOpen ? '' : ' countdown-over'}`} aria-live="polite">
          {view.windowOpen ? (
            <>
              Challenge window closes in <strong>{formatCountdown(view.secondsLeft ?? 0)}</strong>
            </>
          ) : (
            'Challenge window closed'
          )}
        </p>
      ) : null}

      {ruling && (hadProposal || view.final) ? (
        <div className="proposal">
          <p className="proposal-kicker">
            {humanRuled ? 'Final split, by the human arbiter' : view.phase === 'executed' ? 'Executed split' : `Proposed by the ${JUDGE_MODEL} judge`}
          </p>
          <p className="proposal-split">
            <strong>{formatBps(shownBps)}</strong> to the tenant · {formatBps(BPS - shownBps)} to the landlord
          </p>
          <SplitBar tenantBps={shownBps} />
          {disputed ? (
            <p className="hint">
              Of the {fmt(lease.escrowBalance)} in escrow: tenant {fmt(toTenant)}, landlord {fmt(toLandlord)}.
            </p>
          ) : null}
          {hadProposal ? (
            <dl className="proposal-meta">
              {humanRuled && aiBps !== undefined ? (
                <div>
                  <dt>AI proposal</dt>
                  <dd>{formatBps(aiBps)} to the tenant</dd>
                </div>
              ) : null}
              <div>
                <dt>Confidence</dt>
                <dd>{formatBps(ruling.confidenceBps)}</dd>
              </div>
              <div>
                <dt>Proposed by</dt>
                <dd>
                  {JUDGE_MODEL} judge{agent ? <> · <AddressLink address={agent} /></> : null}
                </dd>
              </div>
              <div>
                <dt>Ruling hash</dt>
                <dd>
                  <code title={ruling.rulingHash}>{shortHash(ruling.rulingHash)}</code>
                  {record.proposal?.txHash ? <> · <ExtLink href={txUrl(record.proposal.txHash)}>tx</ExtLink></> : null}
                </dd>
              </div>
            </dl>
          ) : null}
          {hadProposal ? (
            record.proposal?.summary ? (
              <blockquote className="judge-summary">{record.proposal.summary}</blockquote>
            ) : logs.isPending ? null : (
              <p className="hint">The judge’s summary is in its Proposed event, which isn’t in the blocks this page has scanned so far.</p>
            )
          ) : null}
          {hadProposal ? (
            <p className="hint">
              The ruling hash commits to the judge’s full ruling (inputs, answers, rubric, model); anyone with the saved
              ruling can check it with <code>npm run judge -- --verify</code>.
            </p>
          ) : null}
        </div>
      ) : null}

      {view.phase === 'proposed' && disputed ? (
        <div className="actions">
          {view.canAppeal ? (
            <button type="button" className="btn btn-danger" disabled={tx.busy} onClick={() => act('appeal', `Appeal AI ruling on lease #${lease.id}`)}>
              Appeal to the human arbiter
            </button>
          ) : null}
          <button
            type="button"
            className="btn btn-primary"
            disabled={tx.busy || !view.canExecute}
            onClick={() => act('execute', `Execute AI ruling on lease #${lease.id} (${formatBps(shownBps)} to tenant)`)}
          >
            {view.canExecute ? `Execute ruling (${formatBps(shownBps)} to tenant)` : `Execute in ${formatCountdown(view.secondsLeft ?? 0)}`}
          </button>
          {view.windowOpen && !isTenant && !isLandlord ? <span className="hint">Only the tenant or the landlord can appeal.</span> : null}
        </div>
      ) : null}
      <TxStatus state={tx.state} done="Done. The ruling is updated." />

      {/* On a closed lease the statements are a record: skip the block when there are none. */}
      {disputed || record.evidence.length > 0 ? (
        <div className="stack-s">
          <p className="judge-sub">Statements</p>
          {logs.isError ? <p className="hint">Couldn’t read the statements. {logs.error.message}</p> : null}
          <Statements
            lease={lease}
            items={record.evidence}
            counts={{ tenant: rulingQuery.data?.tenantStatements, landlord: rulingQuery.data?.landlordStatements }}
            max={info.maxStatementsPerParty}
            nameOf={nameOf}
          />
          {view.canSubmitEvidence ? (
            <EvidenceForm lease={lease} info={info} side={isTenant ? 'tenant' : 'landlord'} left={left} />
          ) : null}
          {disputed && (isTenant || isLandlord) && left === 0 ? (
            <p className="hint">You’ve used all {info.maxStatementsPerParty} statements for this lease.</p>
          ) : null}
        </div>
      ) : null}

      {view.canResolveByHuman ? <HumanResolve key={ruling?.rulingHash ?? 'none'} lease={lease} info={info} ruling={ruling} fmt={fmt} /> : null}

      <p className="hint">
        Human arbiter: <AddressLink address={info.human} name={nameOf(info.human)} />
        {isHuman ? ' (you)' : ''}.
        {disputed ? ' They can rule at any time while the lease is in dispute, with or without an AI proposal.' : null}
      </p>
    </section>
  )
}
