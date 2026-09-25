# RentOuts Escrow: demo app

A one-page demo of the whole flow on **Ethereum Sepolia**: a tenant claims a soulbound ENSv2 name, a landlord
creates a lease for that name, the tenant prepays deposit and rent in USDC, rent is released period by period,
and the finished lease is written back to the tenant's ENS credential. It's a demo for judges, not a product.

Stack: Vite, React, TypeScript, wagmi v2, viem 2.56 (ENS reads go through the ENSv2 Universal Resolver), and
TanStack Query. Plain CSS. MetaMask (injected connector) only.

## Run it

```bash
cd app
npm ci
npm run dev            # http://localhost:5173
```

You need MetaMask on Ethereum Sepolia (the app offers to switch networks) and a little test money:

- **Sepolia ETH for gas**: the [ETHGlobal faucet](https://ethglobal.com/faucet) gives 0.05 ETH, which is plenty.
- **USDC**: the ETHGlobal faucet also gives 1 Circle test USDC. The default lease (0.25 deposit plus
  3 × 0.20 rent = 0.85 USDC) fits inside that. [Circle's faucet](https://faucet.circle.com) gives more.

A plain MetaMask account works. An account upgraded to a smart account (EIP-7702) has contract code, and ENS may
refuse to mint a name to it. The claim screen warns about this.

## Configuration

Copy `.env.example` to `.env.local`. Every value is optional, and the ENS screens work with none of them.

| Variable | Default | Purpose |
|---|---|---|
| `VITE_SEPOLIA_RPC_URL` | `https://ethereum-sepolia-rpc.publicnode.com` | Read RPC |
| `VITE_ESCROW_ADDRESS` | not set | `RentEscrow`. Until it's set, the lease screens say “escrow not configured” |
| `VITE_LEASE_SHARE_ADDRESS` | not set | `LeaseShare1155` (Curvegrid RWA). When the escrow is set, `RentEscrow.leaseShare()` wins |
| `VITE_CREDENTIAL_SYNC_ADDRESS` | not set | `CredentialSync` for the “Sync credential to ENS” button |
| `VITE_TOKEN_ADDRESS` | Circle USDC `0x1c7D…7238` | Escrow token. When the escrow is set, `RentEscrow.token()` wins |

The ENS addresses aren't env vars. They're imported from [`../ens/deployments/sepolia.json`](../ens/deployments/sepolia.json),
which the ENS deploy script writes.

## What each step shows

| Step | Who | What it demonstrates |
|---|---|---|
| Connect | anyone | Injected wallet only. On another network, a banner offers to switch to Sepolia. Reads work without a wallet |
| 1. Claim your name | tenant | `RentoutsSubnames.register(label, you)`. The label is checked with viem `normalize()` (ENSIP-15) plus the contract's own rule. Availability is a `simulateContract(register)`, so taken, retired and one-name-per-address all come back as readable messages. Once you hold a name, you see your credential card |
| Credential card | anyone | `getEnsAddress` and `getEnsText` for `rentouts.credential`, `.status`, `.leasesCompleted`, `.disputes`, `.rentPaid`, `.depositReturnRate` and `.rating`, all through the ENSv2 Universal Resolver. Stats are shown only if `status == active` **and** the name resolves to the holder `RentoutsSubnames.holderOf(labelhash)` has on record. The card links to the ENS app, the claim transaction on Etherscan and the resolver. It also compares ENS with the escrow's `tenantStats` and offers a sync when ENS is behind. `?name=alice.rentouts.eth` opens a lookup directly |
| 2. Create a lease | landlord | The tenant is entered as an **ENS name** (or a 0x address). The name is resolved live through the Universal Resolver, and the tenant's credential is shown before you sign. Amounts are in USDC (6 decimals). The defaults are a 120 s period and 3 periods. The app warns if the landlord isn't on the lease-share allowlist, which would make `createLease` revert |
| 3. Fund the lease | tenant | Your USDC and ETH balances, then `approve` for the exact amount and `fundLease` |
| 4. Run the lease | both, arbiter | Every lease you're part of (or all of them), with its state, a per-period bar, a countdown to the next unlock, what's in escrow and what's claimable. Buttons: release rent (`claimRent`), `closeLease`, `openDispute` and `cancelLease`. The arbiter gets `resolveDispute` with a tenant-share slider. Closed leases offer `CredentialSync.sync(tenant)`, after which the card refetches |
| 5. Lease shares | landlord | Curvegrid RWA: your `LeaseShare1155` balance per lease (token id = lease id) and a transfer form. The recipient can be an ENS name. The allowlist is checked before sending, and a `NotAllowlisted` revert is explained in plain words |

Every transaction goes through simulate, then sign, then wait. It gets a Sepolia Etherscan link in the card
and in a “recent transactions” strip, which stays visible even after the card that sent it disappears. Contract
errors are decoded against every ABI in the app, so an error from `LeaseShare1155` that surfaces through the
escrow still reads as a sentence.

**Nothing is hard-coded.** The parent name comes from `RentoutsSubnames.parentName()`, names and records come
from the Universal Resolver, and leases are read by walking `1..nextLeaseId-1` with multicalls. The app doesn't
use `eth_getLogs` for leases, because public RPCs cap log ranges.

## Checks

```bash
npm test               # vitest: label validation, USDC formatting, lease timing, error mapping, trust check
npm run typecheck      # tsc --noEmit
npm run build          # typecheck + vite build
npm run ens:smoke      # live ENSv2 read on Sepolia, no wallet
```

`ens:smoke` output (Fri 2026-09-25):

```
universal resolver  0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe (viem sepolia default: 0xeeeeeeee14d718c2b47d9923deab1335e144eeee)
name                alice.rentouts.eth
getEnsAddress       0x484811c8c967809bE644A89d677933c29fb9e936
getEnsText          rentouts.credential = "tenant/v1"
getEnsText          rentouts.status = "active"
```

Before `RentEscrow` was on Sepolia, we ran every write path once in headless Chrome against a local anvil fork
of Sepolia: claim a name, create a lease by ENS name, approve and fund, release rent, open a dispute, resolve it
as the arbiter, and a blocked share transfer. The escrow was the `feat/core-escrow` version, with a mock
6-decimal token.

## Honest limits

- Testnet only. The money is Circle **test** USDC.
- The arbiter is a single test account. In production it would be a Safe multisig.
- The ENS app (`sepolia.app.ens.domains`) may not display ENSv2 beta names yet. The Etherscan links and the
  in-app reads are the source of truth.
- `CredentialSync` wasn't deployed when this was written. The app calls only `sync(address)` and shows
  `rentouts.*` values exactly as written. A bare number gets a unit, so `rentPaid` gets “USDC” and
  `depositReturnRate` gets “%”. `CredentialSync` should therefore write human units (e.g. `0.60`), not raw token
  units.
