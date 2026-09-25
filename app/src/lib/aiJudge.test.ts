import { describe, expect, it } from 'vitest'
import { LeaseState } from '../abi/rentEscrow'
import {
  RulingStatus,
  aiArbiterProblem,
  bpsToPercent,
  disputeLog,
  formatBps,
  judgeView,
  percentToBps,
  splitEscrow,
  statementBytes,
  statementProblem,
  type ArbiterLog,
  type Ruling,
  type Viewer,
} from './aiJudge'

const tenant = '0x484811c8c967809bE644A89d677933c29fb9e936'
const landlord = '0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE'
const agent = '0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA'
const aiArbiter = '0x1111111111111111111111111111111111111111'
const escrow = '0x2222222222222222222222222222222222222222'
const hashA = `0x${'aa'.repeat(32)}` as const
const hashB = `0x${'bb'.repeat(32)}` as const
const tx = (n: number) => `0x${n.toString(16).padStart(64, '0')}` as const

describe('bps <-> %', () => {
  it('maps basis points to percent', () => {
    expect(bpsToPercent(0)).toBe(0)
    expect(bpsToPercent(7500)).toBe(75)
    expect(bpsToPercent(3333)).toBe(33.33)
    expect(bpsToPercent(10_000)).toBe(100)
    expect(bpsToPercent(12_000)).toBe(100)
  })

  it('maps percent to the nearest basis point', () => {
    expect(percentToBps(0)).toBe(0)
    expect(percentToBps(50)).toBe(5000)
    expect(percentToBps(100)).toBe(10_000)
    expect(percentToBps(33.33)).toBe(3333)
    expect(percentToBps(12.345)).toBe(1235) // 1234.4999… in floating point
    expect(percentToBps(0.004)).toBe(0)
  })

  it('refuses values outside 0..100 %', () => {
    expect(percentToBps(-1)).toBeNull()
    expect(percentToBps(100.01)).toBeNull()
    expect(percentToBps(Number.NaN)).toBeNull()
    expect(percentToBps(Number.POSITIVE_INFINITY)).toBeNull()
  })

  it('round-trips every slider step', () => {
    for (let p = 0; p <= 100; p += 5) expect(bpsToPercent(percentToBps(p)!)).toBe(p)
  })

  it('formats without trailing zeros', () => {
    expect(formatBps(7500)).toBe('75%')
    expect(formatBps(3333)).toBe('33.33%')
    expect(formatBps(50)).toBe('0.5%')
    expect(formatBps(0)).toBe('0%')
    expect(formatBps(10_000)).toBe('100%')
  })
})

describe('splitEscrow', () => {
  it('rounds the tenant share down and gives the landlord the rest, like RentEscrow', () => {
    expect(splitEscrow(850_000n, 7500)).toEqual({ toTenant: 637_500n, toLandlord: 212_500n })
    expect(splitEscrow(1n, 5000)).toEqual({ toTenant: 0n, toLandlord: 1n })
    expect(splitEscrow(999n, 3333)).toEqual({ toTenant: 332n, toLandlord: 667n })
    expect(splitEscrow(100n, 0)).toEqual({ toTenant: 0n, toLandlord: 100n })
    expect(splitEscrow(100n, 10_000)).toEqual({ toTenant: 100n, toLandlord: 0n })
  })
})

const ruling = (over: Partial<Ruling> = {}): Ruling => ({
  status: RulingStatus.PROPOSED,
  tenantBps: 7500,
  confidenceBps: 8500,
  proposedAt: 1000n,
  deadline: 1120n,
  rulingHash: hashA,
  ...over,
})
const nobody: Viewer = { isTenant: false, isLandlord: false, isHuman: false }
const asTenant: Viewer = { ...nobody, isTenant: true }
const asLandlord: Viewer = { ...nobody, isLandlord: true }
const asHuman: Viewer = { ...nobody, isHuman: true }
const disputed = LeaseState.DISPUTED

describe('judgeView', () => {
  it('awaits evidence before any proposal; parties may write, the human may rule', () => {
    const v = judgeView({ leaseState: disputed, ruling: undefined, now: 0, viewer: asTenant })
    expect(v).toMatchObject({ phase: 'awaiting-evidence', label: 'Awaiting evidence', final: false, windowOpen: false, secondsLeft: null })
    expect(v.canSubmitEvidence).toBe(true)
    expect(v.canAppeal || v.canExecute || v.canResolveByHuman).toBe(false)
    expect(judgeView({ leaseState: disputed, ruling: ruling({ status: RulingStatus.NONE }), now: 0, viewer: asHuman }).canResolveByHuman).toBe(true)
    expect(judgeView({ leaseState: disputed, ruling: undefined, now: 0, viewer: nobody }).canSubmitEvidence).toBe(false)
  })

  it('stops evidence once the party has used its statements', () => {
    expect(judgeView({ leaseState: disputed, ruling: undefined, now: 0, viewer: asLandlord, statementsLeft: 1 }).canSubmitEvidence).toBe(true)
    expect(judgeView({ leaseState: disputed, ruling: undefined, now: 0, viewer: asLandlord, statementsLeft: 0 }).canSubmitEvidence).toBe(false)
  })

  it('counts down the challenge window; parties appeal inside it, nobody executes', () => {
    const v = judgeView({ leaseState: disputed, ruling: ruling(), now: 1030, viewer: asTenant })
    expect(v).toMatchObject({ phase: 'proposed', label: 'Proposed', windowOpen: true, secondsLeft: 90, canAppeal: true, canExecute: false })
    expect(judgeView({ leaseState: disputed, ruling: ruling(), now: 1119, viewer: asLandlord }).canAppeal).toBe(true)
    expect(judgeView({ leaseState: disputed, ruling: ruling(), now: 1030, viewer: nobody }).canAppeal).toBe(false)
    expect(judgeView({ leaseState: disputed, ruling: ruling(), now: 1030, viewer: asHuman }).canAppeal).toBe(false)
  })

  it('closes the window at the deadline exactly (block.timestamp >= deadline), then anyone executes', () => {
    const v = judgeView({ leaseState: disputed, ruling: ruling(), now: 1120, viewer: nobody })
    expect(v).toMatchObject({ windowOpen: false, secondsLeft: 0, canExecute: true, canAppeal: false })
    expect(judgeView({ leaseState: disputed, ruling: ruling(), now: 5000, viewer: asTenant })).toMatchObject({ secondsLeft: 0, canAppeal: false, canExecute: true })
  })

  it('lets the human override a proposal inside or after the window, and after an appeal', () => {
    expect(judgeView({ leaseState: disputed, ruling: ruling(), now: 1030, viewer: asHuman }).canResolveByHuman).toBe(true)
    expect(judgeView({ leaseState: disputed, ruling: ruling(), now: 2000, viewer: asHuman }).canResolveByHuman).toBe(true)
    const appealed = judgeView({ leaseState: disputed, ruling: ruling({ status: RulingStatus.APPEALED }), now: 1030, viewer: asHuman })
    expect(appealed).toMatchObject({ phase: 'appealed', label: 'Appealed', canResolveByHuman: true, canExecute: false, canAppeal: false, secondsLeft: null })
  })

  it('never lets the human rule on a lease it is a party to', () => {
    expect(judgeView({ leaseState: disputed, ruling: undefined, now: 0, viewer: { ...asHuman, isLandlord: true } }).canResolveByHuman).toBe(false)
  })

  it('is final and inert once executed or resolved by the human', () => {
    for (const [status, phase, label] of [
      [RulingStatus.EXECUTED, 'executed', 'Executed'],
      [RulingStatus.HUMAN_RESOLVED, 'human-resolved', 'Resolved by human'],
    ] as const) {
      const v = judgeView({ leaseState: LeaseState.CLOSED, ruling: ruling({ status }), now: 9999, viewer: asHuman })
      expect(v).toMatchObject({ phase, label, final: true, canAppeal: false, canExecute: false, canResolveByHuman: false, canSubmitEvidence: false })
    }
  })

  it('allows nothing on a lease that is no longer in dispute', () => {
    const v = judgeView({ leaseState: LeaseState.CLOSED, ruling: ruling(), now: 1030, viewer: asTenant })
    expect(v.canAppeal || v.canExecute || v.canSubmitEvidence).toBe(false)
  })
})

describe('disputeLog', () => {
  const evidence = (leaseId: bigint, party: `0x${string}`, statement: string, block: bigint, logIndex: number): ArbiterLog => ({
    eventName: 'Evidence',
    args: { leaseId, party, statement },
    transactionHash: tx(Number(block) * 10 + logIndex),
    blockNumber: block,
    logIndex,
  })
  const proposed = (leaseId: bigint, tenantBps: number, rulingHash: `0x${string}`, block: bigint, summary: string): ArbiterLog => ({
    eventName: 'Proposed',
    args: { leaseId, agent, tenantBps, confidenceBps: 9000, rulingHash, deadline: 1120n, summary },
    transactionHash: tx(Number(block) * 10),
    blockNumber: block,
    logIndex: 0,
  })

  it('keeps one lease’s statements in chain order, whatever order the logs arrive in', () => {
    const logs = [
      evidence(3n, tenant, 'I broke it by accident.', 12n, 0),
      evidence(4n, tenant, 'other lease', 11n, 0),
      evidence(3n, landlord, 'The tenant broke the kitchen window.', 10n, 1),
    ]
    const log = disputeLog(logs, 3n)
    expect(log.evidence.map((e) => e.statement)).toEqual(['The tenant broke the kitchen window.', 'I broke it by accident.'])
    expect(log.evidence[0]).toMatchObject({ party: landlord, txHash: tx(101) })
    expect(new Set(log.evidence.map((e) => e.key)).size).toBe(2)
    expect(log.proposal).toBeUndefined()
    expect(log.proposals).toBe(0)
  })

  it('picks the proposal behind the current ruling hash, else the latest', () => {
    const logs = [proposed(3n, 5000, hashA, 20n, 'first'), proposed(3n, 7500, hashB, 21n, 'replacement')]
    expect(disputeLog(logs, 3n).proposal).toMatchObject({ tenantBps: 7500, summary: 'replacement', agent })
    expect(disputeLog(logs, 3n, hashA).proposal).toMatchObject({ tenantBps: 5000, summary: 'first' })
    expect(disputeLog(logs, 3n, hashB).proposals).toBe(2)
    expect(disputeLog(logs, 3n, `0x${'cc'.repeat(32)}`).proposal?.summary).toBe('replacement')
  })

  it('records who appealed', () => {
    const logs: ArbiterLog[] = [
      proposed(3n, 5000, hashA, 20n, 's'),
      { eventName: 'Appealed', args: { leaseId: 3n, by: tenant }, transactionHash: tx(1), blockNumber: 22n, logIndex: 0 },
    ]
    expect(disputeLog(logs, 3n).appealedBy).toBe(tenant)
    expect(disputeLog(logs, 4n).appealedBy).toBeUndefined()
  })
})

describe('statements', () => {
  it('counts UTF-8 bytes like the contract', () => {
    expect(statementBytes('abc')).toBe(3)
    expect(statementBytes('é')).toBe(2)
    expect(statementBytes('家')).toBe(3)
  })

  it('rejects empty and oversized statements', () => {
    expect(statementProblem('   ')).toBe('Write a statement first.')
    expect(statementProblem('ok')).toBeNull()
    expect(statementProblem('a'.repeat(1000))).toBeNull()
    expect(statementProblem(` ${'a'.repeat(1000)} `)).toBeNull() // trimmed before sending
    expect(statementProblem('a'.repeat(1001))).toMatch(/^1,001 bytes; the limit is 1,000/)
    expect(statementProblem('家'.repeat(334))).toMatch(/^1,002 bytes/)
  })
})

describe('aiArbiterProblem', () => {
  it('accepts an AIArbiter bound to this escrow and set as its arbiter', () => {
    expect(aiArbiterProblem({ aiArbiter, boundEscrow: escrow, escrow, escrowArbiter: aiArbiter })).toBeNull()
    expect(aiArbiterProblem({ aiArbiter, boundEscrow: escrow, escrow: undefined, escrowArbiter: undefined })).toBeNull()
  })

  it('explains an unbound contract, another escrow, or another arbiter', () => {
    expect(aiArbiterProblem({ aiArbiter, boundEscrow: undefined, escrow, escrowArbiter: aiArbiter })).toMatch(/bindEscrow/)
    expect(aiArbiterProblem({ aiArbiter, boundEscrow: landlord, escrow, escrowArbiter: aiArbiter })).toMatch(/another escrow/)
    expect(aiArbiterProblem({ aiArbiter, boundEscrow: escrow, escrow, escrowArbiter: agent })).toMatch(/arbiter is 0x4a44…d0dA/)
  })
})
