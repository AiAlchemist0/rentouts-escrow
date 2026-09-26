# Design decisions

Short architecture decision records (ADRs) for RentOuts Escrow at ETHGlobal Tokyo 2026. Each one gives the context, the decision and its consequences. The timestamped history, with transaction hashes, is in [`docs/ens/LOG.md`](./ens/LOG.md). The system itself is described in [ARCHITECTURE.md](../ARCHITECTURE.md).

| # | Decision | Status |
|---|---|---|
| [01](#adr-01-one-chain-ethereum-sepolia-for-everything) | One chain: Ethereum Sepolia for everything | accepted (Fri 22:40 JST) |
| [02](#adr-02-non-custodial-escrow-with-full-prepayment-and-short-periods) | Non-custodial escrow with full prepayment and short periods | accepted, live |
| [03](#adr-03-one-fixed-arbiter-that-can-only-split) | One fixed arbiter that can only split | accepted, live; the arbiter is the `AIArbiter` contract ([ADR-11](#adr-11-an-ai-judge-that-only-proposes-a-human-has-the-last-word)) |
| [04](#adr-04-circles-test-usdc-as-the-escrow-token) | Circle's test USDC as the escrow token | accepted (Fri 22:40 JST) |
| [05](#adr-05-credentials-derived-on-chain-by-a-permissionless-credentialsync) | Credentials derived on-chain by a permissionless `CredentialSync` | accepted, live (Sat 03:08 JST) |
| [06](#adr-06-soulbound-through-ens-roles-not-a-custom-nft) | Soulbound through ENS roles, not a custom NFT | accepted, live |
| [07](#adr-07-names-never-expire-revocation-is-the-only-end-labels-are-single-use) | Names never expire; revocation is the only end; labels are single-use | accepted, live |
| [08](#adr-08-a-separate-issuer-eoa-with-key-scoped-ens-roles) | A separate issuer EOA with key-scoped ENS roles | accepted, live (role cleanup done Sat 03:09 JST) |
| [09](#adr-09-lease-shares-minted-to-an-allowlisted-landlord-at-createlease) | Lease shares minted to an allowlisted landlord at `createLease` | accepted, live |
| [10](#adr-10-world-id-behind-a-human-gate-seam-that-only-gates-new-funding) | World ID behind a human-gate seam that only gates new funding | accepted, live (gate open); World verifier next |
| [11](#adr-11-an-ai-judge-that-only-proposes-a-human-has-the-last-word) | An AI judge that only proposes; a human has the last word | accepted, live (`AIArbiter`, Sat 03:05 JST) |

---

## ADR-01: One chain, Ethereum Sepolia for everything

**Context.** The ENSv2 beta (contracts-v2 tag `sepolia-deployment-2026-09-15`) exists only on Ethereum Sepolia, and ENS v1 registration there is switched off, so v2 is the only on-chain ENS path. The original brief put the escrow on Base Sepolia and ENS on Ethereum Sepolia, with an off-chain relayer copying escrow events into ENS records. Dean's `LeaseShare1155` was deployed to Base Sepolia first.

**Decision.** `RentEscrow`, `HumanGate`, `AIArbiter`, `LeaseShare1155`, `CredentialSync` and the ENS contracts all live on Ethereum Sepolia (11155111).

**Consequences.**
- One contract can read another, so credentials can be derived on-chain ([ADR-05](#adr-05-credentials-derived-on-chain-by-a-permissionless-credentialsync)) instead of trusting a relayer.
- One network in the wallet and one explorer, which keeps the demo simpler.
- The Base Sepolia `LeaseShare1155` stays up as a standalone Curvegrid proof. The integrated share contract is a fresh deploy on Sepolia.
- Names still resolve on Base: the ENSIP-19 default EVM address record answers every EVM chain.
- Sepolia ENS is reset every few weeks, so every ENS deploy phase is re-runnable.

## ADR-02: Non-custodial escrow with full prepayment and short periods

**Context.** Judges need to see a whole lease (fund → rent → close) in a few minutes. They also need to see that neither RentOuts nor the landlord ever holds the tenant's money.

**Decision.**
- `RentEscrow` has no owner, admin, fee or upgradeability. Its `token`, `arbiter`, `leaseShare` and `humanGate` are immutable.
- The tenant prepays the deposit and all rent in `fundLease`. Rent unlocks one period at a time, and a period can be as short as `MIN_PERIOD = 60` seconds.
- `claimRent` is permissionless and can only pay the landlord.
- `closeLease` is open to the landlord at `endTime` and to anyone one period later. That grace period gives the landlord time to dispute the deposit.

**Consequences.**
- There is no missed-payment state, so the state machine is small and four invariants cover the money ([ARCHITECTURE §8](../ARCHITECTURE.md#8-invariants-and-how-they-are-tested)).
- The tenant locks the whole term up front. That's fine for a demo lease measured in cents and minutes, but a real lease needs installments or streaming.
- With no late-payment concept, `rentouts.onTimeRate` can't be derived and stays an issuer judgment ([ADR-08](#adr-08-a-separate-issuer-eoa-with-key-scoped-ens-roles)).

## ADR-03: One fixed arbiter that can only split

**Context.** Deposits need a dispute path. A court, a DAO or an optimistic oracle is out of scope for a weekend.

**Decision.**
- The arbiter is an immutable address. `resolveDispute(id, tenantBps)` can only split a `DISPUTED` lease's remaining escrow between that lease's tenant and landlord. The tenant's share is rounded down and the landlord gets the rest.
- The arbiter can never be a party: `createLease` reverts `InvalidTerms` if the landlord or the tenant is the arbiter, and `DeployEscrow` refuses `ESCROW_ARBITER == deployer`.
- The escrow only checks `msg.sender == arbiter`, so the arbiter can be an EOA or a contract. For the demo it is the `AIArbiter` contract ([ADR-11](#adr-11-an-ai-judge-that-only-proposes-a-human-has-the-last-word)), with the human arbiter EOA `0x798b…e486` behind it. In production the human would be a Safe multisig.

**Consequences.**
- The arbiter can't take funds or pay a third party (INV-1, INV-4, both tested).
- It still decides the split, and a disputed lease stays frozen until a ruling. There is no timeout.
- Changing the arbiter contract means deploying a new escrow. Inside `AIArbiter`, the human can rotate the AI key, hand over the human role or change the challenge window without touching the escrow.

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
- ENS itself enforces soulbound transfers. Both reverts were confirmed against the live `alice.rentouts.eth` (re-checked Sat 01:22 JST).
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
- The `subnames` deploy phase refuses an issuer that holds root `SET_TEXT` on the resolver (such as the deployer), and revokes any issuer role on an escrow-derived key.
- The `removeIssuer` deploy phase takes away both the contract right (`setIssuer(x, false)`) and the issuer's resolver key roles.
- Holders never get raw resolver roles. They edit allowlisted profile keys through `setProfileText`.

**Consequences.**
- ENS's access control enforces "the issuer can write `rentouts.rating` but not `avatar`", and one `cast call` shows it (see [DEMO.md](./DEMO.md#optional-cli-proofs)).
- A key-scoped role applies to every name under the resolver. That's acceptable because the issuer is RentOuts.
- The first live deploy also granted the issuer three escrow-derived keys (`leasesCompleted`, `disputes`, `escrow`). Re-running the `subnames` phase revoked them on Sat 03:09 JST (three `revokeRoles` transactions, [ARCHITECTURE §3](../ARCHITECTURE.md#3-roles-and-trust-model)). A direct write by the issuer now reverts on all five escrow-derived keys.

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

## ADR-10: World ID behind a human-gate seam that only gates new funding

**Context.** Proof of personhood for tenants (World ID) is part of the plan. The escrow and ENS spine had to work first, and a World integration needs its own testing time. But `RentEscrow` has no owner and cannot change after deployment, so World can't simply be added to it later.

**Decision.**
- `RentEscrow` takes a `humanGate` address once, as an immutable constructor argument. `address(0)` means funding is never gated on that escrow.
- `fundLease` is the only function that asks the gate: it reverts `NotVerifiedHuman(tenant)` unless `humanGate.isVerified(tenant)`. The check is a view call made before any state change.
- By default `DeployEscrow` deploys a `HumanGate` owned by the deployer with `verifier = 0`, so the gate starts **open** and every tenant passes.
- World plugs in with `HumanGate.setVerifier(worldVerifier)`: any contract that implements `isVerified(address) returns (bool)`. The escrow is not redeployed. Setting the verifier back to `0` reopens the gate.

**Consequences.**
- The gate owner decides only **who may fund a new lease**. It holds no tokens and cannot move, freeze or redirect funds. `claimRent`, `closeLease`, `openDispute` and `resolveDispute` never consult it, so a funded lease runs to the end whatever the gate says (tested).
- A verifier that reverts makes funding fail closed until the owner fixes or clears it. `setVerifier` refuses a non-contract (`VerifierHasNoCode`).
- The World verifier is set: `HumanGate.verifier` is `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`, and only a registered wallet can fund a new lease. One name per address remains the ENS sybil friction. The issuer can reflect a passed check in `rentouts.verified`.
- The owner is a single EOA on testnet; in production it would be a Safe.

## ADR-11: An AI judge that only proposes; a human has the last word

**Context.** A single human arbiter is slow, and a bottleneck when many small disputes arrive. An LLM can read both sides' statements and answer in seconds. But an LLM can be confidently wrong, its probabilities are not calibrated, and both parties write the evidence it reads, so either can try to sway it with a plausible false statement.

**Decision.**
- `RentEscrow`'s immutable arbiter is the `AIArbiter` contract. Its only state-changing call is `escrow.resolveDispute` (invariant AI-1), and it holds no tokens.
- Parties post short statements on-chain (`submitEvidence`: 1–1000 bytes, at most 5 per party, stored as events).
- The judge service (`judge/`, z.ai GLM 5.3) asks the model a fixed set of typed questions: damage beyond normal wear, whether the landlord's claim to the unearned rent is valid, whether the evidence is sufficient (each yes/no with a probability), a severity from 1 to 5, and a short rationale.
- **Code, not the model, computes `tenantBps`** from those answers with a fixed rubric, rounded to 25 % steps.
- The judge **abstains** (no proposal; the human decides) when the evidence is insufficient, when an answer the payout rests on has a probability below 0.7, when only one party has posted, or when a statement is flagged by the injection screen in code. With no statements at all it does not call the model.
- A proposal carries `rulingHash`, the keccak256 of the canonical JSON ruling, so anyone can check what was decided and from which inputs.
- A proposal only executes after a **challenge window** (120 s in the demo, 60 s to 30 days allowed) in which either party can appeal. After an appeal, only the human can rule.
- The **human arbiter** (`0x798b…e486`) can rule directly or override an unexecuted proposal at any time. It hands its role over in two steps (`setHuman`, then `acceptHuman` from the new address), so a typo can't strand appealed leases.

**Consequences.**
- A bad AI answer, a manipulated one, or even a stolen AI or human key can at worst split one disputed lease's own escrow wrongly between its tenant and landlord. It can never pay anyone else (INV-1, INV-4, AI-1..AI-3, all tested).
- The model never sees the tenant's track record, only its identity, so past disputes don't bias a ruling that then feeds back into that record.
- Statements are public on-chain, and the model provider receives them.
- The human route has no deadline, and an appeal costs only gas. A production version would add an appeal bond and a service-level deadline.
- Text only: the judge can't check photos, documents or invoices a statement mentions.
