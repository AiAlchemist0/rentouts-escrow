import { useState, type FormEvent } from 'react'
import type { Address } from 'viem'
import { useReadContract } from 'wagmi'
import { sepolia } from 'wagmi/chains'
import { leaseShareAbi } from '../abi/leaseShare'
import { AddressLink, Empty, Field, NotConfigured, Notice, TxStatus } from '../components/ui'
import { useAddressInput, useContracts, useLeases, useParentName, useTx, useWallet } from '../hooks'
import { parseWhole } from '../lib/format'

function useAllowlisted(leaseShare: Address | undefined, account: Address | undefined) {
  return useReadContract({
    address: leaseShare,
    abi: leaseShareAbi,
    functionName: 'allowlisted',
    args: account ? [account] : undefined,
    chainId: sepolia.id,
    query: { enabled: !!leaseShare && !!account },
  })
}

function TransferForm({ leaseShare, account, holdings }: { leaseShare: Address; account: Address; holdings: Map<bigint, bigint> }) {
  const parent = useParentName()
  const first = holdings.keys().next().value
  const [leaseId, setLeaseId] = useState(first !== undefined ? String(first) : '')
  const [recipientInput, setRecipientInput] = useState('')
  const [amount, setAmount] = useState('10')
  const tx = useTx()

  const resolved = useAddressInput(recipientInput)
  const recipient = resolved.kind === 'name' || resolved.kind === 'address' ? resolved.address : undefined
  const { data: recipientAllowed } = useAllowlisted(leaseShare, recipient)
  const id = parseWhole(leaseId, Number.MAX_SAFE_INTEGER)
  const value = parseWhole(amount, Number.MAX_SAFE_INTEGER)
  const held = id !== null ? holdings.get(BigInt(id)) : undefined

  async function onSubmit(event: FormEvent) {
    event.preventDefault()
    if (!recipient || id === null || value === null) return
    await tx.run({
      address: leaseShare,
      abi: leaseShareAbi,
      functionName: 'safeTransferFrom',
      args: [account, recipient, BigInt(id), BigInt(value), '0x'],
    }, `Transfer ${value} shares of lease #${id}`)
  }

  return (
    <form className="stack-s transfer" onSubmit={onSubmit}>
      <h3>Transfer shares</h3>
      <div className="grid-3">
        <Field label="Lease #" htmlFor="share-id" hint={held !== undefined ? `You hold ${String(held)}.` : undefined}>
          <input id="share-id" inputMode="numeric" value={leaseId} onChange={(e) => setLeaseId(e.target.value)} />
        </Field>
        <Field label="Shares" htmlFor="share-amount">
          <input id="share-amount" inputMode="numeric" value={amount} onChange={(e) => setAmount(e.target.value)} />
        </Field>
        <Field label="Recipient" htmlFor="share-to">
          <input
            id="share-to"
            value={recipientInput}
            onChange={(e) => setRecipientInput(e.target.value)}
            placeholder={parent ? `name.${parent} or 0x…` : '0x…'}
            autoComplete="off"
            spellCheck={false}
          />
        </Field>
      </div>
      {resolved.kind === 'loading' ? <p className="status status-hint">Resolving {resolved.name}…</p> : null}
      {resolved.kind === 'error' ? <p className="status status-bad">{resolved.message}</p> : null}
      {recipient && recipientAllowed === false ? (
        <p className="status status-bad">
          {resolved.kind === 'name' ? resolved.name : 'This address'} isn’t on the compliance allowlist, so the contract
          will refuse the transfer. Try it to see the on-chain check.
        </p>
      ) : null}
      {recipient && recipientAllowed === true ? (
        <p className="status status-ok">
          <AddressLink address={recipient} name={resolved.kind === 'name' ? resolved.name : undefined} /> is allowlisted.
        </p>
      ) : null}
      <div className="actions">
        <button type="submit" className="btn btn-primary" disabled={!recipient || id === null || value === null || tx.busy}>
          Transfer shares
        </button>
      </div>
      <TxStatus state={tx.state} done="Shares transferred." />
    </form>
  )
}

export function SharesPanel() {
  const { escrow, leaseShare, sharesPerLease } = useContracts()
  const { address, isConnected } = useWallet()
  const leases = useLeases(escrow)
  const { data: allowed } = useAllowlisted(leaseShare, address)
  const ids = (leases.data ?? []).map((l) => l.id)

  const { data: balances } = useReadContract({
    address: leaseShare,
    abi: leaseShareAbi,
    functionName: 'balanceOfBatch',
    args: address ? [ids.map(() => address), ids] : undefined,
    chainId: sepolia.id,
    query: { enabled: !!leaseShare && !!address && ids.length > 0 },
  })
  const holdings = new Map<bigint, bigint>()
  ids.forEach((id, i) => {
    const b = balances?.[i]
    if (b && b > 0n) holdings.set(id, b)
  })

  return (
    <div className="stack">
      <div>
        <h2>Lease shares</h2>
        <p className="lede">
          Each lease is also a real-world asset: creating it mints {sharesPerLease !== undefined ? String(sharesPerLease) : 'a fixed number of'}{' '}
          ERC-1155 shares (token id = lease id) to the landlord. Shares only move to addresses on a compliance allowlist,
          checked on-chain for every mint and transfer.
        </p>
      </div>
      {!leaseShare ? (
        <NotConfigured what="LeaseShare1155" envVar="VITE_LEASE_SHARE_ADDRESS">
          When the escrow is configured, the app reads the address from RentEscrow.leaseShare().
        </NotConfigured>
      ) : !isConnected || !address ? (
        <Notice>Connect MetaMask to see the shares you hold.</Notice>
      ) : (
        <>
          <p className={`status ${allowed ? 'status-ok' : 'status-bad'}`}>
            {allowed === undefined
              ? 'Checking the allowlist…'
              : allowed
                ? 'Your wallet is on the compliance allowlist.'
                : 'Your wallet isn’t on the compliance allowlist, so it can’t receive or be minted shares.'}{' '}
            Contract: <AddressLink address={leaseShare} />
          </p>
          {!escrow ? null : holdings.size === 0 ? (
            <Empty title="You don’t hold any lease shares">
              <p>Landlords receive shares when they create a lease.</p>
            </Empty>
          ) : (
            <ul className="holdings">
              {[...holdings].map(([id, amount]) => (
                <li key={String(id)}>
                  <span>Lease #{String(id)}</span>
                  <strong>{String(amount)} shares</strong>
                </li>
              ))}
            </ul>
          )}
          <TransferForm
            key={String(holdings.keys().next().value ?? 'none')}
            leaseShare={leaseShare}
            account={address}
            holdings={holdings}
          />
        </>
      )}
    </div>
  )
}
