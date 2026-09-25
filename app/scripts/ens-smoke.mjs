#!/usr/bin/env node
// Live ENSv2 read check on Ethereum Sepolia. No wallet, no keys.
//   node scripts/ens-smoke.mjs [name]   (default: alice.<parent from ens/deployments/sepolia.json>)
// Reads go through the ENSv2 Universal Resolver, exactly like the app does.
import { readFileSync } from 'node:fs'
import { createPublicClient, http } from 'viem'
import { sepolia } from 'viem/chains'
import { normalize } from 'viem/ens'

const deployment = JSON.parse(readFileSync(new URL('../../ens/deployments/sepolia.json', import.meta.url), 'utf8'))
const rpc = process.env.VITE_SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com'
const name = normalize(process.argv[2] || `alice.${deployment.ensParentName}`)

const client = createPublicClient({ chain: sepolia, transport: http(rpc) })
const universalResolverAddress = deployment.universalResolver

console.log(`rpc                 ${rpc}`)
console.log(`universal resolver  ${universalResolverAddress} (viem sepolia default: ${sepolia.contracts.ensUniversalResolver.address})`)
console.log(`name                ${name}`)

const address = await client.getEnsAddress({ name, universalResolverAddress })
console.log(`getEnsAddress       ${address}`)

for (const key of ['rentouts.credential', 'rentouts.status']) {
  const value = await client.getEnsText({ name, key, universalResolverAddress })
  console.log(`getEnsText          ${key} = ${JSON.stringify(value)}`)
}

if (!address) {
  console.error('FAIL: name did not resolve')
  process.exit(1)
}
