import { getAddress, isAddress, zeroAddress, type Address } from 'viem'
import deployment from '../../ens/deployments/sepolia.json'

const env = import.meta.env

/** Parses an optional address env var. Empty, malformed or zero means "not configured". */
export function optionalAddress(value: string | undefined): Address | undefined {
  const v = value?.trim()
  if (!v) return undefined
  if (!isAddress(v, { strict: false })) {
    console.warn(`Ignoring malformed address in env: ${v}`)
    return undefined
  }
  const address = getAddress(v)
  return address === zeroAddress ? undefined : address
}

export const RPC_URL = env.VITE_SEPOLIA_RPC_URL?.trim() || 'https://ethereum-sepolia-rpc.publicnode.com'

/** Circle's USDC on Ethereum Sepolia (6 decimals). */
export const CIRCLE_USDC: Address = '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238'

/** ENSv2 deployment, straight from ens/deployments/sepolia.json (written by the ENS deploy script). */
export const ENS = {
  chainId: deployment.chainId,
  subnames: getAddress(deployment.rentoutsSubnames),
  resolver: getAddress(deployment.permissionedResolver),
  registry: getAddress(deployment.userRegistry),
  universalResolver: getAddress(deployment.universalResolver),
  /** Block RentoutsSubnames was deployed in (ens/broadcast/.../subnames-latest.json). Log scans start here. */
  subnamesDeployBlock: 11_779_455n,
} as const

/** Contracts that may not be deployed yet. `undefined` = not configured; the UI degrades. */
export const ENV_CONTRACTS = {
  escrow: optionalAddress(env.VITE_ESCROW_ADDRESS),
  leaseShare: optionalAddress(env.VITE_LEASE_SHARE_ADDRESS),
  credentialSync: optionalAddress(env.VITE_CREDENTIAL_SYNC_ADDRESS),
  token: optionalAddress(env.VITE_TOKEN_ADDRESS) ?? CIRCLE_USDC,
} as const

export const EXPLORER = 'https://sepolia.etherscan.io'
export const ENS_APP = 'https://sepolia.app.ens.domains'

/** The rentouts.* text records the credential card shows, in display order. */
export const CREDENTIAL_KEYS = [
  'rentouts.credential',
  'rentouts.status',
  'rentouts.leasesCompleted',
  'rentouts.disputes',
  'rentouts.rentPaid',
  'rentouts.depositReturnRate',
  'rentouts.rating',
] as const
export type CredentialKey = (typeof CREDENTIAL_KEYS)[number]

/** Demo defaults sized for the faucets: ETHGlobal's faucet gives 1 test USDC per request. */
export const LEASE_DEFAULTS = {
  deposit: '0.25',
  rentPerPeriod: '0.20',
  periodSeconds: '120',
  periods: '3',
} as const
