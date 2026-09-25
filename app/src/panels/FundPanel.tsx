import type { Address } from 'viem'
import { useBalance, useReadContract } from 'wagmi'
import { sepolia } from 'wagmi/chains'
import { erc20Abi } from '../abi/erc20'
import { LeaseState, rentEscrowAbi } from '../abi/rentEscrow'
import { AddressLink, Empty, ExtLink, NotConfigured, Notice, TxStatus } from '../components/ui'
import { useContracts, useLeases, useRentoutsName, useRentoutsNames, useTx, useWallet, type LeaseRow } from '../hooks'
import { formatDuration, formatToken } from '../lib/format'
import { totalDue } from '../lib/lease'

function FundRow({ lease, account, balance }: { lease: LeaseRow; account: Address; balance: bigint | undefined }) {
  const { escrow, token, tokenDecimals, tokenSymbol } = useContracts()
  const nameOf = useRentoutsNames([lease.landlord])
  const approveTx = useTx()
  const fundTx = useTx()
  const due = totalDue(lease.deposit, lease.rentPerPeriod, lease.periods)

  const { data: allowance } = useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: 'allowance',
    args: [account, escrow!],
    chainId: sepolia.id,
    query: { enabled: !!escrow },
  })
  const approved = allowance !== undefined && allowance >= due
  const enough = balance !== undefined && balance >= due
  const amount = `${formatToken(due, tokenDecimals)} ${tokenSymbol}`

  return (
    <li className="fund-row">
      <div className="fund-terms">
        <p className="fund-title">
          Lease #{String(lease.id)} from <AddressLink address={lease.landlord} name={nameOf(lease.landlord)} />
        </p>
        <p className="hint">
          {formatToken(lease.deposit, tokenDecimals)} deposit + {lease.periods} × {formatToken(lease.rentPerPeriod, tokenDecimals)} rent,
          one period every {formatDuration(lease.periodSeconds)}. You prepay {amount}.
        </p>
      </div>
      <div className="fund-actions">
        <button
          type="button"
          className="btn"
          disabled={approved || approveTx.busy || !escrow}
          onClick={() =>
            approveTx.run({ address: token, abi: erc20Abi, functionName: 'approve', args: [escrow!, due] }, `Approve ${amount} for lease #${lease.id}`)
          }
        >
          {approved ? 'Approved' : `Approve ${amount}`}
        </button>
        <button
          type="button"
          className="btn btn-primary"
          disabled={!approved || !enough || fundTx.busy}
          onClick={() =>
            fundTx.run({ address: escrow!, abi: rentEscrowAbi, functionName: 'fundLease', args: [lease.id] }, `Fund lease #${lease.id}`)
          }
        >
          Fund lease
        </button>
      </div>
      {!enough && balance !== undefined ? (
        <p className="status status-bad">You need {amount} and hold {formatToken(balance, tokenDecimals)}.</p>
      ) : null}
      <TxStatus state={approveTx.state} done="Escrow approved to pull the exact amount." />
      <TxStatus state={fundTx.state} done="Lease funded. Rent starts unlocking now; follow it under Run the lease." />
    </li>
  )
}

export function FundPanel() {
  const { escrow, token, tokenDecimals, tokenSymbol, escrowError } = useContracts()
  const { address, isConnected } = useWallet()
  const { data: myName } = useRentoutsName(address)
  const leases = useLeases(escrow)
  const { data: balance } = useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    chainId: sepolia.id,
    query: { enabled: !!address },
  })
  const { data: eth } = useBalance({ address, chainId: sepolia.id })

  const mine = (leases.data ?? []).filter((l) => address && l.tenant.toLowerCase() === address.toLowerCase())
  const waiting = mine.filter((l) => l.state === LeaseState.CREATED)

  return (
    <div className="stack">
      <div>
        <h2>Fund the lease</h2>
        <p className="lede">
          The tenant approves the escrow for the exact amount, then prepays deposit and rent in one transaction. From
          then on only the contract moves the money: to the landlord as rent, back to the tenant as deposit.
        </p>
      </div>

      {isConnected && address ? (
        <dl className="balances">
          <div>
            <dt>{tokenSymbol} balance</dt>
            <dd>{balance !== undefined ? formatToken(balance, tokenDecimals) : '…'}</dd>
          </div>
          <div>
            <dt>Sepolia ETH for gas</dt>
            <dd>{eth ? Number(eth.formatted).toFixed(4) : '…'}</dd>
          </div>
        </dl>
      ) : (
        <Notice>Connect MetaMask to see your balance and the leases waiting for you.</Notice>
      )}
      <p className="hint">
        Need test funds? The <ExtLink href="https://ethglobal.com/faucet">ETHGlobal faucet</ExtLink> gives 0.05 Sepolia ETH
        and 1 USDC; <ExtLink href="https://faucet.circle.com">Circle’s faucet</ExtLink> gives more USDC.
      </p>

      {escrowError ? <Notice tone="error">{escrowError}</Notice> : null}
      {!escrow ? (
        <NotConfigured what="The escrow" envVar="VITE_ESCROW_ADDRESS" />
      ) : !address ? null : leases.isPending ? (
        <p className="hint">Reading leases…</p>
      ) : waiting.length === 0 ? (
        <Empty title="No leases are waiting for your funding">
          <p>
            Ask the landlord to create one for {myName || address}. It appears here as soon as it’s on-chain.
            {mine.length > 0 ? (
              <>
                {' '}
                Your funded leases are under <a href="#run">Run the lease</a>.
              </>
            ) : null}
          </p>
        </Empty>
      ) : (
        <ul className="list">
          {waiting.map((lease) => (
            <FundRow key={String(lease.id)} lease={lease} account={address} balance={balance} />
          ))}
        </ul>
      )}
    </div>
  )
}
