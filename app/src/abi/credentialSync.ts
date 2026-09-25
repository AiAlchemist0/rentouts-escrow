import { parseAbi } from 'viem'

/**
 * CredentialSync: permissionless `sync(tenant)` that reads RentEscrow.tenantStats(tenant) and writes the
 * tenant's rentouts.* ENS records through RentoutsSubnames (as an issuer). The app only calls `sync` and
 * then re-reads ENS, so it does not depend on the shape of the contract's `Synced` event.
 */
export const credentialSyncAbi = parseAbi(['function sync(address tenant)'])
