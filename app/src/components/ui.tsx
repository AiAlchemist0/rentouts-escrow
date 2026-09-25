import type { ReactNode } from 'react'
import type { Address } from 'viem'
import type { TxState } from '../hooks'
import { addressUrl, shortAddress, txUrl } from '../lib/format'

export function ExtLink({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a href={href} target="_blank" rel="noreferrer" className="ext">
      {children}
    </a>
  )
}

/** Address (or its RentOuts name) linking to Sepolia Etherscan. */
export function AddressLink({ address, name }: { address: Address; name?: string }) {
  return (
    <a href={addressUrl(address)} target="_blank" rel="noreferrer" className="addr" title={address}>
      {name ?? shortAddress(address)}
    </a>
  )
}

export function Notice({ tone = 'info', children }: { tone?: 'info' | 'warn' | 'error' | 'ok'; children: ReactNode }) {
  return (
    <div className={`notice notice-${tone}`} role={tone === 'error' ? 'alert' : undefined}>
      {children}
    </div>
  )
}

export function Field({
  label,
  hint,
  children,
  htmlFor,
}: {
  label: string
  hint?: ReactNode
  children: ReactNode
  htmlFor: string
}) {
  return (
    <div className="field">
      <label htmlFor={htmlFor}>{label}</label>
      {children}
      {hint ? <div className="hint">{hint}</div> : null}
    </div>
  )
}

/** One line of transaction progress, always with the Etherscan link once there is a hash. */
export function TxStatus({ state, done = 'Confirmed.' }: { state: TxState; done?: string }) {
  switch (state.status) {
    case 'idle':
      return null
    case 'simulating':
      return <p className="tx tx-busy">Checking the transaction…</p>
    case 'signing':
      return <p className="tx tx-busy">Confirm in MetaMask…</p>
    case 'pending':
      return (
        <p className="tx tx-busy">
          Waiting for Sepolia to confirm. <ExtLink href={txUrl(state.hash)}>View on Etherscan</ExtLink>
        </p>
      )
    case 'success':
      return (
        <p className="tx tx-ok">
          {done} <ExtLink href={txUrl(state.hash)}>View on Etherscan</ExtLink>
        </p>
      )
    case 'error':
      return (
        <p className="tx tx-error" role="alert">
          {state.message} {state.hash ? <ExtLink href={txUrl(state.hash)}>View on Etherscan</ExtLink> : null}
        </p>
      )
  }
}

export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="empty">
      <p className="empty-title">{title}</p>
      {children ? <div className="empty-body">{children}</div> : null}
    </div>
  )
}

/** Placeholder for screens that need a contract that isn't deployed / configured yet. */
export function NotConfigured({ what, envVar, children }: { what: string; envVar: string; children?: ReactNode }) {
  return (
    <Empty title={`${what} isn’t configured yet`}>
      <p>
        Set <code>{envVar}</code> in <code>app/.env.local</code> and restart the dev server. {children}
      </p>
    </Empty>
  )
}
