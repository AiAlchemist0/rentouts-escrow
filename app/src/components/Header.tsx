import { useAccount, useConnect, useDisconnect, useSwitchChain } from 'wagmi'
import { sepolia } from 'wagmi/chains'
import { useRentoutsName } from '../hooks'
import { errorMessage } from '../lib/errors'
import { shortAddress } from '../lib/format'

function Logo() {
  return (
    <svg className="logo" viewBox="0 0 32 32" aria-hidden="true">
      <path d="M6 15.5 16 7l10 8.5V26a1 1 0 0 1-1 1h-6v-6.5h-6V27H7a1 1 0 0 1-1-1z" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round" />
      <circle cx="16" cy="16" r="2" fill="currentColor" />
    </svg>
  )
}

function WalletButton() {
  const { address, isConnected, connector } = useAccount()
  const { connect, connectors, isPending, error } = useConnect()
  const { disconnect } = useDisconnect()
  const { data: name } = useRentoutsName(address)
  const injectedConnector = connectors[0]
  const hasWallet = typeof window !== 'undefined' && 'ethereum' in window

  if (isConnected && address) {
    return (
      <button type="button" className="btn btn-quiet wallet" onClick={() => disconnect({ connector })} title={`${address}\nClick to disconnect`}>
        <span className="wallet-dot" aria-hidden="true" />
        {name || shortAddress(address)}
      </button>
    )
  }
  if (!hasWallet) {
    return (
      <a className="btn btn-primary" href="https://metamask.io/download/" target="_blank" rel="noreferrer">
        Install MetaMask
      </a>
    )
  }
  return (
    <span className="wallet-connect">
      <button
        type="button"
        className="btn btn-primary"
        disabled={isPending || !injectedConnector}
        onClick={() => injectedConnector && connect({ connector: injectedConnector, chainId: sepolia.id })}
      >
        {isPending ? 'Connecting…' : 'Connect MetaMask'}
      </button>
      {error ? <span className="wallet-error">{errorMessage(error)}</span> : null}
    </span>
  )
}

export function Header() {
  return (
    <header className="header">
      <div className="wrap header-row">
        <a className="brand" href="#identity">
          <Logo />
          <span className="brand-name">RentOuts</span>
          <span className="brand-sub">Escrow</span>
        </a>
        <div className="header-right">
          <span className="chain-pill" title={`Ethereum Sepolia, chain id ${sepolia.id}`}>
            Sepolia testnet
          </span>
          <WalletButton />
        </div>
      </div>
    </header>
  )
}

/** Shown when the wallet is on another chain; reads keep working, writes wait for the switch. */
export function NetworkGuard() {
  const { isConnected, chainId } = useAccount()
  const { switchChain, isPending, error } = useSwitchChain()
  if (!isConnected || chainId === sepolia.id) return null
  return (
    <div className="guard" role="alert">
      <div className="wrap guard-row">
        <p>
          MetaMask is on another network. This demo runs on Ethereum Sepolia (chain id {sepolia.id}).
          {error ? ` ${errorMessage(error)}` : ''}
        </p>
        <button type="button" className="btn btn-primary" disabled={isPending} onClick={() => switchChain({ chainId: sepolia.id })}>
          {isPending ? 'Switching…' : 'Switch to Sepolia'}
        </button>
      </div>
    </div>
  )
}
