# Design decisions

Short architecture decision records (ADRs) for RentOuts Escrow at ETHGlobal Tokyo 2026. Each one gives the context, the decision and its consequences. The timestamped history, with transaction hashes, is in [`docs/ens/LOG.md`](./ens/LOG.md). The system itself is described in [ARCHITECTURE.md](./ARCHITECTURE.md).

| # | Decision | Status |
|---|---|---|
| [01](#adr-01-one-chain-ethereum-sepolia-for-everything) | One chain: Ethereum Sepolia for everything | accepted (Fri 22:40 JST) |
| [02](#adr-02-non-custodial-escrow-with-full-prepayment-and-short-periods) | Non-custodial escrow with full prepayment and short periods | accepted, built |
| [03](#adr-03-one-fixed-arbiter-that-can-only-split) | One fixed arbiter that can only split | accepted, built |
| [04](#adr-04-circles-test-usdc-as-the-escrow-token) | Circle's test USDC as the escrow token | accepted (Fri 22:40 JST) |
| [05](#adr-05-credentials-derived-on-chain-by-a-permissionless-credentialsync) | Credentials derived on-chain by a permissionless `CredentialSync` | accepted, built, not yet deployed |
| [06](#adr-06-soulbound-through-ens-roles-not-a-custom-nft) | Soulbound through ENS roles, not a custom NFT | accepted, live |
| [07](#adr-07-names-never-expire-revocation-is-the-only-end-labels-are-single-use) | Names never expire; revocation is the only end; labels are single-use | accepted, live |
| [08](#adr-08-a-separate-issuer-eoa-with-key-scoped-ens-roles) | A separate issuer EOA with key-scoped ENS roles | accepted, live (role cleanup pending) |
| [09](#adr-09-lease-shares-minted-to-an-allowlisted-landlord-at-createlease) | Lease shares minted to an allowlisted landlord at `createLease` | accepted, built |
| [10](#adr-10-world-id-deferred-behind-an-optional-human-gate) | World ID deferred behind an optional human gate | accepted; seam in progress |

---

## ADR-01: One chain, Ethereum Sepolia for everything

**Context.** The ENSv2 beta (contracts-v2 tag `sepolia-deployment-2026-09-15`) exists only on Ethereum Sepolia, and ENS v1 registration there is switched off, so v2 is the only on-chain ENS path. The original brief put the escrow on Base Sepolia and ENS on Ethereum Sepolia, with an off-chain relayer copying escrow events into ENS records. Dean's `LeaseShare1155` was deployed to Base Sepolia first.

**Decision.** `RentEscrow`, `LeaseShare1155`, `CredentialSync` and the ENS contracts all live on Ethereum Sepolia (11155111).

**Consequences.**
- One contract can read another, so credentials can be derived on-chain ([ADR-05](#adr-05-credentials-derived-on-chain-by-a-permissionless-credentialsync)) instead of trusting a relayer.
- One network in the wallet and one explorer, which keeps the demo simpler.
- The Base Sepolia `LeaseShare1155` stays up as a standalone Curvegrid proof. The integrated share contract is a fresh deploy on Sepolia.
- Names still resolve on Base: the ENSIP-19 default EVM address record answers every EVM chain.
- Sepolia ENS is reset every few weeks, so every ENS deploy phase is re-runnable.

## ADR-02: Non-custodial escrow with full prepayment and short periods

**Context.** Judges need to see a whole lease (fund → rent → close) in a few minutes. They also need to see that neither RentOuts nor the landlord ever holds the tenant's money.

**Decision.**
- `RentEscrow` has no owner, admin, fee or upgradeability. Its `token`, `arbiter` and `leaseShare` are immutable.
- The tenant prepays the deposit and all rent in `fundLease`. Rent unlocks one period at a time, and a period can be as short as `MIN_PERIOD = 60` seconds.
- `claimRent` is permissionless and can only pay the landlord.
- `closeLease` is open to the landlord at `endTime` and to anyone one period later. That grace period gives the landlord time to dispute the deposit.

**Consequences.**
- There is no missed-payment state, so the state machine is small and four invariants cover the money ([ARCHITECTURE §6](./ARCHITECTURE.md#6-invariants-and-how-they-are-tested)).
- The tenant locks the whole term up front. That's fine for a demo lease measured in cents and minutes, but a real lease needs installments or streaming.
- With no late-payment concept, `rentouts.onTimeRate` can't be derived and stays an issuer judgment ([ADR-08](#adr-08-a-separate-issuer-eoa-with-key-scoped-ens-roles)).

## ADR-03: One fixed arbiter that can only split

**Context.** Deposits need a dispute path. A court, a DAO or an optimistic oracle is out of scope for a weekend.

**Decision.**
- The arbiter is an immutable address. `resolveDispute(id, tenantBps)` can only split a `DISPUTED` lease's remaining escrow between that lease's tenant and landlord. The tenant's share is rounded down and the landlord gets the rest.
- The arbiter can never be a party: `createLease` reverts `InvalidTerms` if the landlord or the tenant is the arbiter, and `DeployEscrow` refuses `ESCROW_ARBITER == deployer`.
- On testnet the arbiter is a single EOA (`0x798b…e486`). In production it would be a Safe multisig.

**Consequences.**
- The arbiter can't take funds or pay a third party (INV-1, INV-4, both tested).
- It still decides the split, and a disputed lease stays frozen until it rules. There is no timeout.
- Changing the arbiter means deploying a new escrow.

## ADR-04: Circle's test USDC as the escrow token

**Context.** There were three candidates:
- ENS's Sepolia MockUSDC, which has an open `mint` and an open `nuke(owner)` that burns anyone's balance;
- a mock token of our own;
- Circle's USDC on Sepolia.

**Decision.** Use Circle's USDC, `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (6 decimals), available from the ETHGlobal and Circle faucets. A mock token stays available as a deploy-time fallback (`ESCROW_TOKEN`). ENS's MockUSDC is used only to pay the ENS registration fee.

**Consequences.**
- "USDC escrow" is literally true, and nobody can burn the escrow's balance.
- Faucet amounts are small (1 USDC per ETHGlobal claim), so demo leases are sized in cents.

## ADR-05: Credentials derived on-chain by a permissionless CredentialSync

**Context.** The brief had an off-chain relayer write a tenant's reputation into ENS. That is a trusted server deciding the numbers.

**Decision.**
- `CredentialSync.sync(tenant)` can be called by anyone. It reads `RentEscrow.tenantStats(tenant)` and writes five keys through `RentoutsSubnames.setCredential`: `leasesCompleted`, `disputes`, `rentPaid`, `depositReturnRate` and `escrow` (a CAIP-10 id). `CredentialSync` is an issuer contract.
- Only judgments the escrow can't derive (`onTimeRate`, `rating`, `verified`) stay with the issuer EOA.

**Consequences.**
- The derived values are a pure function of public escrow state. Anyone can recompute them, restore them with `sync`, or compare them with `tenantStats` before trusting them. No RentOuts API sits in the read path.
- Records only change when someone calls `sync`. The app shows when ENS is behind the escrow and offers a Sync button.
- The derived keys are verifiable but not write-protected. Any `RentoutsSubnames` issuer can still overwrite them through `setCredential` until the admin removes it, and `sync` restores them. This is stated in the trust model.
- A sync costs about 210k–350k gas (5 text records).

## ADR-06: Soulbound through ENS roles, not a custom NFT

**Context.** A rental credential must not be sellable, and the ENS track rewards real ENSv2 primitives over cosmetic ones.

**Decision.**
- Subnames live in our own `UserRegistry` proxy and are registered with a **token role bitmap of 0**.
- Without `ROLE_CAN_TRANSFER_ADMIN`, `unsafeTransfer` reverts `TransferDisallowed`. The registry is left un-emancipated, so ERC-1155 safe transfers revert `TransferUnsafeUntilRegistryIsEmancipated`.
- The holder also gets no `SET_RESOLVER`, `SET_SUBREGISTRY` or `UNREGISTER` role.

**Consequences.**
- ENS itself enforces soulbound transfers. Both reverts were confirmed against the live `alice.rentouts.eth`.
- The holder can't detach its credential by pointing the name at another resolver.
- Names are **deliberately not emancipated**: the registry root (RentOuts, through `RentoutsSubnames`) keeps `UNREGISTER`. That makes revocation possible ([ADR-07](#adr-07-names-never-expire-revocation-is-the-only-end-labels-are-single-use)), and it is a trust choice we state openly.

## ADR-07: Names never expire, revocation is the only end, labels are single-use

**Context.**
- An expiring credential could vanish in the middle of a lease.
- A revoked name must stop resolving. Because subnames share the parent's `PermissionedResolver`, the Universal Resolver would otherwise still find the old records through `rentouts.eth` after `unregister`.

**Decision.**
- Subnames get `expiry = 2^64 − 1`. The parent's expiry already bounds resolution.
- `revoke(label, reason)` is issuer-only. It runs `linkToRecord(name, 0)` to detach every old record, writes a fresh record holding only `rentouts.status = revoked`, calls `unregister` to burn the token, and retires the label.
- A label can never be registered again, even by a redeployed `RentoutsSubnames`, because `register` requires the registry expiry to still be 0.

**Consequences.**
- A revoked name resolves to address 0 and status `revoked`; its stats and profile are gone.
- The same person can claim a new label (for example `alice-2`).
- A null `getEnsAddress` no longer means a label is free, so the app checks availability by simulating `register`.

## ADR-08: A separate issuer EOA with key-scoped ENS roles

**Context.** `PermissionedResolver` roles are scoped per record key (or root), not per name. The deployer holds root roles, so with the deployer as issuer the "issuer can't write `avatar`" check would pass for the wrong reason.

**Decision.**
- The issuer is its own EOA, `0xF604…13C4`. Through `grantSetterRoles` it holds key-scoped `SET_TEXT` on `rentouts.onTimeRate`, `rentouts.rating` and `rentouts.verified` only, and no root resolver role.
- The deploy script refuses issuer == deployer and revokes any issuer role on an escrow-derived key.
- `removeIssuer` removes both the contract right and the resolver roles.
- Holders never get raw resolver roles. They edit allowlisted profile keys through `setProfileText`.

**Consequences.**
- ENS's access control enforces "the issuer can write `rentouts.rating` but not `avatar`", and one `cast call` shows it (see [DEMO.md](./DEMO.md#optional-cli-proofs)).
- A key-scoped role applies to every name under the resolver. That's acceptable because the issuer is RentOuts.
- The first live deploy also granted the issuer three escrow-derived keys. Re-running the `subnames` phase revokes them.

<!-- VERIFY: the issuer role cleanup broadcast (3 revokeRoles txs). A live read at 23:10 JST still showed SET_TEXT on rentouts.leasesCompleted, rentouts.disputes and rentouts.escrow. -->

## ADR-09: Lease shares minted to an allowlisted landlord at createLease

**Context.** The Curvegrid track asks for tokenized real-world assets with compliance-aware transfer logic. Dean built `LeaseShare1155` first, with the allowlist check in OpenZeppelin v5's `_update` hook, and proved it standalone on Base Sepolia.

**Decision.**
- `RentEscrow` is the share contract's minter. `createLease` mints `SHARES_PER_LEASE = 100` shares with `tokenId = leaseId` to the landlord.
- Because the landlord must be allowlisted to receive them, listing a lease is itself compliance-gated.
- There is one `LeaseShare1155` per `RentEscrow`. The deploy script refuses a share contract that is already wired to an escrow.

**Consequences.**
- Every lease is an RWA position from the moment it is listed, and single and batch transfers only reach allowlisted wallets.
- A share records the lease position. It is not a cash-flow right: rent goes to `lease.landlord`, not pro rata to share holders.
- There is no burn, so shares of a cancelled lease stay with the landlord. The share owner (the deployer) controls the allowlist and can mint directly.

## ADR-10: World ID deferred behind an optional human gate

**Context.** Proof of personhood for tenants (World ID) was in the original plan. The escrow and ENS spine had to work first, and a World integration needs its own testing time.

**Decision.** World ID moves to Saturday. `RentEscrow` gets an optional gate address, where `0` means disabled. When a gate is set, `fundLease` requires `isVerified(tenant)`.

<!-- VERIFY: the human gate seam is being added to RentEscrow right now. Confirm the parameter name, the interface (isVerified(address) -> bool), the revert error, and whether IRentEscrow (and its copy in ens/) changes. -->

**Consequences.**
- Adding World later is a deploy-time address, not a rewrite of the escrow. The issuer can reflect a passed check in `rentouts.verified`.
- Until then there is no proof of personhood. One name per address is the only sybil friction.
