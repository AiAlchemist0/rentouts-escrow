import { createConfig, http } from 'wagmi'
import { sepolia } from 'wagmi/chains'
// From @wagmi/core, not wagmi/connectors, which would pull every wallet SDK into the bundle.
import { injected } from '@wagmi/core'
import { RPC_URL } from './config'

/** One chain (Ethereum Sepolia), one connector (the injected wallet, i.e. MetaMask). */
export const wagmiConfig = createConfig({
  chains: [sepolia],
  connectors: [injected()],
  multiInjectedProviderDiscovery: false,
  transports: { [sepolia.id]: http(RPC_URL, { batch: { batchSize: 20 } }) },
})

declare module 'wagmi' {
  interface Register {
    config: typeof wagmiConfig
  }
}
