# RentOuts Escrow: demo app

A one-page demo of the whole flow on **Ethereum Sepolia**: a tenant claims a soulbound ENSv2 name, a landlord
creates a lease for that name, the tenant prepays deposit and rent in USDC, rent is released period by period,
and the finished lease is written back to the tenant's ENS credential. A disputed lease goes to an AI judge
contract with a human arbiter: the AI only proposes a split, and the human can always override it. It's a demo
for judges, not a product.

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

Contract addresses come from the repo-root [`../deployments.json`](../deployments.json), which the deploy
scripts write: `script/DeployEscrow.s.sol` writes the `"sepolia"` entry (`rentEscrow`, `leaseShare1155`,
`humanGate`, `token`, `arbiter`) and `script/DeployAIArbiter.s.sol` writes `"sepoliaAIArbiter"` (`aiArbiter`,
`fromBlock`, …). The file is read at build time. If it or an entry is missing, that contract counts as not
deployed and its screens say so.

Any `VITE_*` variable overrides the file. Copy `.env.example` to `.env.local`. Every value is optional, and the
ENS screens work with none of them.

| Variable | Default | Purpose |
|---|---|---|
| `VITE_SEPOLIA_RPC_URL` | `https://ethereum-sepolia-rpc.publicnode.com` | Read RPC |
| `VITE_ESCROW_ADDRESS` | `sepolia.rentEscrow` | `RentEscrow`. With neither set, the lease screens say “escrow not configured” |
| `VITE_AI_ARBITER_ADDRESS` | `sepoliaAIArbiter.aiArbiter` | `AIArbiter`, the escrow's arbiter. With neither set, the app checks whether `RentEscrow.arbiter()` is an AIArbiter |
| `VITE_LEASE_SHARE_ADDRESS` | `sepolia.leaseShare1155` | `LeaseShare1155` (Curvegrid RWA). When the escrow is read, `RentEscrow.leaseShare()` wins |
| `VITE_CREDENTIAL_SYNC_ADDRESS` | not set | `CredentialSync` for the “Sync credential to ENS” button |
| `VITE_TOKEN_ADDRESS` | `sepolia.token`, else Circle USDC `0x1c7D…7238` | Escrow token. When the escrow is read, `RentEscrow.token()` wins |

If `VITE_ESCROW_ADDRESS` points at a different escrow from the one recorded in the file, the record's
lease-share, token, gate and arbiter are ignored, because they belong to the recorded escrow.

The ENS addresses aren't env vars. They're imported from [`../ens/deployments/sepolia.json`](../ens/deployments/sepolia.json),
which the ENS deploy script writes.

## What each step shows

| Step | Who | What it demonstrates |
|---|---|---|
| Connect | anyone | Injected wallet only. On another network, a banner offers to switch to Sepolia. Reads work without a wallet |
| 1. Claim your name | tenant | `RentoutsSubnames.register(label, you)`. The label is checked with viem `normalize()` (ENSIP-15) plus the contract's own rule. Availability is a `simulateContract(register)`, so taken, retired and one-name-per-address all come back as readable messages. Once you hold a name, you see your credential card |
| Credential card | anyone | `getEnsAddress` and `getEnsText` for `rentouts.credential`, `.status`, `.leasesCompleted`, `.disputes`, `.rentPaid`, `.depositReturnRate` and `.rating`, all through the ENSv2 Universal Resolver. Stats are shown only if `status == active` **and** the name resolves to the holder `RentoutsSubnames.holderOf(labelhash)` has on record. The card links to the ENS app, the claim transaction on Etherscan and the resolver. It also compares ENS with the escrow's `tenantStats` and offers a sync when ENS is behind. `?name=alice.rentouts.eth` opens a lookup directly |
| 2. Create a lease | landlord | The tenant is entered as an **ENS name** (or a 0x address). The name is resolved live through the Universal Resolver, and the tenant's credential is shown before you sign. Amounts are in USDC (6 decimals). The defaults are a 120 s period and 3 periods. The app warns if the landlord isn't on the lease-share allowlist, which would make `createLease` revert |
| 3. Fund the lease | tenant | Your USDC and ETH balances, then `approve` for the exact amount and `fundLease`. If `RentEscrow.humanGate()` is set, a “Human verification required (World ID — coming soon)” notice explains the gate. The app reads `isVerified(you)` and `verifier()` (open gate = everyone passes) and disables both buttons for a wallet the gate rejects. A `NotVerifiedHuman` revert reads as a sentence |
| 4. Run the lease | both, AI judge, human arbiter | Every lease you're part of (or all of them), with its state, a per-period bar, a countdown to the next unlock, what's in escrow and what's claimable. Buttons: release rent (`claimRent`), `closeLease`, `openDispute` and `cancelLease`. A disputed lease shows the **AI dispute judge** panel (below). Closed leases offer `CredentialSync.sync(tenant)`, after which the card refetches |
| 5. Lease shares | landlord | Curvegrid RWA: your `LeaseShare1155` balance per lease (token id = lease id) and a transfer form. The recipient can be an ENS name. The allowlist is checked before sending, and a `NotAllowlisted` revert is explained in plain words |

### AI dispute judge

The escrow's arbiter is the `AIArbiter` contract (`src/AIArbiter.sol`, with the GLM 5.3 judge service in
`judge/`). No wallet can be the arbiter, so every disputed lease gets this panel instead of a resolve button:

- **State badge**, from `getRuling(leaseId)`: *Awaiting evidence*, *Proposed*, *Appealed*, *Executed* or
  *Resolved by human*. One line under it says that the AI only proposes and the human arbiter can always
  override it.
- **Statements.** The tenant and the landlord each get a text box (`submitEvidence`, at most 5 statements of
  1,000 bytes each). The byte count is checked before signing. Both sides' statements are read from the
  `Evidence` events, each with its Etherscan link.
- **The proposal.** Shows the tenant's share as a percentage, a split bar, and what each side would receive
  from the current escrow. Also shown: the judge's confidence, its one-line summary (from the `Proposed` event),
  the `rulingHash`, "proposed by the AI judge" with the judge key, and a live countdown to the end of the
  challenge window. The page doesn't name the model: the `Proposed` event doesn't record it, but the
  `rulingHash` commits to it (`npm run judge -- --verify`).
- **Appeal**: for the tenant or landlord, inside the window. **Execute**: for anyone, once the window is over
  and nobody appealed. Before that the button shows a countdown.
- **Resolve as human arbiter**: only for the wallet that is `AIArbiter.human()`, with a percentage slider
  (`resolveByHuman`). It starts at the AI's figure and works with or without a proposal, before or after an
  appeal. Disputes the human has seen stay listed after they close, so the result stays on screen.
- A lease closed through AIArbiter keeps the record: the final split, the AI's proposal if the human overruled
  it, the summary and the hash.

The app finds the AIArbiter from `VITE_AI_ARBITER_ADDRESS`, then `deployments.json`, then
`RentEscrow.arbiter()`. It warns if the contract isn't bound to this escrow (`bindEscrow`) or isn't this
escrow's arbiter. Statements and summaries are read with one `eth_getLogs` for the whole contract. The scan
starts at the recorded `fromBlock` or 49k blocks back, whichever is later, because public RPCs cap log ranges.

Every transaction goes through simulate, then sign, then wait. It gets a Sepolia Etherscan link in the card
and in a “recent transactions” strip, which stays visible even after the card that sent it disappears. Contract
errors are decoded against every ABI in the app, so an error from `LeaseShare1155` that surfaces through the
escrow still reads as a sentence.

**Nothing is hard-coded.** The parent name comes from `RentoutsSubnames.parentName()`, names and records come
from the Universal Resolver, and leases are read by walking `1..nextLeaseId-1` with multicalls. The app doesn't
use `eth_getLogs` for leases, because public RPCs cap log ranges.

## Checks

```bash
npm test               # vitest: label validation, address input, USDC formatting, lease timing and parties, error mapping, trust check, human-gate notice, deployments.json + env resolution, AI judge state / countdown / bps <-> %
npm run typecheck      # tsc --noEmit
npm run build          # typecheck + vite build
npm run ens:smoke      # live ENSv2 read on Sepolia, no wallet
npm run live:smoke     # live read of the configured contracts on Sepolia: checks they point at each other
```

`live:smoke` resolves addresses the way the app does (`VITE_*`, then `deployments.json`, then the escrow's
getters) and checks `RentEscrow.arbiter()` = the AIArbiter, `AIArbiter.escrow()`, `RentEscrow.leaseShare()`,
`LeaseShare1155.minter()`, `RentEscrow.humanGate()`, `CredentialSync.escrow()` / `.subnames()` and the
issuer role on `RentoutsSubnames`. It exits 1 on any mismatch.

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

We tested the AI dispute judge panel the same way (Sat 2026-09-26). The contracts were `feat/ai-judge`'s
`AIArbiter` and `RentEscrow`, with a 120 s window. On the fork we checked the tenant's and landlord's
statements, the proposal card with its live countdown, an appeal inside the window, an execute by a
non-party after the window, and the human arbiter overruling an appealed proposal (40 % against the AI's 25 %).
We also checked the over-long statement guard, the executed and resolved-by-human records, and a 390 px layout.

## Honest limits

- Testnet only. The money is Circle **test** USDC.
- Disputes go to an AI judge contract with a human arbiter. The AI judge only proposes, and the human arbiter
  can always override it. On testnet the human arbiter is one key; in production it would be a Safe multisig.
  An appealed lease stays frozen until the human rules. The escrow refuses a lease where the arbiter is the
  landlord or the tenant, and the app checks this before you sign.
- The judge service runs off-chain (`judge/`). The team starts it for a disputed lease, so a proposal isn't
  instant. If the judge abstains, the lease waits for the human arbiter.
- World ID isn't integrated. The escrow has a human-gate seam (`humanGate()`); while its `HumanGate` has no
  verifier, every wallet passes. The app can't verify anyone itself.
- The ENS app (`sepolia.app.ens.domains`) may not display ENSv2 beta names yet. The Etherscan links and the
  in-app reads are the source of truth.
- `CredentialSync` wasn't deployed when this was written. The app calls only `sync(address)` and shows
  `rentouts.*` values exactly as written. A bare number gets a unit, so `rentPaid` gets “USDC” and
  `depositReturnRate` gets “%”. `CredentialSync` should therefore write human units (e.g. `0.60`), not raw token
  units.
