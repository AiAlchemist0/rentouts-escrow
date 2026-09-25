import { useEffect, useState, type ReactNode } from 'react'
import type { Address } from 'viem'
import { Header, NetworkGuard } from './components/Header'
import { AddressLink, ExtLink } from './components/ui'
import { ENS } from './config'
import { useContracts } from './hooks'
import { txUrl } from './lib/format'
import { useTxLog } from './txLog'
import { CreateLeasePanel } from './panels/CreateLeasePanel'
import { FundPanel } from './panels/FundPanel'
import { IdentityPanel } from './panels/IdentityPanel'
import { LeasesPanel } from './panels/LeasesPanel'
import { SharesPanel } from './panels/SharesPanel'

const STEPS = [
  { id: 'identity', title: 'Claim your name', who: 'Tenant', panel: IdentityPanel },
  { id: 'create', title: 'Create a lease', who: 'Landlord', panel: CreateLeasePanel },
  { id: 'fund', title: 'Fund the lease', who: 'Tenant', panel: FundPanel },
  { id: 'run', title: 'Run the lease', who: 'Both, and the arbiter', panel: LeasesPanel },
  { id: 'shares', title: 'Lease shares', who: 'Landlord', panel: SharesPanel },
] as const
type StepId = (typeof STEPS)[number]['id']

function stepFromHash(): StepId {
  const hash = window.location.hash.slice(1)
  return STEPS.find((s) => s.id === hash)?.id ?? 'identity'
}

/** Tabs driven by the URL hash, so every step has a link judges can open directly. */
function useStep(): StepId {
  const [step, setStep] = useState<StepId>(stepFromHash)
  useEffect(() => {
    const onHash = () => setStep(stepFromHash())
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])
  return step
}

function ContractRow({ name, address, note }: { name: string; address?: Address; note?: ReactNode }) {
  return (
    <div className="contract">
      <dt>{name}</dt>
      <dd>{address ? <AddressLink address={address} /> : <span className="muted">not configured</span>}{note ? <span className="muted"> {note}</span> : null}</dd>
    </div>
  )
}

const TX_STATUS = { pending: 'Pending', success: 'Confirmed', reverted: 'Reverted' } as const

/** Every transaction sent this session, with its Etherscan link, above whichever step is open. */
function RecentTxs() {
  const log = useTxLog()
  if (log.length === 0) return null
  return (
    <section className="recent" aria-label="Your transactions this session" aria-live="polite">
      <ul>
        {log.slice(0, 3).map((tx) => (
          <li key={tx.hash} className={`recent-${tx.status}`}>
            <span className="recent-status">{TX_STATUS[tx.status]}</span>
            <span className="recent-label">{tx.label}</span>
            <ExtLink href={txUrl(tx.hash)}>Etherscan</ExtLink>
          </li>
        ))}
      </ul>
    </section>
  )
}

function Footer() {
  const { escrow, token, leaseShare, credentialSync, arbiter, tokenSymbol } = useContracts()
  return (
    <footer className="footer">
      <div className="wrap">
        <h2>Contracts on Ethereum Sepolia</h2>
        <dl className="contracts">
          <ContractRow name="RentEscrow" address={escrow} />
          <ContractRow name={`Token (${tokenSymbol})`} address={token} />
          <ContractRow name="Arbiter" address={arbiter} note={arbiter ? '(test account; a Safe in production)' : undefined} />
          <ContractRow name="LeaseShare1155" address={leaseShare} />
          <ContractRow name="CredentialSync" address={credentialSync} />
          <ContractRow name="RentoutsSubnames" address={ENS.subnames} />
          <ContractRow name="PermissionedResolver" address={ENS.resolver} />
          <ContractRow name="UserRegistry" address={ENS.registry} />
          <ContractRow name="ENS Universal Resolver" address={ENS.universalResolver} />
        </dl>
        <p className="footer-note">
          Testnet demo for ETHGlobal Tokyo 2026. Test USDC only, no real funds. Source:{' '}
          <ExtLink href="https://github.com/AiAlchemist0/rentouts-escrow">github.com/AiAlchemist0/rentouts-escrow</ExtLink>{' '}
          (MIT).
        </p>
      </div>
    </footer>
  )
}

export function App() {
  const step = useStep()
  const current = STEPS.find((s) => s.id === step)!
  const Panel = current.panel

  return (
    <div className="app">
      <Header />
      <NetworkGuard />
      <main className="wrap main">
        <section className="hero">
          <h1>Rent held by a contract, not a company.</h1>
          <p>
            Tenants prepay deposit and rent into an escrow on Ethereum Sepolia. Rent unlocks to the landlord period by
            period, the deposit comes back at the end, and each finished lease adds to the tenant’s portable ENS
            credential.
          </p>
          <p className="hero-note">Testnet demo: Circle test USDC and a single-account arbiter (a Safe in production).</p>
        </section>

        <nav className="steps" aria-label="Demo steps">
          <ol>
            {STEPS.map((s, i) => (
              <li key={s.id}>
                <a href={`#${s.id}`} className={`step${s.id === step ? ' step-on' : ''}`} aria-current={s.id === step ? 'step' : undefined}>
                  <span className="step-n">{i + 1}</span>
                  <span className="step-text">
                    <span className="step-title">{s.title}</span>
                    <span className="step-who">{s.who}</span>
                  </span>
                </a>
              </li>
            ))}
          </ol>
        </nav>

        <RecentTxs />
        <section className="panel" aria-label={current.title}>
          <Panel />
        </section>
      </main>
      <Footer />
    </div>
  )
}
