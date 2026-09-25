#!/usr/bin/env node
// Live read-only check of the RentOuts contracts on Ethereum Sepolia. No wallet, no keys, no transactions.
//   node scripts/live-smoke.mjs            (npm run live:smoke)
// Addresses are resolved the way the app resolves them: VITE_* from the environment and app/.env*.local (Vite's
// loadEnv, dev mode), then the repo-root deployments.json ("sepolia" / "sepoliaAIArbiter"), then the escrow's
// own getters. Then it checks that the contracts point at each other. Exits 1 on any mismatch.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { createPublicClient, getAddress, http, isAddress, isAddressEqual, parseAbi, zeroAddress } from 'viem'
import { sepolia } from 'viem/chains'
import { loadEnv } from 'vite'

const appDir = fileURLToPath(new URL('..', import.meta.url))
const env = loadEnv(process.env.MODE || 'development', appDir, 'VITE_')

const readJson = (rel) => {
  try {
    return JSON.parse(readFileSync(new URL(rel, import.meta.url), 'utf8'))
  } catch {
    return undefined
  }
}
const asAddress = (v) => {
  const s = typeof v === 'string' ? v.trim() : ''
  if (!s || !isAddress(s, { strict: false })) return undefined
  const a = getAddress(s)
  return a === zeroAddress ? undefined : a
}
const onSepolia = (entry) => (entry && (entry.chainId === undefined || Number(entry.chainId) === sepolia.id) ? entry : {})

const deployments = readJson('../../deployments.json') ?? {}
const core = onSepolia(deployments.sepolia)
const ai = onSepolia(deployments.sepoliaAIArbiter)
const ens = readJson('../../ens/deployments/sepolia.json') ?? {}

const rpc = env.VITE_SEPOLIA_RPC_URL?.trim() || 'https://ethereum-sepolia-rpc.publicnode.com'
const client = createPublicClient({ chain: sepolia, transport: http(rpc) })

const escrowAbi = parseAbi([
  'function token() view returns (address)',
  'function arbiter() view returns (address)',
  'function leaseShare() view returns (address)',
  'function humanGate() view returns (address)',
  'function nextLeaseId() view returns (uint256)',
])
const aiArbiterAbi = parseAbi([
  'function escrow() view returns (address)',
  'function human() view returns (address)',
  'function pendingHuman() view returns (address)',
  'function agent() view returns (address)',
  'function challengeWindow() view returns (uint32)',
])
const leaseShareAbi = parseAbi(['function minter() view returns (address)', 'function owner() view returns (address)'])
const humanGateAbi = parseAbi(['function verifier() view returns (address)'])
const credentialSyncAbi = parseAbi(['function escrow() view returns (address)', 'function subnames() view returns (address)'])
const subnamesAbi = parseAbi(['function isIssuer(address account) view returns (bool)'])
const erc20Abi = parseAbi(['function symbol() view returns (string)', 'function decimals() view returns (uint8)'])

let failures = 0
const ok = (msg) => console.log(`ok    ${msg}`)
const fail = (msg) => {
  failures++
  console.log(`FAIL  ${msg}`)
}
const same = (a, b) => !!a && !!b && isAddressEqual(a, b)
const expectEq = (label, actual, expected) =>
  same(actual, expected) ? ok(`${label} = ${actual}`) : fail(`${label} = ${actual}, expected ${expected}`)
const read = (address, abi, functionName, args) => client.readContract({ address, abi, functionName, args })
const hasCode = async (label, address) => {
  const code = await client.getCode({ address })
  if (code && code !== '0x') return true
  fail(`${label} ${address} has no code on Sepolia`)
  return false
}

console.log(`rpc                 ${rpc}`)
const chainId = await client.getChainId()
chainId === sepolia.id ? ok(`chainId ${chainId}`) : fail(`chainId ${chainId}, expected ${sepolia.id}`)

// Same precedence as src/config.ts + src/lib/deployments.ts: env wins, the record fills the gaps.
const envEscrow = asAddress(env.VITE_ESCROW_ADDRESS)
const escrow = envEscrow ?? asAddress(core.rentEscrow)
const recordedEscrow = !envEscrow || same(envEscrow, asAddress(core.rentEscrow))
const configured = {
  aiArbiter: asAddress(env.VITE_AI_ARBITER_ADDRESS) ?? asAddress(ai.aiArbiter),
  leaseShare: asAddress(env.VITE_LEASE_SHARE_ADDRESS) ?? (recordedEscrow ? asAddress(core.leaseShare1155) : undefined),
  credentialSync: asAddress(env.VITE_CREDENTIAL_SYNC_ADDRESS),
  token: asAddress(env.VITE_TOKEN_ADDRESS) ?? (recordedEscrow ? asAddress(core.token) : undefined),
  humanGate: recordedEscrow ? asAddress(core.humanGate) : undefined,
}
const source = (fromEnv) => (fromEnv ? 'env' : 'deployments.json')
console.log(`escrow              ${escrow ?? 'not configured'} (${source(envEscrow)})`)
console.log(`aiArbiter           ${configured.aiArbiter ?? 'not configured'}`)
console.log(`leaseShare          ${configured.leaseShare ?? 'not configured'}`)
console.log(`credentialSync      ${configured.credentialSync ?? 'not configured'}`)

if (!escrow) {
  fail('no escrow: set VITE_ESCROW_ADDRESS in app/.env.local or add the "sepolia" entry to deployments.json')
  process.exit(1)
}
if (!(await hasCode('RentEscrow', escrow))) process.exit(1)

// RentEscrow
const [arbiter, humanGate, leaseShare, token, nextLeaseId] = await Promise.all([
  read(escrow, escrowAbi, 'arbiter'),
  read(escrow, escrowAbi, 'humanGate'),
  read(escrow, escrowAbi, 'leaseShare'),
  read(escrow, escrowAbi, 'token'),
  read(escrow, escrowAbi, 'nextLeaseId'),
])
ok(`escrow.nextLeaseId() = ${nextLeaseId} (${nextLeaseId - 1n} lease${nextLeaseId === 2n ? '' : 's'} so far)`)
const [symbol, decimals] = await Promise.all([read(token, erc20Abi, 'symbol'), read(token, erc20Abi, 'decimals')])
if (configured.token) expectEq('escrow.token()', token, configured.token)
else ok(`escrow.token() = ${token}`)
console.log(`      token ${symbol}, ${decimals} decimals`)

// AIArbiter <-> RentEscrow (the app falls back to escrow.arbiter() when no AIArbiter is configured)
const aiArbiter = configured.aiArbiter ?? arbiter
expectEq('escrow.arbiter()', arbiter, aiArbiter)
if (await hasCode('AIArbiter', aiArbiter)) {
  const [bound, human, pendingHuman, agent, challengeWindow] = await Promise.all([
    read(aiArbiter, aiArbiterAbi, 'escrow'),
    read(aiArbiter, aiArbiterAbi, 'human'),
    read(aiArbiter, aiArbiterAbi, 'pendingHuman'),
    read(aiArbiter, aiArbiterAbi, 'agent'),
    read(aiArbiter, aiArbiterAbi, 'challengeWindow'),
  ])
  expectEq('aiArbiter.escrow()', bound, escrow)
  human !== zeroAddress ? ok(`aiArbiter.human() = ${human}`) : fail('aiArbiter.human() is zero')
  const aiAgent = agent === zeroAddress ? 'zero (AI proposals off)' : agent
  const pending = pendingHuman === zeroAddress ? 'none' : pendingHuman
  console.log(`      agent ${aiAgent}, challengeWindow ${challengeWindow}s, pendingHuman ${pending}`)
}

// HumanGate (the app reads it only from the escrow)
if (humanGate === zeroAddress) ok('escrow.humanGate() = zero (funding not gated)')
else {
  if (configured.humanGate) expectEq('escrow.humanGate()', humanGate, configured.humanGate)
  else ok(`escrow.humanGate() = ${humanGate}`)
  if (await hasCode('HumanGate', humanGate)) {
    const verifier = await read(humanGate, humanGateAbi, 'verifier')
    console.log(`      verifier ${verifier === zeroAddress ? 'zero (open: everyone passes)' : verifier}`)
  }
}

// LeaseShare1155 <-> RentEscrow
if (configured.leaseShare) expectEq('escrow.leaseShare()', leaseShare, configured.leaseShare)
else ok(`escrow.leaseShare() = ${leaseShare}`)
if (await hasCode('LeaseShare1155', leaseShare)) expectEq('leaseShare.minter()', await read(leaseShare, leaseShareAbi, 'minter'), escrow)

// CredentialSync <-> RentEscrow, and its issuer role on RentoutsSubnames
if (!configured.credentialSync) {
  fail('CredentialSync not configured: set VITE_CREDENTIAL_SYNC_ADDRESS (the app hides "Sync credential to ENS")')
} else if (await hasCode('CredentialSync', configured.credentialSync)) {
  const [syncEscrow, syncSubnames] = await Promise.all([
    read(configured.credentialSync, credentialSyncAbi, 'escrow'),
    read(configured.credentialSync, credentialSyncAbi, 'subnames'),
  ])
  expectEq('credentialSync.escrow()', syncEscrow, escrow)
  const subnames = asAddress(ens.rentoutsSubnames)
  if (!subnames) fail('ens/deployments/sepolia.json has no rentoutsSubnames')
  else {
    expectEq('credentialSync.subnames()', syncSubnames, subnames)
    const issuer = await read(subnames, subnamesAbi, 'isIssuer', [configured.credentialSync])
    issuer ? ok('subnames.isIssuer(credentialSync) = true') : fail('subnames.isIssuer(credentialSync) = false')
  }
}

if (failures) {
  console.log(`\n${failures} check(s) failed`)
  process.exit(1)
}
console.log('\nall wiring checks passed')
