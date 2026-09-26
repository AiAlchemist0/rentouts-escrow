#!/usr/bin/env node
// RentOuts AI dispute judge.
//   npm run judge -- --lease <id> [--provider glm|mock] [--propose]
// See judge/README.md. Secrets come from the environment only (run.sh loads the team secrets file).
import { existsSync, readFileSync } from 'node:fs'
import { parseArgs } from 'node:util'
import { createPublicClient, formatUnits, getAddress, http, isAddress } from 'viem'
import { sepolia } from 'viem/chains'
import { canonicalJson } from './canonical.ts'
import { loadDisputeInput, NotDisputedError, type ArbiterState } from './chain.ts'
import { abstainWithoutModel, confidenceBasis, decide, type Decision } from './decide.ts'
import { createProvider, isProviderName, PROVIDERS } from './providers/index.ts'
import { EXIT_STANDING_PROPOSAL, MOCK_SUMMARY_PREFIX, planProposal, sendProposal } from './propose.ts'
import { TOKYO_RULES_REF } from './rules/tokyo.ts'
import { proposedPath, recordPath, verifyOnchain, verifySaved, writeRecord, type SavedRuling } from './record.ts'
import type { Address, DisputeInput } from './types.ts'

const DEFAULT_RPC = 'https://ethereum-sepolia-rpc.publicnode.com'
const DEPLOYMENTS = new URL('../../deployments.json', import.meta.url)

const USAGE = `RentOuts AI dispute judge

  npm run judge -- --lease <id> [--provider glm|mock] [--propose]

  --lease <id>         disputed RentEscrow lease id
  --provider <name>    ${PROVIDERS.join(' | ')} (default glm; mock = deterministic, no API key)
  --propose            send AIArbiter.propose (keystore ~/.foundry/keystores/$JUDGE_KEYSTORE)
  --arbiter <address>  AIArbiter (default $AI_ARBITER, else deployments.json "sepoliaAIArbiter")
  --rpc <url>          Sepolia RPC (default $SEPOLIA_RPC_URL, else ${DEFAULT_RPC})
  --from-block <n>     first block to scan for the dispute's logs (default: the AIArbiter record)
  --input <file>       judge a saved DisputeInput JSON instead of reading the chain (no --propose)
  --out-dir <dir>      where rulings are saved (default judge/out). Every run writes
                       ruling-<chainId>-<arbiter>-<lease>-<rulingHash>.json (never overwrites
                       another ruling); a confirmed --propose also writes
                       ruling-<chainId>-<arbiter>-<lease>.json, the ruling behind that proposal
  --out <file>         save this run's ruling here instead of the hash-named file
  --json               print the ruling JSON on stdout (the report goes to stderr)
  --verify <file>      check a saved ruling and exit 0 (ok) or 1: its rulingHash, and that its
                       saved input (facts + statements) is the one the ruling committed to
  --onchain            with --verify: also compare with AIArbiter.getRuling(lease) on --rpc

  exit: 0 ok, 1 error, 2 usage, ${EXIT_STANDING_PROPOSAL} --propose abstained while an earlier AI proposal is still open
       (it executes at its deadline unless a party appeals or the human calls resolveByHuman)

  env: ZAI_API_KEY ZAI_BASE_URL ZAI_MODEL JUDGE_REASONING_EFFORT JUDGE_MAX_TOKENS
       JUDGE_MIN_CONFIDENCE (default 0.7) JUDGE_KEYSTORE (default rentouts-judge) JUDGE_KEYSTORE_DIR
       JUDGE_KEYSTORE_PASSWORD (else a hidden prompt) JUDGE_FROM_BLOCK AI_ARBITER SEPOLIA_RPC_URL`

class UsageError extends Error {}

function deploymentsRecord(): { aiArbiter?: string; fromBlock?: number } {
  if (!existsSync(DEPLOYMENTS)) return {}
  try {
    const json = JSON.parse(readFileSync(DEPLOYMENTS, 'utf8'))
    return json.sepoliaAIArbiter ?? {}
  } catch {
    return {}
  }
}

function minConfidenceFromEnv(env: NodeJS.ProcessEnv): number {
  const raw = env.JUDGE_MIN_CONFIDENCE
  const v = raw === undefined || raw === '' ? 0.7 : Number(raw)
  if (!Number.isFinite(v) || v < 0 || v > 1) throw new UsageError('JUDGE_MIN_CONFIDENCE must be a number between 0 and 1')
  return v
}

function loadInputFile(path: string): DisputeInput {
  const input = JSON.parse(readFileSync(path, 'utf8')) as DisputeInput
  if (input?.version !== 1 || !input.lease || !Array.isArray(input.evidence)) {
    throw new UsageError(`${path} is not a DisputeInput (version 1)`)
  }
  return input
}

function pct(bps: number): string {
  return `${(bps / 100).toFixed(2)}%`
}

function report(input: DisputeInput, d: Decision, meta: { provider: string; model: string; attempts: number; latencyMs: number | null; notes: string[] }, arbiterState: ArbiterState | null): string[] {
  const l = input.lease
  const { decimals, symbol } = l.token
  const amt = (v: string | bigint) => `${formatUnits(BigInt(v), decimals)} ${symbol}`
  const r = d.ruling
  const lines = [
    `RentOuts AI judge: lease #${l.leaseId} (chain ${input.chainId})`,
    `  escrow        ${input.escrow}`,
    `  arbiter       ${input.arbiter}${arbiterState ? `  (current: ${arbiterState.ruling.status}, window ${arbiterState.challengeWindow} s)` : ''}`,
    `  remaining     ${amt(l.remainingEscrow)} = deposit ${amt(l.deposit)} + earned rent ${amt(l.earnedRentUnreleased)} + unearned rent ${amt(l.unearnedRent)}`,
    `  dispute       opened by the ${l.disputeOpenedBy} after ${l.periodsEarnedAtDispute}/${l.periods} periods`,
    `  evidence      ${input.evidence.length} statement(s): ${input.evidence.map((e) => `${e.id} ${e.party}`).join(', ') || 'none'}`,
    `  tenant ENS    ${input.tenantCredential?.name ?? '(none)'}${input.tenantCredential?.name ? ` (status ${input.tenantCredential.status ?? '?'}, ${input.tenantCredential.resolvesToTenant ? 'resolves to the tenant' : 'does NOT resolve to the tenant'})` : ''}`,
    `  judge         ${meta.provider} (${meta.model}), ${meta.attempts} attempt(s)`,
    `  latency       ${meta.latencyMs === null ? 'no model call' : `${meta.latencyMs} ms`}`,
  ]
  for (const n of meta.notes) lines.push(`  note          ${n}`)
  const a = r.answers
  if (a) {
    const yn = (q: { answer: string; confidence: number }) => `${q.answer.padEnd(3)}  (p=${q.confidence.toFixed(2)})`
    const rentNote = confidenceBasis(a, l).includes('rentClaimValid')
      ? ''
      : `  not counted in confidence: ${a.rentClaimValid.answer === 'no' ? 'leaves the unearned rent with the tenant' : 'no unearned rent to move'}`
    lines.push(
      '  answers',
      `    damage beyond normal wear     ${yn(a.damageBeyondNormalWear)}`,
      `    landlord's rent claim valid   ${yn(a.rentClaimValid)}${rentNote}`,
      `    evidence sufficient           ${yn(a.evidenceSufficient)}`,
      `    severity                      ${a.severity}/5`,
      `  rationale     ${a.rationale}`,
    )
    if (a.rules?.length) lines.push(`  rules cited   ${a.rules.join(', ')}`)
  }
  if (r.rules) lines.push(`  rules pack    ${r.rules.id} v${r.rules.version} (${r.rules.hash})`)
  for (const i of r.rubric?.items ?? []) {
    const life = i.usefulLifeYears === null ? 'not depreciated' : `age ${i.ageYears} of ${i.usefulLifeYears} y -> tenant share ${pct(i.tenantShareBps)}`
    lines.push(`  item          ${i.item} [${i.material}] ${i.cause}, severity ${i.severity}/5, ${life}: charge ${amt(i.charge)}`)
  }
  if (r.rubric) {
    lines.push(
      `  rubric        tenant: deposit ${amt(r.rubric.depositReturned)} back (${amt(r.rubric.depositKept)} kept) + unearned rent ${amt(r.rubric.unearnedRentToTenant)} = ${amt(r.rubric.tenantAmount)} of ${amt(r.rubric.remainingEscrow)} (${pct(r.rubric.exactBps)}) -> ${pct(r.rubric.tenantBps)}`,
    )
  }
  if (r.decision === 'propose') {
    lines.push(`  decision      PROPOSE tenantBps ${r.tenantBps} (${pct(r.tenantBps ?? 0)} to the tenant), confidence ${pct(r.confidenceBps)}`)
  } else {
    lines.push(`  decision      ABSTAIN: ${r.abstainReasons.join('; ')}`, '                escalated to human arbiter')
  }
  lines.push(`  rulingHash    ${d.rulingHash}`)
  return lines
}

async function main(argv: string[], env: NodeJS.ProcessEnv): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: {
      lease: { type: 'string' },
      provider: { type: 'string', default: 'glm' },
      propose: { type: 'boolean', default: false },
      arbiter: { type: 'string' },
      rpc: { type: 'string' },
      'from-block': { type: 'string' },
      input: { type: 'string' },
      out: { type: 'string' },
      'out-dir': { type: 'string' },
      json: { type: 'boolean', default: false },
      verify: { type: 'string' },
      onchain: { type: 'boolean', default: false },
      help: { type: 'boolean', short: 'h', default: false },
    },
    strict: true,
  })
  if (values.help) {
    console.log(USAGE)
    return 0
  }
  const say = values.json ? (line: string) => console.error(line) : (line: string) => console.log(line)
  const warn = (line: string) => console.error(line)

  if (values.verify) {
    const saved = JSON.parse(readFileSync(values.verify, 'utf8'))
    const offline = verifySaved(saved)
    for (const line of offline.lines) say(line)
    if (!offline.ok || !values.onchain) return offline.ok ? 0 : 1
    const client = createPublicClient({ chain: sepolia, transport: http(values.rpc || env.SEPOLIA_RPC_URL || DEFAULT_RPC) })
    const onchain = await verifyOnchain(client, saved.ruling, saved.rulingHash)
    for (const line of onchain.lines) say(line)
    return onchain.ok ? 0 : 1
  }
  if (values.onchain) throw new UsageError('--onchain goes with --verify <file>')

  if (!values.lease && !values.input) throw new UsageError('--lease <id> is required')
  if (values.lease !== undefined && !/^\d+$/.test(values.lease)) throw new UsageError('--lease must be a lease id')
  if (!isProviderName(values.provider)) throw new UsageError(`--provider must be one of ${PROVIDERS.join(', ')}`)
  if (values.propose && values.input) throw new UsageError('--propose needs a lease read from the chain, not --input')
  const minConfidence = minConfidenceFromEnv(env)
  const provider = createProvider(values.provider, env, warn)
  if (provider.name === 'mock' && values.propose) {
    warn('WARNING: --provider mock is keyword matching, not a judge. A proposal it makes is signed with the agent key')
    warn(`         like any other; its on-chain summary starts with "${MOCK_SUMMARY_PREFIX.trim()}" and the ruling records provider "mock".`)
  }

  const rpcUrl = values.rpc || env.SEPOLIA_RPC_URL || DEFAULT_RPC
  const record = deploymentsRecord()
  let input: DisputeInput
  let arbiterState: ArbiterState | null = null
  let client: ReturnType<typeof createPublicClient> | null = null
  if (values.input) {
    input = loadInputFile(values.input)
  } else {
    const arbiterRaw = values.arbiter || env.AI_ARBITER || record.aiArbiter
    if (!arbiterRaw || !isAddress(arbiterRaw)) {
      throw new UsageError('no AIArbiter address: pass --arbiter, set AI_ARBITER, or deploy it (deployments.json "sepoliaAIArbiter")')
    }
    const fromRaw = values['from-block'] ?? env.JUDGE_FROM_BLOCK ?? (record.fromBlock !== undefined ? String(record.fromBlock) : undefined)
    if (fromRaw !== undefined && !/^\d+$/.test(fromRaw)) throw new UsageError('--from-block must be a block number')
    client = createPublicClient({ chain: sepolia, transport: http(rpcUrl) })
    const loaded = await loadDisputeInput(client as never, getAddress(arbiterRaw), BigInt(values.lease!), {
      fromBlock: fromRaw === undefined ? undefined : BigInt(fromRaw),
      log: warn,
    })
    input = loaded.input
    arbiterState = loaded.arbiterState
  }
  if (values.lease !== undefined && input.lease.leaseId !== values.lease) {
    throw new UsageError(`--lease ${values.lease} does not match the input's lease ${input.lease.leaseId}`)
  }

  // Ask the model (unless there is nothing to judge), then let code decide.
  const judge = { provider: provider.name, model: provider.model }
  let decision: Decision
  let meta = { ...judge, attempts: 0, latencyMs: null as number | null, notes: [] as string[] }
  if (input.evidence.length === 0) {
    decision = abstainWithoutModel(input, judge, minConfidence, 'no statements from either party')
  } else {
    const t0 = performance.now()
    const result = await provider.judge(input)
    const latencyMs = Math.round(performance.now() - t0)
    meta = { provider: provider.name, model: result.model, attempts: result.attempts, latencyMs, notes: result.notes }
    decision = decide(input, result.answers, { provider: provider.name, model: result.model }, minConfidence, { rules: TOKYO_RULES_REF })
  }

  for (const line of report(input, decision, meta, arbiterState)) say(line)

  // Saved before anything is sent, under a name that holds the hash: the preimage of a rulingHash
  // that goes on-chain is never overwritten by a later run.
  const outDir = values['out-dir'] ?? new URL('../out/', import.meta.url).pathname
  const saved: SavedRuling = { rulingHash: decision.rulingHash, ruling: decision.ruling, input, meta: { ...meta, savedAt: new Date().toISOString() } }
  const out = values.out ?? recordPath(outDir, decision.ruling, decision.rulingHash)
  writeRecord(out, saved)
  say(`  saved         ${out}`)
  if (values.json) console.log(canonicalJson(decision.ruling))

  const plan = planProposal(decision.ruling, arbiterState?.ruling ?? null, {
    propose: values.propose,
    now: BigInt(Math.floor(Date.now() / 1000)),
  })
  for (const line of plan.lines) say(line)
  if (!plan.send) return plan.exitCode
  const { txHash, deadline } = await sendProposal({
    publicClient: client as never,
    rpcUrl,
    arbiter: input.arbiter as Address,
    leaseId: BigInt(input.lease.leaseId),
    decision,
    expectedAgent: arbiterState!.agent,
    keystore: env.JUDGE_KEYSTORE || 'rentouts-judge',
    keystoreDir: env.JUDGE_KEYSTORE_DIR || undefined,
    password: env.JUDGE_KEYSTORE_PASSWORD || undefined,
    log: say,
  })
  say(`  proposed      confirmed on-chain`)
  const proposed = proposedPath(outDir, decision.ruling)
  writeRecord(proposed, { ...saved, meta: { ...saved.meta, proposal: { txHash, deadline: deadline?.toString() ?? null } } })
  say(`  saved         ${proposed} (the ruling behind this proposal: --verify it with --onchain)`)
  if (deadline !== null) {
    say(`  appeal until  ${new Date(Number(deadline) * 1000).toISOString()} (then anyone can execute; the human can override until then)`)
  }
  return 0
}

main(process.argv.slice(2), process.env).then(
  (code) => process.exit(code),
  (err: unknown) => {
    if (err instanceof UsageError) {
      console.error(`error: ${err.message}\n\n${USAGE}`)
      process.exit(2)
    }
    if (err instanceof NotDisputedError) {
      console.error(`nothing to judge: ${err.message}`)
      process.exit(1)
    }
    const e = err as Error
    console.error(`error: ${e.message?.split('\n')[0] ?? String(err)}`)
    process.exit(1)
  },
)
