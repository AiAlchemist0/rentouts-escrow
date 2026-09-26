# RentOuts Escrow: architecture

ETHGlobal Tokyo 2026 · **Ethereum Sepolia testnet only** · Circle test USDC · MIT

Written for judges and code reviewers; about a 15-minute read. Companion docs: [DECISIONS.md](./docs/DECISIONS.md) (why), [PLAN.md](./docs/PLAN.md) (scope and timeline), [DEMO.md](./docs/DEMO.md) (the 3-minute demo).

---

## 1. Summary

RentOuts Escrow adds an on-chain rental layer to [RentOuts](https://rentouts.co), an existing rental marketplace. A landlord proposes a lease to a tenant by ENS name, and the tenant prepays the deposit and every period's rent in Circle test USDC into `RentEscrow`. That contract has no owner, admin or fee. It releases rent to the landlord one period at a time and returns the deposit at the end.

Five more pieces sit around that escrow:

- **Dispute judge.** The escrow's arbiter is the `AIArbiter` contract. It can do exactly one thing to the escrow: split a disputed lease's remaining escrow between that lease's tenant and landlord. An AI judge (an LLM, z.ai GLM 5.3) reads both parties' on-chain statements and answers a few typed questions. Code, not the model, turns those answers into a split. The judge only **proposes** that split. Either party can appeal inside a challenge window, and a human arbiter can rule or override at any time.
- **Human gate.** `fundLease` asks a `HumanGate` whether the tenant is a verified human. Its verifier is a World ID 4.0 gate (`WorldIdV4Gate`), plugged in on Sat 12:09 JST with one `setVerifier` call and no escrow redeploy (and switched at 12:42 JST to the gate the demo tenant alice is registered on), so only wallets registered after a World App Proof of Human can fund. The gate can only refuse to fund **new** leases; it never touches money.
- **Lease shares.** Each new lease mints 100 `LeaseShare1155` shares to the landlord. They are ERC-1155 real-world-asset tokens that only move between compliance-allowlisted wallets.
- **Identity.** The tenant's identity is a soulbound ENSv2 subname such as `alice.rentouts.eth`.
- **Credential.** A permissionless `CredentialSync.sync(tenant)` writes the tenant's track record into `rentouts.*` text records, reading it straight from the escrow. Any ENS-aware app can then read the credential through the ENS Universal Resolver, with no RentOuts API involved.

Everything runs on one chain, Ethereum Sepolia (11155111), because that is the only place the ENSv2 beta exists.

**Status (Sat 2026-09-26, 12:45 JST).** The whole system is live on Ethereum Sepolia. `AIArbiter`, the integrated `LeaseShare1155`, `HumanGate`, `RentEscrow` and `CredentialSync` were deployed between 03:05 and 03:09 JST. `AIArbiter` is bound to the escrow, and the issuer role cleanup is broadcast. All five contracts are source verified on Sourcify (`exact_match`) and Blockscout. Addresses and transactions are in [§10](#10-deployments). The ENS layer (`rentouts.eth`, `RentoutsSubnames`, `alice.rentouts.eth`) has been live since Friday. World ID has been wired in since Sat 12:09 JST ([`0x56b47b25…43e8ee`](https://sepolia.etherscan.io/tx/0x56b47b25c08ecec6022814b78273d2568bc7a8a4bea4eb6b4dda04180543e8ee)). Since 12:42 JST `HumanGate.verifier()` is the `WorldIdV4Gate` `0x5Cb8…aABa` that alice is registered on ([`0xcd93549e…b86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671)), see [§5(c)](#c-human-gate-plugging-world-id-in-without-a-redeploy).

---

## 2. Component map

```mermaid
flowchart TB
    W["Wallets on Sepolia<br/>tenant: alice.rentouts.eth<br/>landlord · anyone"]
    HUM["Human arbiter EOA<br/>0x798b…e486, a Safe in production"]
    I["Issuer EOA<br/>key-scoped ENS roles, CLI"]
    APP["Frontend app<br/>Vite + React + wagmi/viem"]
    J["AI judge service, judge/<br/>CLI, key: rentouts-judge keystore"]
    LLM["z.ai GLM 5.3<br/>OpenAI-compatible API"]

    subgraph R["RentOuts contracts"]
        RE["RentEscrow<br/>no owner, no admin, no fee"]
        AIA["AIArbiter<br/>RentEscrow's arbiter"]
        HG["HumanGate<br/>owner: deployer, verifier = WorldIdV4Gate"]
        LS["LeaseShare1155<br/>ERC-1155, allowlist in _update"]
        CS["CredentialSync<br/>permissionless sync(tenant)"]
        RS["RentoutsSubnames<br/>register, setCredential, revoke"]
    end

    WV["WorldIdV4Gate<br/>World ID 4.0, RP-attested register"]

    subgraph E["ENSv2 beta (ENS contracts plus our two proxies)"]
        UR["Universal Resolver"]
        ETHR["ETHRegistry<br/>rentouts.eth"]
        UREG["UserRegistry proxy<br/>*.rentouts.eth, soulbound"]
        PR["PermissionedResolver proxy<br/>records, key-scoped roles"]
    end

    USDC[("Circle test USDC<br/>6 decimals")]

    W -->|"sign transactions"| APP
    W -->|"submitEvidence, appeal, execute"| AIA
    APP -->|"resolve names, read records"| UR
    APP -->|"lease actions"| RE
    APP -->|"register"| RS
    APP -->|"sync"| CS
    APP -->|"approve"| USDC
    APP -->|"share transfers"| LS
    RE -->|"mintShare(leaseId, landlord, 100)"| LS
    RE <-->|"transferFrom in, transfer out"| USDC
    RE -->|"isVerified(tenant) in fundLease"| HG
    HG -->|"isVerified(tenant)"| WV
    AIA -->|"resolveDispute(id, tenantBps)"| RE
    J -->|"read lease, Evidence events"| AIA
    J -->|"typed questions"| LLM
    J -->|"tenant name, identity only"| UR
    J -->|"propose(id, tenantBps, rulingHash, ...)"| AIA
    HUM -->|"resolveByHuman, bindEscrow"| AIA
    CS -->|"tenantStats(tenant)"| RE
    CS -->|"setCredential(label, rentouts.*)"| RS
    RS -->|"register, unregister"| UREG
    RS -->|"setAddress, setText, linkToRecord"| PR
    I -->|"setText on rentouts.rating, onTimeRate, verified"| PR
    UR --> ETHR
    ETHR -->|"subregistry"| UREG
    ETHR -->|"resolver"| PR
    UREG -->|"resolver"| PR
```

| Component | Source | What it does |
|---|---|---|
| `RentEscrow` | [`src/RentEscrow.sol`](./src/RentEscrow.sol), interface [`src/interfaces/IRentEscrow.sol`](./src/interfaces/IRentEscrow.sol) | Holds each lease's USDC and runs the lease state machine ([§4](#4-lease-lifecycle)). Keeps per-tenant `tenantStats`. `token`, `arbiter`, `leaseShare` and `humanGate` are immutable constructor arguments. |
| `HumanGate` | [`src/HumanGate.sol`](./src/HumanGate.sol), interface [`src/interfaces/IHumanGate.sol`](./src/interfaces/IHumanGate.sol) | The World ID seam. `isVerified(account)` answers `true` while `verifier` is `address(0)` (open); otherwise it forwards the question to the verifier. The owner can `setVerifier` at any time, and the verifier must be a contract. See [§5(c)](#c-human-gate-plugging-world-id-in-without-a-redeploy). |
| `AIArbiter` | [`src/AIArbiter.sol`](./src/AIArbiter.sol) | The escrow's arbiter contract. Parties post evidence, the AI judge's key (`agent`) proposes a split, a challenge window runs, then anyone executes it. The `human` arbiter can rule or override at any time. Its only state-changing call is `escrow.resolveDispute` (invariant AI-1). See [§6](#6-ai-dispute-judge). |
| AI judge | [`judge/`](./judge/README.md) (TypeScript, Node ≥ 24) | `npm run judge -- --lease <id> [--propose]`. Reads the dispute from Sepolia, asks GLM 5.3 a fixed checklist, computes `tenantBps` with a fixed rubric (or abstains), and signs `AIArbiter.propose` with the `rentouts-judge` keystore. |
| `LeaseShare1155` | [`src/LeaseShare1155.sol`](./src/LeaseShare1155.sol) | ERC-1155 lease shares with `tokenId == leaseId`. The allowlist check sits in OpenZeppelin v5's `_update` hook, so it covers mints, single transfers and batch transfers ([§7](#7-lease-shares-leaseshare1155)). `RentEscrow` is its minter. |
| `RentoutsSubnames` | [`ens/src/RentoutsSubnames.sol`](./ens/src/RentoutsSubnames.sol) | Issues `<label>.rentouts.eth`. It holds root `REGISTRAR`, `UNREGISTER` and `RENEW` on our `UserRegistry`, and root `SET_ADDRESS`, `SET_TEXT` and `LINK` on our `PermissionedResolver`. It enforces who may write which record. |
| `CredentialSync` | [`ens/src/CredentialSync.sol`](./ens/src/CredentialSync.sol) | `sync(tenant)`: reads `RentEscrow.tenantStats(tenant)` and writes five `rentouts.*` records. It is an issuer on `RentoutsSubnames`. |
| ENSv2 (ENS's code) | `ensdomains/contracts-v2`, tag `sepolia-deployment-2026-09-15`; interfaces vendored in [`ens/src/interfaces/IENSv2.sol`](./ens/src/interfaces/IENSv2.sol) | `ETHRegistry` holds `rentouts.eth`. Its subregistry is our `UserRegistry` proxy and its resolver is our `PermissionedResolver` proxy, both deployed through ENS's `VerifiableFactory`. The Universal Resolver walks that tree. |
| App | [`app/`](./app/) | A 5-step wizard: claim a name, create a lease, fund it (with the human-gate notice), run it (claim / close / dispute / sync), lease shares. Every write is simulated first, so a revert shows as a readable error before MetaMask opens. The AI judge steps run from the CLI ([DEMO.md](./docs/DEMO.md)). |
| Deploy tooling | [`script/DeployAIArbiter.s.sol`](./script/DeployAIArbiter.s.sol), [`script/DeployEscrow.s.sol`](./script/DeployEscrow.s.sol), [`ens/script/DeployEns.s.sol`](./ens/script/DeployEns.s.sol), [`ens/scripts/ens.sh`](./ens/scripts/ens.sh) | Foundry scripts that sign with an encrypted keystore (`--account`), never a raw private key. The root scripts write `deployments.json` only in a real `--broadcast`. The ENS phases are re-runnable, and the wrapper dry-runs unless `BROADCAST=true`. |

**How a name resolves.** `getEnsAddress("alice.rentouts.eth")` in viem calls the Universal Resolver `0xeEeE…EeEe`. The Universal Resolver walks `RootRegistry → ETHRegistry ("rentouts") → our UserRegistry ("alice")` to find the resolver, then calls `PermissionedResolver.resolve(name, addr(node))`. The app reads ENS addresses from `ens/deployments/sepolia.json` and the parent name from `RentoutsSubnames.parentName()`, so no ENS address is hard-coded in the app's code.

---

## 3. Roles and trust model

| Role | Account | Can | Cannot |
|---|---|---|---|
| **Tenant** | e.g. alice `0x4848…e936` | Claim one name for itself (`register(label, self)`). Edit allowlisted profile keys (`avatar`, `description`, `url`, `com.twitter`, `com.github`) through `setProfileText`. `fundLease` on leases where it is the tenant, if the human gate says yes. `openDispute` on its `ACTIVE` leases. While disputed: `submitEvidence` (up to 5 statements of 1–1000 bytes) and `appeal` inside the challenge window. Call `claimRent`, `closeLease` (after the grace period), `execute` and `sync` like anyone. | Transfer, detach or burn its name (no token roles). Write any `rentouts.*` record (ENS reverts `EACUnauthorizedAccountRoles`). Withdraw prepaid rent or the deposit early; the only way out before the term ends is a dispute. |
| **Landlord** | e.g. the deployer `0xdD9c…CCCE` in the demo | `createLease` (must be on the `LeaseShare1155` allowlist and must not be the arbiter). `cancelLease` before funding. `claimRent`. `closeLease` from `endTime`. `openDispute`, `submitEvidence`, `appeal`. Transfer its lease shares to allowlisted wallets. | Take rent ahead of elapsed periods (INV-3). Keep the deposit without a dispute. Redirect rent by transferring shares: rent always goes to `lease.landlord`. Send shares to a wallet that is not allowlisted. |
| **Arbiter** (`RentEscrow.arbiter`) | the `AIArbiter` contract (immutable) | `resolveDispute(id, tenantBps)` on a `DISPUTED` lease: `⌊remaining × tenantBps / 10000⌋` goes to the tenant and the rest to the landlord. `AIArbiter` makes this call only from `execute` (an unappealed proposal after its window) or `resolveByHuman`. | Pay anyone other than that lease's two parties (INV-1). Pay out more or less than the remaining escrow (INV-4). Act on a lease that is not `DISPUTED`, or open a dispute. Be a landlord or tenant: `createLease` reverts `InvalidTerms`, and `DeployEscrow` refuses arbiter == deployer. Hold tokens: `AIArbiter` has no balance and no approvals. |
| **Human arbiter** (`AIArbiter.human`) | EOA `0x798b…e486` (a Safe in production) | `resolveByHuman(id, tenantBps)` at any time while the lease is `DISPUTED`: directly, after an appeal, or overriding a proposal that has not been executed. `bindEscrow` once (done live). `setAgent` (address 0 switches AI proposals off), `setChallengeWindow` (60 s to 30 days). Hand its own role over in two steps: `setHuman(new)` nominates, and the role moves only when `new` calls `acceptHuman()`. Until then the old human keeps it, a new `setHuman` replaces the nominee, and `setHuman(0)` cancels. A mistyped address therefore can't strand appealed leases, which only the human can close. | Rule from an address that is a party to the lease (`PartyCannotArbitrate`). The check binds addresses: the human is a trusted role and could hand the role to another key it controls, so the check only stops a ruling by accident. Keep the human's address out of every lease (the demo human is neither the landlord nor alice). Move funds anywhere but the lease's two parties. Change the escrow's arbiter. Trust assumption: it has the last word, and an appealed or abstained lease stays frozen until it rules (no deadline). |
| **AI judge** (`AIArbiter.agent`) | keystore `rentouts-judge`, used by [`judge/`](./judge/README.md) | `propose(id, tenantBps, rulingHash, confidenceBps, summary)` on a `DISPUTED` lease. Replace its own proposal while that proposal's window is still open; the window restarts. | Resolve or execute anything itself. Propose after an appeal (`ProposalLocked`) or once the window is over. Propose on a lease it is a party to. Move funds. Its proposal only takes effect if nobody appeals and the human doesn't overrule it. |
| **Deployer / admin** | `0xdD9c…CCCE` (keystore `rentouts-deployer`) | `RentoutsSubnames` admin: `setIssuer`, `setProfileKey` (never `rentouts.*`), `transferAdmin`. It is also an issuer. It owns `rentouts.eth` and holds all root roles (`ALL_ROLES`, including upgrade) on our `UserRegistry` and `PermissionedResolver` proxies, so it can rewrite any record, register or unregister any subname, and upgrade those proxies. It owns the integrated `LeaseShare1155` (`setAllowlist`, `setMinter`, direct mints) and the `HumanGate` (`setVerifier`). | Touch escrowed USDC, change the escrow's token, arbiter or gate, pause the escrow or take a fee: `RentEscrow` has no owner. Stop a funded lease through the gate. Move shares to a wallet that is not allowlisted. **This is the largest trust assumption on the identity side.** In production it would be a Safe that drops the roles it doesn't need. |
| **RP signer** (`WorldIdV4Gate.signer`, immutable) | `0xbb80…42CA`, held by the RentOuts World ID backend | Attest that a World ID 4.0 Proof of Human for the gate's action passed `POST /api/v4/verify` with a given wallet as the signal: one signature per nullifier, bound to chain, gate, action, wallet and deadline. Anyone may submit it with `register`. | Move or freeze funds, touch a lease, or register the same nullifier twice. It is trusted not to sign without a successful verify: the contract cannot check the zk proof. No rotation or revocation: a leaked key means a new gate plus `setVerifier`. |
| **HumanGate owner** | the deployer | `setVerifier(v)`: point the gate at a World ID verifier (must be a contract), swap it, or set `0` to reopen the gate. | Move, freeze or redirect funds. Affect a lease that is already funded: only `fundLease` asks the gate. A verifier that reverts makes `fundLease` revert (fail closed) until the owner fixes or clears it. |
| **Issuer EOA** | `0xF604…13C4` (keystore `rentouts-issuer`) | On `RentoutsSubnames`: `register` a name for any holder, `setCredential` on any `rentouts.*` key, `revoke`. Directly on the resolver, through key-scoped ENS roles: write `rentouts.onTimeRate`, `rentouts.rating` and `rentouts.verified`. | Write `avatar` or any key it wasn't granted directly on the resolver (ENS EAC reverts; checked live, see [DEMO.md](./docs/DEMO.md#optional-cli-proofs)). Write non-`rentouts.*` keys through the contract. Transfer names or touch the escrow. It *can* overwrite escrow-derived keys through `setCredential` until the admin removes it, and a later `sync` restores them. |
| **CredentialSync** | contract `0xd078…9c56` | For a tenant with an active name, write exactly five keys (`rentouts.leasesCompleted`, `disputes`, `rentPaid`, `depositReturnRate`, `escrow`), computed from `tenantStats`. | Choose the values: they are a pure function of public escrow state. Register or revoke names, or write any other key: its code has no other path. If the admin removes it as an issuer, `sync` reverts `NotIssuer`. |
| **Anyone** | any address | `claimRent(id)` (pays only the landlord). `closeLease(id)` from `endTime + periodSeconds`. `AIArbiter.execute(id)` once an unappealed proposal's window is over. `CredentialSync.sync(tenant)`. Read every record through the Universal Resolver and every lease through `getLease` / `tenantStats`. | Move any funds to itself. Register a name for someone else (only the holder or an issuer can). |

**Issuer role cleanup (done, Sat 03:09 JST).** The first ENS deploy had left the issuer EOA with key-scoped `SET_TEXT` on `rentouts.leasesCompleted`, `rentouts.disputes` and `rentouts.escrow`. Re-running the `subnames` phase revoked all three, in [`0x7e1373ad…47bf`](https://sepolia.etherscan.io/tx/0x7e1373adb27cfc551b9844d3122958b1e1fbbadedde07072cdb35c644d6247bf), [`0xa79c86c9…c06c`](https://sepolia.etherscan.io/tx/0xa79c86c93083d5d0d1550a4839241dd84b42a339bc3fdc6b7ad877caf46cc06c) and [`0x6f3603dc…b0bd`](https://sepolia.etherscan.io/tx/0x6f3603dc5544747bbcb4702af27a8c4bf336f978badacc4a05a773c2fd90b0bd). A read-only simulation afterwards showed that a direct resolver write from the issuer reverts `EACUnauthorizedAccountRoles` on all five escrow-derived keys (`leasesCompleted`, `disputes`, `escrow`, `rentPaid`, `depositReturnRate`). It still succeeds on `onTimeRate`, `rating` and `verified`.

**The trust model in four lines.**
- **Money:** trust the code (no admin path to funds). On a disputed lease only, trust the ruling: an AI proposal that nobody appealed, or the human arbiter's decision.
- **Access:** the human gate decides who may fund a new lease: only wallets registered in the `WorldIdV4Gate` (a World ID 4.0 human, attested by the RP signer). It can never touch a funded lease.
- **Credentials:** anyone can check the escrow-derived records against `RentEscrow.tenantStats` and restore them with `sync`. RentOuts (the issuers and the admin) can still overwrite or revoke. The judged keys (`rating`, `onTimeRate`, `verified`) are RentOuts' word.
- **Shares:** trust the `LeaseShare1155` owner's allowlist, which stands in for KYC/eligibility.

---

## 4. Lease lifecycle

```mermaid
stateDiagram-v2
    [*] --> NONE
    NONE --> CREATED : createLease (landlord)
    CREATED --> CANCELLED : cancelLease (landlord)
    CREATED --> ACTIVE : fundLease (tenant prepays all, human gate)
    ACTIVE --> DISPUTED : openDispute (either party)
    ACTIVE --> CLOSED : closeLease (after the term)
    DISPUTED --> CLOSED : resolveDispute (arbiter = AIArbiter)
    CANCELLED --> [*]
    CLOSED --> [*]
    note right of ACTIVE
        claimRent (anyone) pays
        elapsed periods to the landlord.
        The state stays ACTIVE.
    end note
```

`endTime = startTime + periods × periodSeconds`. `startTime` is set by `fundLease`.

| Transition | Call | Caller | Guards (revert) | Money and side effects |
|---|---|---|---|---|
| NONE → CREATED | `createLease(tenant, deposit, rentPerPeriod, periodSeconds, periods)` | landlord (`msg.sender`) | `tenant ≠ 0`, `tenant ≠ landlord`, neither party is the arbiter, `deposit + rentPerPeriod > 0`, `periods ≥ 1`, `periodSeconds ≥ MIN_PERIOD (60)`, total fits in `uint128`, else `InvalidTerms`. With shares enabled, the landlord must be allowlisted (`NotAllowlisted`). | No money moves. Mints 100 shares of `tokenId = leaseId` to the landlord. Ids start at 1. |
| CREATED → CANCELLED | `cancelLease(id)` | landlord | state `CREATED` (`InvalidState`), caller is the landlord (`NotLandlord`) | No money moves. The shares stay with the landlord (there is no burn). |
| CREATED → ACTIVE | `fundLease(id)` | tenant | `CREATED`, caller is the tenant (`NotTenant`). If `humanGate ≠ 0`: `humanGate.isVerified(tenant)`, else `NotVerifiedHuman(tenant)`. USDC allowance ≥ total. | Pulls `deposit + rentPerPeriod × periods` from the tenant. The clock starts. `leasesFunded += 1`. |
| ACTIVE → ACTIVE | `claimRent(id)` | anyone | `ACTIVE`, at least one elapsed, unclaimed period (`NothingToClaim`) | `k × rentPerPeriod` to the landlord. `periodsPaid` and `rentPaid` grow. |
| ACTIVE → DISPUTED | `openDispute(id)` | tenant or landlord | `ACTIVE`, caller is a party (`NotParty`). Allowed until someone closes the lease, also after the term and the grace window. | No money moves, so it works even if the token blocks one party. Rent is frozen: `claimRent` and `closeLease` revert. Records the periods earned so far. `leasesDisputed += 1`. |
| ACTIVE → CLOSED | `closeLease(id)` | landlord from `endTime`, anyone from `endTime + periodSeconds` | `ACTIVE`, `TermNotOver` | Unclaimed rent goes to the landlord and the deposit to the tenant. `leasesCompleted += 1`. The one-period grace window gives the landlord time to dispute the deposit. |
| DISPUTED → CLOSED | `resolveDispute(id, tenantBps)` | arbiter (`AIArbiter`, through `execute` or `resolveByHuman`) | caller is the arbiter (`NotArbiter`), `tenantBps ≤ 10000` (`InvalidBps`), `DISPUTED` | `⌊remaining × tenantBps / 10000⌋` goes to the tenant and the rest to the landlord. `depositsPosted += deposit`. `depositsReturned` counts only the deposit part of the tenant's payout (see [§9](#9-ens-record-schema)). The landlord's payout counts first as earned-but-unclaimed rent, and that part is added to `rentPaid` / `periodsPaid` as if it had been claimed. |

Every mutating function is `nonReentrant` and follows checks-effects-interactions. The human-gate check is a view call made before any state change. `claimable(id)` and `endTime(id)` are views that drive the UI's countdowns.

---

## 5. Flows

### (a) Claim an identity: `alice.rentouts.eth`

```mermaid
sequenceDiagram
    autonumber
    actor T as Tenant (alice)
    participant APP as App
    participant RS as RentoutsSubnames
    participant UREG as UserRegistry (our proxy)
    participant PR as PermissionedResolver (our proxy)
    participant UR as ENS Universal Resolver
    APP->>RS: labelOf(alice) returns "" (no name yet)
    APP->>RS: simulate register("alice", alice)
    Note over APP,RS: maps InvalidLabel, AlreadyHasName, LabelRetired, LabelTaken to readable errors
    alt self-serve
        T->>RS: register("alice", alice)
    else issuer mints for her (how the live alice was claimed)
        Note over RS: an issuer calls register("alice", alice)
    end
    RS->>RS: validate label, one name per address, label not retired, registry expiry == 0
    RS->>RS: store holderOf and labelOf first (the mint calls back into the holder)
    RS->>UREG: register("alice", alice, subregistry 0, resolver PR, roleBitmap 0, expiry max uint64)
    UREG-->>T: ERC-1155 name token, no roles, so it is soulbound
    RS->>PR: setAddress(dns, coinType 0x80000000 for an EOA or 60 for a contract, alice)
    RS->>PR: setText(dns, "rentouts.credential", "tenant/v1")
    RS->>PR: setText(dns, "rentouts.status", "active")
    RS-->>APP: event Claimed("alice", alice, tokenId)
    APP->>UR: getEnsAddress("alice.rentouts.eth")
    Note over UR: walks RootRegistry → ETHRegistry "rentouts" → UserRegistry "alice" → resolver
    UR->>PR: resolve(name, addr(node))
    PR-->>UR: 0x4848…e936
    UR-->>APP: 0x4848…e936
```

The live `alice.rentouts.eth` was claimed in tx [`0x882d63a5…7500`](https://sepolia.etherscan.io/tx/0x882d63a54d344760d5a10dd2455c25796ca3b930e7db50c96d9dea7b5f947500) and passed the ENS go/no-go gate at Fri 22:24 JST. The ENSIP-19 default address record means the same name also resolves on Base (coin type `0x80000000 | 84532`).

### (b) Landlord leases to an ENS name, tenant funds, rent flows, lease closes

```mermaid
sequenceDiagram
    autonumber
    actor L as Landlord (deployer)
    participant APP as App
    participant UR as ENS Universal Resolver
    participant RE as RentEscrow
    participant LS as LeaseShare1155
    participant HG as HumanGate
    participant USDC as Circle USDC
    actor T as Tenant (alice)
    actor K as Anyone (keeper)
    L->>APP: tenant = "alice.rentouts.eth"
    APP->>UR: getEnsAddress + getEnsText(rentouts.*)
    UR-->>APP: 0x4848…e936 and the credential card
    L->>RE: createLease(0x4848…e936, deposit, rentPerPeriod, periodSeconds, periods)
    RE->>RE: check terms, state CREATED, leaseId n
    RE->>LS: mintShare(n, landlord, 100)
    LS->>LS: _update checks allowlisted[landlord], else revert NotAllowlisted
    T->>USDC: approve(RentEscrow, deposit + rentPerPeriod × periods)
    T->>RE: fundLease(n)
    RE->>HG: isVerified(tenant)
    HG-->>RE: true (open gate, or a verified human)
    RE->>USDC: transferFrom(tenant, escrow, total)
    Note over RE: ACTIVE, startTime = now
    loop as periods elapse
        K->>RE: claimRent(n)
        RE->>USDC: transfer(landlord, k × rentPerPeriod)
    end
    L->>RE: closeLease(n) at endTime (anyone from endTime + periodSeconds)
    RE->>USDC: transfer(landlord, unclaimed rent)
    RE->>USDC: transfer(tenant, deposit)
    Note over RE: CLOSED, tenantStats.leasesCompleted += 1
```

The ENS name is resolved once, in the app. The lease stores the tenant's address, not the name.

### (c) Human gate: plugging World ID in without a redeploy

`RentEscrow.humanGate` is immutable, but `HumanGate.verifier` is not. The deploy script creates a `HumanGate` owned by the deployer with verifier `0`, so the gate starts open. On Saturday at 12:09 JST the World ID 4.0 gate `WorldIdV4Gate` (any contract that implements `isVerified(address) returns (bool)` would do) was plugged in with one `setVerifier` call ([`0x56b47b25…43e8ee`](https://sepolia.etherscan.io/tx/0x56b47b25c08ecec6022814b78273d2568bc7a8a4bea4eb6b4dda04180543e8ee), block 11783482). At 12:42 JST a second `setVerifier` ([`0xcd93549e…b86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671), block 11783640) switched it to the `fund-lease-wallet` gate alice is registered on; the first gate is superseded. Each switch was one transaction, with no escrow redeploy.

```mermaid
sequenceDiagram
    autonumber
    actor O as Gate owner (deployer)
    actor T as Tenant
    participant RE as RentEscrow
    participant HG as HumanGate
    participant V as WorldIdV4Gate
    T->>RE: fundLease(n)
    RE->>HG: isVerified(tenant)
    HG-->>RE: true, because verifier is 0 (open)
    Note over RE: lease n ACTIVE
    O->>HG: setVerifier(WorldIdV4Gate)
    Note over HG: VerifierUpdated. A non-contract reverts VerifierHasNoCode
    T->>RE: fundLease(m)
    RE->>HG: isVerified(tenant)
    HG->>V: isVerified(tenant)
    alt verified human
        V-->>HG: true
        HG-->>RE: true
        Note over RE: lease m ACTIVE
    else not verified, or the verifier reverts
        V-->>HG: false
        HG-->>RE: false
        RE-->>T: revert NotVerifiedHuman(tenant)
    end
    Note over RE,HG: claimRent, closeLease, openDispute and resolveDispute never ask the gate, so lease n runs to the end
```

The app reads `humanGate()`, `verifier()` and `isVerified(account)` and shows the gate's state on the fund step. A wallet the gate would refuse sees `NotVerifiedHuman` before MetaMask opens.

#### How World ID is used on RentOuts

World ID is the proof-of-personhood check at **one** moment: a tenant funding a new lease. It is not required to browse, list, claim rent, close a lease, open a dispute, or sync an ENS credential. The escrow never sees a World ID, a document, or a selfie. It only asks `isVerified(tenant)`.

**What is deployed today.** `RentEscrow` on Ethereum Sepolia (`0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18`) has an immutable `humanGate` of `HumanGate` `0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd`. That gate's `verifier` has been a `WorldIdV4Gate` since Sat 12:09 JST ([`0x56b47b25…43e8ee`](https://sepolia.etherscan.io/tx/0x56b47b25c08ecec6022814b78273d2568bc7a8a4bea4eb6b4dda04180543e8ee)). Since 12:42 JST it is `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`, where alice is registered ([`0xcd93549e…b86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671), block 11783640), so `fundLease` reverts `NotVerifiedHuman` for every wallet that is not registered there. Today alice is the only one that is. No escrow redeploy. Funded leases never consult the gate again. `setVerifier(address(0))` from the gate owner would reopen funding.

| `WorldIdV4Gate` | Action | Deploy tx | Registered |
|---|---|---|---|
| [`0x27052bD69b3d961940bCD093C21ba729b6c1B209`](https://eth-sepolia.blockscout.com/address/0x27052bD69b3d961940bCD093C21ba729b6c1B209) | `fund-lease` | [`0xf6009731…a199c`](https://sepolia.etherscan.io/tx/0xf6009731cf6bd6431914961d33746cc7bfc8cd626e730f31df0f333d0a6a199c) | none. **Superseded:** `HumanGate.verifier` from Sat 12:09 to 12:42 JST. The one phone proof for this action (signal `rentouts-fund-lease`) was used off-chain before wallet binding existed, so World now answers `nullifier_replayed` for that human. |
| [`0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`](https://eth-sepolia.blockscout.com/address/0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa) | `fund-lease-wallet` | [`0xde17d046…161dfe`](https://sepolia.etherscan.io/tx/0xde17d046d4e00c95ac09af3fa4e29d4245ca0008ed2a36cbfdf81e053c161dfe) | alice `0x4848…e936` ([`0xdbbfc6dd…148908`](https://sepolia.etherscan.io/tx/0xdbbfc6dd08fdaa4da200b51e6515a7b60423a7c3f94feb06f4a3b28f65148908), block 11783569). **The live verifier:** `HumanGate.verifier` since Sat 12:42 JST ([`0xcd93549e…b86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671), block 11783640). |

Both are Sourcify `exact_match`, have signer `0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA`, no owner and no tokens. `cast call 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd "verifier()(address)"` shows which one is live.

**What was proved with a real World App (2026-09-26).** A production World ID **4.0** Proof of Human was approved on an iPhone and accepted by World:

| | |
|---|---|
| Developer Portal app | RentOuts Escrow, team RentOuts |
| `app_id` | `app_2432bfa166623cfbbf813744d0b4b00c` |
| `rp_id` | `rp_9152be24431cdfcd` |
| First action (spent, not registered) | `fund-lease`, signal `rentouts-fund-lease` |
| Live action | `fund-lease-wallet`, signal Alice `0x484811c8c967809bE644A89d677933c29fb9e936` |
| Live gate | `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`, `register` tx `0xdbbfc6dd08fdaa4da200b51e6515a7b60423a7c3f94feb06f4a3b28f65148908` |
| `setVerifier` | `0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671`, block 11783640 |
| Credential | `proof_of_human` |
| Verify | `POST https://developer.world.org/api/v4/verify/rp_9152be24431cdfcd` → HTTP 200, `success: true`, `environment: production`, `protocol_version: 4.0` |
| Registration | production and staging RP status `registered` |

The phone does not talk to the escrow. The Mac page builds an RP-signed IDKit request (the signing key stays on the server, in `~/.rentouts-world.env`, never in the client or this repo). World App on the iPhone approves the proof. IDKit returns it. The server forwards that payload unchanged to World's verify API. Only a `success: true` result for action `fund-lease-wallet` is signed onto a wallet. The first `fund-lease` proof was spent on a text signal and was never registered.

```mermaid
sequenceDiagram
    autonumber
    actor Phone as iPhone World App
    participant Page as Local IDKit page
    participant Sign as Server (RP signing key)
    participant World as developer.world.org
    participant HG as HumanGate
    participant RE as RentEscrow
    participant V4 as WorldIdV4Gate
    actor T as Tenant wallet
    Sign->>Page: rp_context for action fund-lease-wallet, signal = tenant wallet
    Page->>Phone: QR / connector URI
    Phone-->>Page: Proof of Human (protocol 4.0)
    Page->>World: POST /api/v4/verify/rp_9152be24431cdfcd
    World-->>Page: success, nullifier
    Sign->>V4: register(wallet, nullifier, deadline, RP signature), anyone may send it
    Note over HG,V4: HumanGate.verifier = WorldIdV4Gate fund-lease-wallet (setVerifier, Sat 12:42 JST)
    T->>RE: fundLease
    RE->>HG: isVerified(tenant)
    HG->>V4: isVerified(tenant)
    V4-->>HG: true only for a registered wallet
    HG-->>RE: true or false (NotVerifiedHuman)
```

**Contract that matches the phone: `WorldIdV4Gate`.** `WorldHumanVerifier` checks World ID **3.0** `verifyProof` on the Sepolia router. The iPhone returned protocol **4.0**. World ID 4.0's zk verifier (`WorldIDVerifier`) is on World Chain, not Ethereum Sepolia, so the Sepolia escrow cannot call it. `WorldIdV4Gate` is the gate we use instead. After `/api/v4/verify` succeeds, the RP signer attests `(chainId, gate, actionHash, wallet, nullifier, deadline)`. `register` checks that signature, consumes the nullifier, and `isVerified(wallet)` becomes true. The gate owner then calls `HumanGate.setVerifier(WorldIdV4Gate)`. Setting the verifier back to `address(0)` reopens funding. The contract holds no tokens and cannot move escrow funds.

**What World is not allowed to do here.** It does not custody USDC, choose a dispute split, write ENS records, or allowlist a landlord. Landlord allowlisting stays on `LeaseShare1155`. ENS subnames stay the rental name and credential. World only answers "may this tenant fund a new lease?"

### (d) Dispute: evidence, AI proposal, challenge window, human override

```mermaid
sequenceDiagram
    autonumber
    actor T as Tenant
    actor L as Landlord
    participant RE as RentEscrow
    participant AIA as AIArbiter
    participant J as AI judge (judge/)
    participant M as GLM 5.3 (z.ai)
    actor H as Human arbiter 0x798b…e486
    actor K as Anyone
    T->>RE: openDispute(n) (the landlord can too)
    Note over RE: DISPUTED, rent frozen, periods earned so far recorded
    L->>AIA: submitEvidence(n, "kitchen window broken ...")
    T->>AIA: submitEvidence(n, "broke it by accident ...")
    Note over AIA: Evidence events only, 1 to 1000 bytes, at most 5 per party
    J->>RE: getLease, escrowBalance, DisputeOpened time
    J->>AIA: read Evidence events
    J->>M: lease facts and statements as quoted data, fixed checklist
    M-->>J: 3 yes/no answers with probabilities, severity 1-5, rationale
    J->>J: rubric in code gives tenantBps in 25 % steps, or ABSTAIN
    alt abstain: evidence insufficient, confidence below 0.7, one side silent, or a statement flagged
        Note over J,H: no proposal, the case goes to the human arbiter
    else propose
        J->>AIA: propose(n, tenantBps, rulingHash, confidenceBps, summary)
        Note over AIA: PROPOSED, deadline = now + challenge window (120 s in the demo)
        alt a party appeals inside the window
            T->>AIA: appeal(n)
            Note over AIA: APPEALED, only the human can rule now
        else nobody appeals
            K->>AIA: execute(n) after the deadline
            AIA->>RE: resolveDispute(n, tenantBps)
            RE-->>T: tenant share of the remaining escrow, in USDC
            RE-->>L: the rest
        end
    end
    opt any time while DISPUTED: direct, after an appeal, or overriding
        H->>AIA: resolveByHuman(n, tenantBps)
        AIA->>RE: resolveDispute(n, tenantBps)
    end
```

`AIArbiter.getRuling(n)` keeps the record: status (`NONE`, `PROPOSED`, `APPEALED`, `EXECUTED`, `HUMAN_RESOLVED`), the split, and the AI's `confidenceBps`, `deadline` and `rulingHash`. A human ruling keeps the AI's fields, so the record shows what the AI had said. How the judge reaches its answer is in [§6](#6-ai-dispute-judge).

### (e) Credential sync: escrow → ENS → any app

```mermaid
sequenceDiagram
    autonumber
    actor K as Anyone (tenant, landlord, keeper)
    participant CS as CredentialSync
    participant RS as RentoutsSubnames
    participant RE as RentEscrow
    participant PR as PermissionedResolver
    participant UR as ENS Universal Resolver
    participant X as Any ENS-aware app
    K->>CS: sync(tenant)
    CS->>RS: labelOf(tenant)
    RS-->>CS: "alice" (an empty label reverts NoName)
    CS->>RE: tenantStats(tenant)
    RE-->>CS: leasesCompleted, leasesDisputed, rentPaid, depositsPosted, depositsReturned
    loop five escrow-derived keys
        CS->>RS: setCredential("alice", key, value)
        RS->>RS: onlyIssuer, key starts with "rentouts."
        RS->>PR: setText(dns, key, value)
    end
    CS-->>K: event Synced(tenant, "alice", leasesCompleted, disputes)
    X->>UR: getEnsText("alice.rentouts.eth", "rentouts.leasesCompleted")
    UR->>PR: resolve(name, text(node, key))
    PR-->>UR: "1"
    UR-->>X: "1"
    opt trust check (the app does this)
        X->>RS: holderOf(labelhash) must equal addr, status must be active
        X->>RE: tenantStats(tenant) to spot stale records and offer a Sync button
    end
```

A sync writes 5 text records: about 350k gas for the first write and about 210k gas for a refresh (fork-test gas report). Records only change when someone calls `sync`. The app compares them with `tenantStats` and shows a Sync button when they are behind.

### (f) Revoke: wipe, burn, retire

```mermaid
sequenceDiagram
    autonumber
    actor I as Issuer EOA
    participant RS as RentoutsSubnames
    participant PR as PermissionedResolver
    participant UREG as UserRegistry
    participant APP as Any app
    participant UR as ENS Universal Resolver
    I->>RS: revoke("alice", reason)
    RS->>RS: retired[labelId] = true, delete holderOf and labelOf
    RS->>PR: linkToRecord(dns, 0)
    Note over PR: old record detached: addresses, credential, stats, profile
    RS->>PR: setText(dns, "rentouts.status", "revoked")
    Note over PR: a fresh record that holds only the status
    RS->>UREG: unregister(labelId)
    Note over UREG: name token burned
    RS-->>I: event Revoked("alice", holder, reason)
    APP->>UR: resolve alice.rentouts.eth
    Note over UR: the subname is gone, so the lookup falls back to the parent's resolver, which is the same PermissionedResolver
    UR-->>APP: addr 0x0, rentouts.status "revoked", everything else empty
    Note over RS: register("alice", anyone) now reverts LabelRetired, sync(holder) reverts NoName
```

The wipe matters because the subname shares its parent's resolver. Without `linkToRecord(name, 0)`, the Universal Resolver would still find the old records through `rentouts.eth` after `unregister`. Labels are single-use: even a redeployed `RentoutsSubnames` refuses them, because ENS never resets a used label's expiry to 0. The holder can claim a fresh label, such as `alice-2`.

### (g) Compliant share transfer

```mermaid
sequenceDiagram
    autonumber
    actor O as Share owner (deployer)
    actor L as Landlord (holds 100 shares of lease n)
    participant LS as LeaseShare1155
    actor V as Allowlisted investor
    actor S as Wallet not on the allowlist
    O->>LS: setAllowlist(investor, true)
    L->>LS: safeTransferFrom(landlord, investor, n, 40, "")
    LS->>LS: _update: allowlisted[investor] is true
    LS-->>V: 40 shares of lease n
    L->>LS: safeTransferFrom(landlord, stranger, n, 10, "")
    LS->>LS: _update: allowlisted[stranger] is false
    LS--xL: revert NotAllowlisted(stranger)
    O->>LS: setAllowlist(investor, false)
    Note over LS: transfers to the investor now revert too. Batch transfers go through the same hook.
```

The app simulates the transfer first, so a transfer to a wallet that isn't allowlisted shows `NotAllowlisted` before MetaMask opens. A share records a position in a lease; it is not a claim on cash flows. Rent goes to `lease.landlord`, not pro rata to share holders. The same flow is live on Base Sepolia as a standalone proof ([§10](#10-deployments)).

---

## 6. AI dispute judge

A dispute needs a ruling, and a single human arbiter is slow and a bottleneck. The AI judge gives a first ruling within seconds. It is built so that a wrong or manipulated AI answer can be caught before it pays out, and so that the worst it can do is bounded by the contracts.

**Who does what.**

| Piece | Does | Never does |
|---|---|---|
| **LLM** (z.ai GLM 5.3, OpenAI-compatible API, JSON mode) | Answers a fixed checklist of narrow, typed questions. | Choose the split, sign anything, or see the tenant's track record. |
| **Judge code** ([`judge/`](./judge/README.md)) | Reads the dispute from Sepolia, validates the model's reply (zod, one retry), turns the answers into `tenantBps` with a fixed rubric or abstains, hashes the ruling, and signs `propose` with the `rentouts-judge` keystore. | Resolve or execute. It only proposes. |
| **`AIArbiter`** | Stores evidence as events, holds the proposal through the challenge window, executes it, and lets the human rule or override at any time. | Call anything on the escrow except `resolveDispute`, or hold tokens (AI-1). |
| **Parties** | Post statements, and appeal inside the window. | Rule on their own lease. |
| **Human arbiter** | Rules on abstained or appealed leases, overrides when needed, and sets the agent and the window. | Pay anyone but the lease's two parties. |

**Evidence on-chain.** `submitEvidence(leaseId, statement)` is open to the lease's tenant and landlord while it is `DISPUTED`: 1 to 1000 bytes per statement and at most 5 statements per party. Statements live only in `Evidence` events. They are public, and the judge reads them from the log.

**The typed questions.** Every provider answers the same schema:

| Field | Type | Used for |
|---|---|---|
| `damageBeyondNormalWear` | yes/no + probability | Deposit: if yes, the landlord keeps severity/5 of it. |
| `rentClaimValid` | yes/no + probability | Rent for periods that had not elapsed when the dispute was opened: to the landlord only if yes (for example, the tenant left early without notice). |
| `evidenceSufficient` | yes/no + probability | If no, the judge abstains. |
| `severity` | 1–5 | How much of the deposit the landlord keeps (20 % to 100 %). |
| `rationale` | at most 3 sentences citing evidence ids | Shown as the proposal's summary. It explains the answers but never sets the split. |

**The rubric (code, not the model).** The remaining escrow of a disputed lease splits into three pots, computed the same way `RentEscrow` does: the deposit, rent for periods that had elapsed but was not yet released, and rent for periods that had not elapsed.
1. Elapsed, unreleased rent goes to the landlord. The model is not asked about it.
2. The deposit goes back to the tenant, minus severity/5 of it if there is damage beyond normal wear.
3. Unearned rent goes back to the tenant unless `rentClaimValid` is yes.
4. `tenantBps` is the tenant's amount divided by the remaining escrow, rounded to the nearest 25 % (0 / 2500 / 5000 / 7500 / 10000). An exact half step rounds toward the tenant.

**The abstain band.** The judge makes no proposal, and says the case is escalated to the human arbiter, in any of these cases:
- the model answers `evidenceSufficient: no`;
- an answer the payout rests on has a probability below `JUDGE_MIN_CONFIDENCE` (0.7);
- only one party has posted a statement (silence is not an admission);
- the code screen flags a statement (see below).

With no statements at all it abstains without calling the model. Otherwise it proposes, and `confidenceBps` is the weakest of the answers that count. `evidenceSufficient` and `damageBeyondNormalWear` always count. `rentClaimValid` counts only when it is yes and there is unearned rent in escrow, because only then does it move money. A "no" leaves that rent with the tenant, where it goes anyway. The judge cannot withdraw a proposal. If a rerun abstains while its earlier proposal is still open, the CLI prints a warning with the open split and deadline and `--propose` exits 3. Only an appeal or `resolveByHuman` stops that proposal.

**Commitment.** The ruling is canonical JSON with sorted keys, no whitespace and no timestamps. It holds the chain, escrow, arbiter and lease, an `inputHash` over every fact and statement read, the provider and model, the answers, the rubric arithmetic, the confidence and threshold, and the decision. `rulingHash = keccak256(canonical JSON)` goes on-chain with the proposal. Every run saves the ruling and its input to `judge/out/ruling-<chainId>-<arbiter>-<lease>-<rulingHash>.json` before anything is sent. The hash in the name means a rerun never overwrites the preimage of a hash that is already on-chain. After a confirmed `--propose`, the same record is also written to `ruling-<chainId>-<arbiter>-<lease>.json`, with the arbiter address in lowercase. `--verify <file>` recomputes both hashes, so an edited statement or amount is caught. `--onchain` also compares the file with `AIArbiter.getRuling(lease)`.

**Challenge window and human override.** A proposal is appealable until `deadline = proposedAt + challengeWindow`. The window is 120 s on the live deploy; the contract accepts 60 s to 30 days, and production would use days. While the window is open, the agent may replace its own proposal, which restarts the window, so the parties always get a full window on what would be executed. An appeal by either party locks the proposal: only `resolveByHuman` can close that lease. After the deadline, anyone can `execute`. The human arbiter can `resolveByHuman` at any point while the lease is `DISPUTED`, before or after a proposal, inside or after the window.

**Evidence is attacker-controlled.** Both parties write the evidence, and both want the money. The main risk is a plausible false statement ("the tenant already agreed in writing to forfeit the deposit"), not a blunt "ignore previous instructions". So:
- Statements reach the model as JSON data inside an `<evidence>` block, each labelled with its author and an id, with `<` and `>` escaped so no statement can close the block.
- The system prompt says statements may be false or manipulative, that they are claims and never instructions, and that "already decided / approved" text is only a claim. A claim counts only if the other side admits it or it carries checkable detail. An attempt to instruct the judge or impersonate RentOuts must be reported and answered `evidenceSufficient: no`, which sends the case to the human.
- The system prompt adds that silence is not an admission. A claim against a party who has posted nothing is not established, and the code abstains in that case whatever the model says.
- **Code backs the prompt up, for every provider.** A screen in code ([`judge/src/screen.ts`](./judge/src/screen.ts)) checks every statement for:
  - instructions to the judge;
  - role labels such as `SYSTEM:`, tags, and the checklist's field names;
  - impersonation of RentOuts or an arbiter;
  - "already decided / confirmed" claims.

  A flagged statement makes the judge abstain whatever the model answered, so a model that obeys an injected "answer yes with confidence 1.0" still does not get a proposal out. The screen uses keyword patterns, so a reworded injection can get past it. The prompt, the appeal window and the human remain the other layers.
- The model sees only the tenant's identity (ENS name, credential status, whether the name resolves to the tenant). It does not see the track record (`rentouts.disputes`, `depositReturnRate`, `rating`): a past record is not evidence about this dispute, and rulings feed back into that record through `CredentialSync`.

**Honest limits.**
- **An LLM can be confidently wrong.** Its probabilities are not calibrated on rental disputes (no labelled data exists), so the 0.7 threshold is a placeholder, not a measured error rate. Its rationale may not be the real reason for its answers.
- **It can be swayed by false evidence.** The judge reads short text statements only: no photos, documents or invoices, and it can't check a claim against the world. A careful liar can write a plausible one-sided story. If the other party contests it, the case should come out "insufficient"; if not, the appeal is the safeguard.
- That is why the AI only **proposes**. Nothing it says moves money until a window with an appeal right has passed, and a human can overrule it at any time.
- **Coarse splits.** 25 % steps keep rulings easy to check but can land up to 12.5 % of the remaining escrow away from the rubric's exact figure. A party who cares appeals, and the human can rule any bps.
- **The human route has no deadline.** An appeal costs only gas, and an appealed or abstained lease stays frozen until the human rules. A production version would add an appeal bond and a service-level deadline.
- **Privacy.** Statements are public on-chain, and the model provider receives them.
- **The mock provider** (`--provider mock`) is keyword matching, for tests and offline demos. It is not a judge. `--provider mock --propose` is allowed as the demo fallback when the model API is down. The ruling then records `provider: "mock"`, and the on-chain summary starts with `[mock judge, keyword matching]`.

**What the contracts guarantee whatever the model says** ([`test/AIArbiter.invariant.t.sol`](./test/AIArbiter.invariant.t.sol)):
- **AI-1:** the only state-changing call `AIArbiter` makes is `escrow.resolveDispute(leaseId, tenantBps)` on the bound escrow; its other calls are views on that escrow. It holds no tokens and has no approvals. So even with the agent key, the human key or both compromised, the worst outcome is a wrong split of one disputed lease's own escrow between its tenant and landlord (RentEscrow INV-1 / INV-4). It is never theft and never a payout to anyone else.
- **AI-2:** no token ever reaches the arbiter contract, the agent, the human or a stranger.
- **AI-3:** every closed disputed lease was either executed after an unappealed window or ruled by the human, and paid exactly that split.

`bindEscrow` accepts only an escrow whose immutable `arbiter` is this `AIArbiter`, and only once.

---

## 7. Lease shares: LeaseShare1155

RentOuts turns a **rental lease/deposit into a real-world asset (RWA)**: an ERC-1155 token where `tokenId == leaseId`. The defining feature is **compliance-aware transfers**: shares can only be held by allowlisted (KYC / eligibility-approved) wallets, enforced at the token level. It's a minimal, demoable cut of RentOuts' Stage-3 investor surface (permissioned lease shares, Reg D 506(c) / Reg S). It was built for the **Curvegrid: Best RWA Tokenization** track and first deployed standalone on Base Sepolia at [`0x5490e5dFcDcA741aC99127f66B4abf6204cd64C5`](https://sepolia.basescan.org/address/0x5490e5dFcDcA741aC99127f66B4abf6204cd64C5) (Sourcify-verified). The integrated copy, with `RentEscrow` as minter, is live on Ethereum Sepolia at [`0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09`](https://eth-sepolia.blockscout.com/address/0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09). It was deployed by `DeployEscrow` and is Sourcify-verified.

```mermaid
flowchart TB
  classDef contract fill:#0f2e27,stroke:#1fa882,stroke-width:2px,color:#e8fff7;
  classDef actor fill:#12233f,stroke:#5b8def,stroke-width:1.5px,color:#e6efff;
  classDef good fill:#0f2e27,stroke:#1fa882,stroke-width:1.5px,color:#b8ffe9;
  classDef bad fill:#3a1620,stroke:#e5484d,stroke-width:1.5px,color:#ffd7db;

  Owner["Issuer / Owner (RentOuts)"]:::actor
  Escrow["RentEscrow (minter on the Ethereum Sepolia deploy)"]:::actor

  subgraph Chain["LeaseShare1155 - Base Sepolia standalone, Sourcify verified - integrated on Ethereum Sepolia"]
    LS["LeaseShare1155 (ERC-1155)<br/>tokenId equals leaseId<br/>allowlisted mapping<br/>_update compliance gate<br/>mintShare: minter or owner only"]:::contract
  end

  Owner -->|"setAllowlist / setMinter"| LS
  Escrow -->|"mintShare(leaseId, to, amount)"| LS
  LS -->|"mint and transfer allowed"| Allow["Allowlisted holders<br/>tenant, investor"]:::good
  LS -.->|"transfer blocked"| Deny["Non-allowlisted wallet<br/>revert NotAllowlisted(to)"]:::bad
```

- **Issuer / Owner** (RentOuts) manages the compliance allowlist (`setAllowlist`) and designates the minter (`setMinter`).
- **RentEscrow** calls `mintShare(leaseId, landlord, 100)` in `createLease`. `DeployEscrow` makes the escrow the minter and allowlists the deployer as the demo landlord.
- **LeaseShare1155** mints and moves shares, but **every recipient is checked against the allowlist** in the ERC-1155 `_update` hook.
- **Allowlisted holders** (tenant, investor) can receive; **non-allowlisted** wallets are rejected with `NotAllowlisted`.

### The compliance gate

OpenZeppelin v5 routes mint, single transfer, and batch transfer through one hook, `_update`. We override it so the allowlist covers **every** path:

```mermaid
flowchart LR
  classDef step fill:#12233f,stroke:#5b8def,stroke-width:1.5px,color:#e6efff;
  classDef gate fill:#0f2e27,stroke:#1fa882,stroke-width:2px,color:#e8fff7;
  classDef good fill:#0f2e27,stroke:#1fa882,stroke-width:1.5px,color:#b8ffe9;
  classDef bad fill:#3a1620,stroke:#e5484d,stroke-width:1.5px,color:#ffd7db;

  A["mint / transfer / batch transfer<br/>recipient = to"]:::step --> G{"_update()<br/>allowlisted[to] ?"}:::gate
  G -->|yes| C["balances updated<br/>(single and batch)"]:::good
  G -->|no| D["revert NotAllowlisted(to)"]:::bad
```

```solidity
function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
    internal
    override
{
    if (to != address(0) && !allowlisted[to]) revert NotAllowlisted(to);
    super._update(from, to, ids, values);
}
```

Because mint, `safeTransferFrom`, and `safeBatchTransferFrom` all funnel through `_update`, there is no path to move a share to a non-approved wallet. Burns (`to == address(0)`) are exempt so a burn entrypoint can be added later.

### Contract surface

| Element | Purpose |
| --- | --- |
| `mapping(uint256 => uint256) totalSupply` | shares minted per lease |
| `mapping(address => bool) allowlisted` | compliance allowlist (who may hold shares) |
| `address minter` | escrow / issuer allowed to mint (owner can always mint) |
| `setAllowlist(account, allowed)` | **owner-only**: add/remove a compliant wallet |
| `setMinter(minter_)` | **owner-only**: designate the escrow as minter |
| `mintShare(leaseId, to, amount)` | **minter/owner**: mint a lease share to an allowlisted holder |
| `_update(...)` | enforces the allowlist on every balance change |

**Roles:** the **owner** (RentOuts) controls the allowlist + minter; the **minter** (the escrow) mints shares; holders can transfer only to other allowlisted holders.

### How it fits RentOuts

- **Non-custodial:** the token encodes ownership + transfer rules; RentOuts never holds user funds (ADR-0013 posture).
- **Integration:** `RentEscrow` is the `minter` and calls `mintShare(leaseId, …)` when a lease is created. Because the landlord must be allowlisted to receive the shares, listing a lease is itself compliance-gated. One `LeaseShare1155` per `RentEscrow`, because lease ids restart at 1 in every escrow.
- **Roadmap:** this is the demoable core of the Stage-3 investor surface (`InvestorPool` ERC-1155 + `TransferAgent` permissioned transfers).

---

## 8. Invariants and how they are tested

`RentEscrow`'s invariants are declared in `IRentEscrow` and checked by the handler-based suite [`test/RentEscrow.invariant.t.sol`](./test/RentEscrow.invariant.t.sol). The handler runs random create / cancel / fund / warp / claim / close / dispute / resolve sequences across four actors (funding through a `HumanGate` whose verifier approves them), a keeper and the arbiter. It books every token transfer out of the escrow from the token's own `Transfer` logs, not from the escrow's bookkeeping. Settings: 64 runs × 256 calls, `fail_on_revert = true` (the handler only makes valid calls, so any revert is a bug). At a depth of 64, up to half the runs never reached `closeLease`. At 256, every measured run reached close, resolve and claim, and an `afterInvariant` guard fails any run that settles no lease.

| ID | Invariant | How the suite checks it |
|---|---|---|
| **INV-1** | Funds only ever move to the lease's tenant or landlord (no owner, no fee, no admin). | No escrow transfer goes to a non-party, and claim/close pay each party exactly what it is owed. Each actor's balance equals minted − escrowed + received. The arbiter, the keeper and the share issuer never hold a token. |
| **INV-2** | `Σ escrowBalance(leaseId) == usdc.balanceOf(escrow)` | Sums every lease. `ACTIVE` and `DISPUTED` leases hold exactly `deposit + rentPerPeriod × unclaimed periods`; every other state holds 0. |
| **INV-3** | Rent released for a lease never exceeds `rentPerPeriod × elapsed periods` (capped at the term). | A ghost ledger of rent actually transferred per lease, checked against the elapsed periods since `startTime`. `periodsClaimed ≤ elapsed`. |
| **INV-4** | A dispute resolution pays out exactly the lease's remaining escrow, split tenant/landlord. | The payout equals the escrow at resolve time, the balance is 0 afterwards and the state is `CLOSED`. |
| **AI-1** | `AIArbiter`'s only state-changing call is `escrow.resolveDispute` on the bound escrow. | [`test/AIArbiter.invariant.t.sol`](./test/AIArbiter.invariant.t.sol) records every call the arbiter makes (state diff) while a handler drives evidence, proposals, appeals, executions, human rulings and window changes against the real `RentEscrow`. |
| **AI-2** | No token ever reaches the arbiter contract, the agent, the human or a stranger. | Those accounts' token balances stay 0, and every token minted is in the escrow or with a lease's own tenant or landlord. |
| **AI-3** | A disputed lease closes only through an executed (unappealed, window over) proposal or a human ruling, and pays exactly that split. | Ghost counters for early executions, executed or replaced appeals, refused executions and calls by the wrong role all stay 0. Each closed lease's status is `EXECUTED` or `HUMAN_RESOLVED` (always the human after an appeal), and its payouts equal the ruling's split of the escrow left at the dispute. |

Mutation check (from the core README): each of these injected bugs makes the escrow suite fail: dropping the term cap, paying the arbiter, leaving a closed lease's balance, and rounding the split up.

Other suites:

- **`RentEscrow` unit and fuzz** ([`test/RentEscrow.t.sol`](./test/RentEscrow.t.sol)): every function and exact custom-error revert, partial and complete claims with `vm.warp`, the close grace rule, 0 / 5000 / 10000 bps splits plus a fuzzed split, share minting and the non-allowlisted-landlord revert, re-entry through the ERC-1155 receive hook, the arbiter never being a party, tenant-stats accounting (how a dispute payout splits into refunded rent, returned deposit and rent paid), and disputes opened after the grace window. [`test/RentEscrow.blacklist.t.sol`](./test/RentEscrow.blacklist.t.sol) covers the way out when a USDC-style token blacklists the landlord or the tenant ([§11](#11-security-notes-and-known-limitations)).
- **`HumanGate`** ([`test/HumanGate.t.sol`](./test/HumanGate.t.sol)): no gate, open gate, forwarding to the verifier, an unverified tenant refused, a verifier swapped later on the same escrow, fail-closed while the verifier is down, owner-only `setVerifier`, a renounced owner freezing the verifier, and a funded lease never touched by the gate.
- **`AIArbiter`** ([`test/AIArbiter.t.sol`](./test/AIArbiter.t.sol)): every flow against the real `RentEscrow`: evidence rules and caps, propose / replace / appeal / execute, windows, the human's direct ruling and overrides inside and after the window, party checks, `bindEscrow` checks, setters, the two-step human handover, and a fuzzed exact split.
- **Deploy scripts** ([`test/DeployEscrow.t.sol`](./test/DeployEscrow.t.sol), [`test/DeployAIArbiter.t.sol`](./test/DeployAIArbiter.t.sol)): config checks (arbiter ≠ deployer, agent ≠ human, window bounds, one `LeaseShare1155` per escrow), wiring, and nothing recorded outside a real broadcast.
- **`LeaseShare1155`** ([`test/LeaseShare1155.t.sol`](./test/LeaseShare1155.t.sol)): 12 tests including a 256-run fuzz that proves non-allowlisted recipients are always rejected, allowlist enforcement on single **and** batch transfers, revoke-mid-life, and access control.
- **AI judge** (`judge/test/`, vitest) covers:
  - the rubric and its rounding, the abstain rules, and which answers count toward the confidence;
  - a replay of real GLM 5.3 answers on the three demo fixtures;
  - zod validation, the single retry, and the JSON-mode fallback against a mocked HTTP endpoint;
  - canonical JSON and a pinned `rulingHash`;
  - prompt construction, the injection fixtures and the code screen;
  - saved rulings, `--verify` catching edited input, and `--onchain` against a stubbed client;
  - `--propose` over an open proposal, and the mock label on-chain;
  - keystore decryption, including a `cast`-written keystore;
  - the CLI end to end.

  No test calls a real API.
- **ENS fork tests against live ENSv2 on Sepolia** ([`ens/test/`](./ens/test/)). They deploy fresh proxies and register a random parent inside the fork. Coverage: soulbound (`unsafeTransfer` → `TransferDisallowed`, plus a positive control that proves the gate), the holder can't detach or burn, issuer key-scoped roles enforced by ENS (the issuer writes `rentouts.onTimeRate` and reverts on `avatar`; the holder can't forge), revoke wipes, burns and retires, labels stay blocked across a redeploy, `sync` is permissionless, restores overwritten values and reverts after revoke or when not an issuer, and the deploy script grants judged keys only. The deploy phases also run end to end: `credentialSync` fresh, reused, replaced, interrupted or never landed; a `removeIssuer` that sticks; the `subnames` re-run that revokes derived-key roles; and the state-file checks.
- **App** (`app/src/lib/*.test.ts`, vitest): the credential trust check, error mapping, the human-gate notice, address input, formatting and label validation.

Counts (Sat 03:15 JST, all green):
- **Root package: 163** (Sat 12:53 JST, 12 suites). `RentEscrow` 49, `RentEscrowBlacklist` 4, `HumanGate` 16, `WorldIdV4Gate` 6, `WorldIdV4GateSecurity` 12, `WorldHumanVerifier` 8 (deprecated 3.0 path), `DeployEscrow` 15, `LeaseShare1155` 12, `AIArbiter` 34 and `DeployAIArbiter` 5, plus the two invariant campaigns, which forge counts as one test each.
- **`judge/`: 92 vitest tests.** The `cast` keystore cross-check is skipped when `cast` is not on `PATH`.
- **`ens/`: 42 fork tests.** `RentoutsSubnames` 18, `CredentialSync` 10, `DeployEnsPhases` 11 and `DeployEnsRoles` 3. All 42 passed against live Sepolia right after the deploy ([`docs/ens/LOG.md`](./docs/ens/LOG.md)).

---

## 9. ENS record schema

Records for `<label>.rentouts.eth`. They all live in one shared `PermissionedResolver`.

| Key | Written by | Value | Example |
|---|---|---|---|
| `addr` | `RentoutsSubnames.register` | the holder. EOAs get the ENSIP-19 default EVM record (`0x80000000`), which resolves on every EVM chain; contract wallets get coin 60 only. | `0x4848…e936` |
| `rentouts.credential` | `RentoutsSubnames.register` | credential schema version | `tenant/v1` |
| `rentouts.status` | `RentoutsSubnames` (register / revoke) | lifecycle | `active` / `revoked` |
| `rentouts.leasesCompleted` | `CredentialSync.sync` | `tenantStats.leasesCompleted` (closed without a dispute) | `3` |
| `rentouts.disputes` | `CredentialSync.sync` | `tenantStats.leasesDisputed` (opened by either party) | `0` |
| `rentouts.rentPaid` | `CredentialSync.sync` | `tenantStats.rentPaid`, USDC with 2 decimals, rounded down | `1250.00` |
| `rentouts.depositReturnRate` | `CredentialSync.sync` | `depositsReturned × 100 / depositsPosted`, whole percent, rounded down, capped at 100. `n/a` until a lease with a deposit has ended. In a dispute, the tenant's payout counts first as a refund of rent not yet earned when the dispute was opened, then as deposit, then as earned rent; only the deposit part counts as returned. | `100`, `50`, `n/a` |
| `rentouts.escrow` | `CredentialSync.sync` | CAIP-10 id of the escrow the stats come from | `eip155:11155111:0x…` (lowercase) |
| `rentouts.onTimeRate`, `rentouts.rating`, `rentouts.verified` | issuer EOA (key-scoped ENS role, or `setCredential`) | judgments the escrow can't derive | `100`, `5`, `true` |
| `avatar`, `description`, `url`, `com.twitter`, `com.github` | holder, via `setProfileText` | profile (admin-editable allowlist, never `rentouts.*`) | … |

Parent `rentouts.eth` records: `addr` = `0x7ed696c879a1a7FD2eD3b49d9982E634a8647eb1` (RentOuts' published address), `url` = `https://rentouts.co`, `email` = `partners@rentouts.co`, `com.twitter` = `RentOuts`, and `description`.

**Reader rule.** Show `rentouts.*` values only when `rentouts.status == "active"` and `addr(name)` equals `RentoutsSubnames.holderOf(labelhash)`. The app's credential card enforces this in `app/src/lib/credential.ts`.

---

## 10. Deployments

**Ethereum Sepolia (11155111).** Machine-readable copies: [`ens/deployments/sepolia.json`](./ens/deployments/sepolia.json) (ENS, `CredentialSync` and the escrow it reads), and the root [`deployments.json`](./deployments.json), where `DeployEscrow` wrote the `"sepolia"` entry and `DeployAIArbiter` the `"sepoliaAIArbiter"` entry (with `fromBlock` 11780900 for log scans).

**Our contracts.** They were deployed Sat 2026-09-26 between 03:05 and 03:09 JST, in blocks 11780903 to 11780920, from the deployer `0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE`. All 11 transactions succeeded, for about 0.0062 ETH in total. Each contract is source verified on Sourcify (`exact_match` for both creation and runtime code) and on Blockscout (fully verified, imported from Sourcify). Etherscan does not show them as verified yet, because that needs an Etherscan API key. Before submission, each contract's creation bytecode was rebuilt and compared byte for byte with its deploy transaction. The four root contracts use solc 0.8.24 and `CredentialSync` uses 0.8.28, all with the cancun EVM and 200 optimizer runs.

| Contract | Address (Blockscout, verified source) | Deploy tx | Wiring, read live |
|---|---|---|---|
| `AIArbiter` (arbiter of `RentEscrow`) | [`0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5`](https://eth-sepolia.blockscout.com/address/0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5) | [`0xc82a9176…977a`](https://sepolia.etherscan.io/tx/0xc82a9176171588129ef6244ab9f655b39319a661456d0daedbf7d7673b47977a) | `agent` = judge key `0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA`, `human` = `0x798b…e486`, `challengeWindow` = 120 s, `escrow` = `RentEscrow` (bound in [`0xe4771261…b875`](https://sepolia.etherscan.io/tx/0xe47712614a63eec77c960c9f27cd31ed34de7d2e7bc3a4b0098172195088b875)) |
| `LeaseShare1155` (integrated) | [`0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09`](https://eth-sepolia.blockscout.com/address/0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09) | [`0x05ce482f…f64b`](https://sepolia.etherscan.io/tx/0x05ce482f57de77b09f73efed346c889b0f6012c3a0b426f8bc76abf7e124f64b) | owner = deployer, allowlisted = deployer, `minter` = `RentEscrow` (set in [`0xc0d8b854…9f84`](https://sepolia.etherscan.io/tx/0xc0d8b854aad94e8fd1cab7488c2e3f29390aa5af2d5127dd2236298534149f84)) |
| `HumanGate` | [`0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd`](https://eth-sepolia.blockscout.com/address/0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd) | [`0x2351a01f…c232`](https://sepolia.etherscan.io/tx/0x2351a01fdc504feeb7bd8026029c287765e16568aa8370431a498e089e89c232) | owner = deployer, `verifier` = `WorldIdV4Gate` `fund-lease-wallet` since Sat 12:42 JST ([`0xcd93549e…b86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671)); the `fund-lease` gate from Sat 12:09 JST ([`0x56b47b25…43e8ee`](https://sepolia.etherscan.io/tx/0x56b47b25c08ecec6022814b78273d2568bc7a8a4bea4eb6b4dda04180543e8ee)) until then |
| `WorldIdV4Gate` (`fund-lease`) | [`0x27052bD69b3d961940bCD093C21ba729b6c1B209`](https://eth-sepolia.blockscout.com/address/0x27052bD69b3d961940bCD093C21ba729b6c1B209) | [`0xf6009731…a199c`](https://sepolia.etherscan.io/tx/0xf6009731cf6bd6431914961d33746cc7bfc8cd626e730f31df0f333d0a6a199c) | `signer` = RP signer `0xbb80…42CA`, deployed by `0x5129…2c28`; `HumanGate.verifier` Sat 12:09–12:42 JST, superseded; nobody registered |
| `WorldIdV4Gate` (`fund-lease-wallet`) | [`0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`](https://eth-sepolia.blockscout.com/address/0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa) | [`0xde17d046…161dfe`](https://sepolia.etherscan.io/tx/0xde17d046d4e00c95ac09af3fa4e29d4245ca0008ed2a36cbfdf81e053c161dfe) | same signer and deployer; alice registered (block 11783569); `HumanGate.verifier` since Sat 12:42 JST ([`0xcd93549e…b86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671)) |
| `RentEscrow` | [`0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18`](https://eth-sepolia.blockscout.com/address/0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18) | [`0xf8b1d3c0…8f00`](https://sepolia.etherscan.io/tx/0xf8b1d3c05a146a85205a215e96e3c3c1eb20015db12323cdc7013eae795c8f00) | `token` = Circle USDC, `arbiter` = `AIArbiter`, `leaseShare` = `LeaseShare1155`, `humanGate` = `HumanGate`, all immutable |
| `CredentialSync` | [`0xd0783EC7B0668652718f3977Ca92235fe6bF9c56`](https://eth-sepolia.blockscout.com/address/0xd0783EC7B0668652718f3977Ca92235fe6bF9c56) | [`0x47fc7cc4…422c`](https://sepolia.etherscan.io/tx/0x47fc7cc42a2b0d35de69f00019f80840618f1778f759b21d21cdfbeebcdb422c) | escrow = `RentEscrow`, subnames = `RentoutsSubnames`, issuer on `RentoutsSubnames` (set in [`0x5f9d8b78…2ee4`](https://sepolia.etherscan.io/tx/0x5f9d8b786cbd15a7337cc754ceb6964723f4494bb00ffa3d107c98dbb2612ee4)) |

The same contracts on Etherscan: [`AIArbiter`](https://sepolia.etherscan.io/address/0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5), [`LeaseShare1155`](https://sepolia.etherscan.io/address/0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09), [`HumanGate`](https://sepolia.etherscan.io/address/0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd), [`RentEscrow`](https://sepolia.etherscan.io/address/0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18), [`CredentialSync`](https://sepolia.etherscan.io/address/0xd0783EC7B0668652718f3977Ca92235fe6bF9c56). Sourcify: `https://repo.sourcify.dev/11155111/<address>`.

**ENS, accounts and external contracts.**

| What | Address | Status |
|---|---|---|
| `rentouts.eth` (in ENS `ETHRegistry`) | owner `0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE`, expires 2027-09-25; registered in [`0x7100160a…ca7b`](https://sepolia.etherscan.io/tx/0x7100160abf684418f7c00b60e3a839662c6de1cae1db2bf57cd59210f125ca7b) | 🟢 live |
| `PermissionedResolver` proxy (ours) | [`0xBB8A105f48Ac836F549eC0B6A1a45BB7BA0961E5`](https://sepolia.etherscan.io/address/0xBB8A105f48Ac836F549eC0B6A1a45BB7BA0961E5) | 🟢 live |
| `UserRegistry` proxy (ours) | [`0xD2D122000D4725a863376EcAe4220BC20590f382`](https://sepolia.etherscan.io/address/0xD2D122000D4725a863376EcAe4220BC20590f382) | 🟢 live |
| `RentoutsSubnames` | [`0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60`](https://eth-sepolia.blockscout.com/address/0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60) | 🟢 live, source verified (Sourcify `exact_match`) |
| `alice.rentouts.eth` (demo tenant) | resolves to [`0x484811c8c967809bE644A89d677933c29fb9e936`](https://sepolia.etherscan.io/address/0x484811c8c967809bE644A89d677933c29fb9e936); claimed in [`0x882d63a5…7500`](https://sepolia.etherscan.io/tx/0x882d63a54d344760d5a10dd2455c25796ca3b930e7db50c96d9dea7b5f947500) | 🟢 live |
| Issuer EOA | [`0xF6048B190D178Fb6F0870c65CD2F7E06381713C4`](https://sepolia.etherscan.io/address/0xF6048B190D178Fb6F0870c65CD2F7E06381713C4) | 🟢 live; judged keys only since the role cleanup ([§3](#3-roles-and-trust-model)) |
| Human arbiter EOA (`AIArbiter.human`) | [`0x798b01Cef62b889943Ce1D3C5011a755B297e486`](https://sepolia.etherscan.io/address/0x798b01Cef62b889943Ce1D3C5011a755B297e486) | 🟢 live |
| AI judge key (`AIArbiter.agent`, keystore `rentouts-judge`) | [`0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA`](https://sepolia.etherscan.io/address/0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA) | 🟢 live |
| World ID 4.0 RP signer (`WorldIdV4Gate.signer`) | [`0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA`](https://sepolia.etherscan.io/address/0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA) | 🟢 live (signs off-chain only) |
| World ID verifier | [`0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`](https://sepolia.etherscan.io/address/0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa) | 🟢 live. Alice verified. First gate `0x2705…B209` superseded |
| Circle test USDC (Circle's) | [`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`](https://sepolia.etherscan.io/address/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) | 🟢 external, 6 decimals |
| ENS Universal Resolver (ENS's) | [`0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe`](https://sepolia.etherscan.io/address/0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe) | 🟢 external |
| ENS `ETHRegistry` (ENS's) | [`0x657eA849311d3D5823348ddEd7C2AaAFb3EDE09E`](https://sepolia.etherscan.io/address/0x657eA849311d3D5823348ddEd7C2AaAFb3EDE09E) | 🟢 external |

**Deploy order.** Each step needs an address from the one before, because every link is immutable except `HumanGate.verifier` and the `AIArbiter` settings. Steps 1 to 4 were broadcast on Sat 03:05–03:09 JST.

1. **`AIArbiter`** (done): `RentEscrow.arbiter` is immutable, so the arbiter must exist first.
2. **`DeployEscrow`** (done): deploys `LeaseShare1155`, then `HumanGate` (open), then `RentEscrow` with `arbiter = AIArbiter` and `humanGate = HumanGate`. It then makes the escrow the share minter. The deployer is allowlisted as the demo landlord.
3. **`bindEscrow`** (done): the human arbiter binds `AIArbiter` to that escrow, once.
4. **`CredentialSync`** (done): it takes the escrow address in its constructor and is made an issuer. The issuer role cleanup was broadcast right after.
5. **World ID** (done, Sat 12:09 JST): `WorldIdV4Gate` deployed by Dean, then `HumanGate.setVerifier(WorldIdV4Gate)` from the gate owner ([`0x56b47b25…43e8ee`](https://sepolia.etherscan.io/tx/0x56b47b25c08ecec6022814b78273d2568bc7a8a4bea4eb6b4dda04180543e8ee)). At 12:42 JST a second `setVerifier` ([`0xcd93549e…b86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671)) switched to the `fund-lease-wallet` gate alice is registered on. The escrow was not redeployed.

The commands that were run, for a redeploy:

```bash
# 1. AIArbiter (AI_HUMAN defaults to 0x798b…e486, AI_CHALLENGE_WINDOW to 120 s)
AI_AGENT=<rentouts-judge address> forge script script/DeployAIArbiter.s.sol --rpc-url sepolia \
  --account rentouts-deployer --sender <deployer> --broadcast
# 2. LeaseShare1155 + HumanGate + RentEscrow
ESCROW_ARBITER=<aiArbiter> forge script script/DeployEscrow.s.sol --rpc-url sepolia \
  --account rentouts-deployer --sender <deployer> --broadcast
# 3. The human arbiter binds the escrow, once
cast send <aiArbiter> "bindEscrow(address)" <rentEscrow> --account <human arbiter keystore> --rpc-url ${SEPOLIA_RPC_URL}
# 4. From ens/: CredentialSync for that escrow, then the issuer role cleanup
ESCROW_ADDRESS=<rentEscrow> BROADCAST=true ./scripts/ens.sh credentialSync
BROADCAST=true ./scripts/ens.sh subnames
# 5. World ID 4.0 gate, then plug it in (no escrow redeploy)
WORLD_ID_SIGNER=<RP signer address> WORLD_ACTION=fund-lease-wallet forge script script/DeployWorldIdV4Gate.s.sol \
  --rpc-url sepolia --account <funded> --broadcast
cast send <humanGate> "setVerifier(address)" <WorldIdV4Gate> --account rentouts-deployer --rpc-url ${SEPOLIA_RPC_URL}
```

Each Foundry script has a dry-run mode (omit `--broadcast`, or `BROADCAST` for `ens.sh`) that simulates without recording anything.

**Base Sepolia (84532), standalone Curvegrid proof.** This `LeaseShare1155` is not wired to an escrow. The integrated one is the Ethereum Sepolia deploy above.

| What | Link |
|---|---|
| `LeaseShare1155` | [`0x5490e5dFcDcA741aC99127f66B4abf6204cd64C5`](https://sepolia.basescan.org/address/0x5490e5dFcDcA741aC99127f66B4abf6204cd64C5) (Sourcify, exact match), deploy tx [`0x76164bf8…400c`](https://sepolia.basescan.org/tx/0x76164bf89428462ed9b8220f609cefa101efce9d4a8d677d16a27083c332400c) |
| Mint 1000 shares of lease #1 | [`0x87be65e5…5a29`](https://sepolia.basescan.org/tx/0x87be65e59b2bff356269d8e2cfe5c4a0d5b51f9ca793ad138e64c40342b95a29) |
| Allowlist a recipient | [`0xbb139655…c07a4`](https://sepolia.basescan.org/tx/0xbb1396555cf4d02c14e4eeed1209c448eae1a76de3955fa86d5f87ec2f8c07a4) |
| Transfer 400 to the allowlisted recipient (succeeds) | [`0x34227e62…dddce`](https://sepolia.basescan.org/tx/0x34227e62ef9b0002589e5827114932960eed8ea54089ccae38bd41ae442dddce) |
| Transfer to a non-allowlisted recipient | reverts `NotAllowlisted` |

Resulting balances: issuer 600, allowlisted recipient 400, totalSupply 1000.

---

## 11. Security notes and known limitations

**Scope and honesty**
- **Testnet only.** Ethereum Sepolia and **Circle's test USDC**. This is hackathon code and it has not been audited.
- **No custody by RentOuts.** `RentEscrow` has no owner, admin, fee or upgrade path, and its token, arbiter, share contract and human gate are immutable. RentOuts never holds tenant funds; the escrow contract does.
- **All code in this repo was written during the event.** A design brief ([`docs/ens/HANDOFF.md`](./docs/ens/HANDOFF.md)) was prepared in a design session at the event, and the running decision log is [`docs/ens/LOG.md`](./docs/ens/LOG.md). AI assistance is recorded in [`ens/AI_USAGE.md`](./ens/AI_USAGE.md).

**Escrow and disputes**
- **The arbiter decides disputed splits.** It can't pay anyone but the two parties and can't be a party itself. On testnet it is `AIArbiter` with a single human EOA behind it; in production the human would be a Safe multisig. The human hands its role over in two steps (`setHuman`, then `acceptHuman`), so a typo can't strand appealed leases.
- **The AI judge can be wrong.** It can be confidently wrong or swayed by plausible false statements, which is why it only proposes, behind a challenge window and a human override ([§6](#6-ai-dispute-judge)).
- **Disputes can wait.** An appealed or abstained lease stays frozen until the human rules (no timeout).
- **Prepay only.** The tenant locks the deposit plus all rent at `fundLease`. That keeps the state machine and the invariants small, and it suits short demo leases, but a real lease needs installments or streaming. With no late-payment state, `rentouts.onTimeRate` can't be derived and stays an issuer judgment.
- **Unclaimed earned rent is part of a dispute's pot.** Rent that has been earned but not claimed when a dispute opens is frozen until the ruling, and a ruling can move part of it to the tenant (the AI judge's 25 % steps, for example). `claimRent` is open to anyone, so a landlord or keeper should claim as periods elapse.
- **Payouts are pushed, and USDC can blacklist addresses.** If the landlord or the tenant is blacklisted, every call that pays them reverts, including the other party's `closeLease` and any split ruling. The other party can still `openDispute`, which moves no tokens. After that, only a 0 or 10000 bps ruling pays out, and it hands the blocked party's share to the other party. Pull payments would keep the agreed split, but they were not built for the hackathon.
- **`tenantStats` are counts.** They are not weighted by value or term, so a landlord and a tenant working together can build a record out of tiny 60-second leases for the cost of gas. The sybil brake is landlord allowlisting on `LeaseShare1155`: only allowlisted landlords can create leases, and today that is only the deployer.
- **Timing uses `block.timestamp`.** Periods are at least 60 s and challenge windows at least 60 s, so a few seconds of drift don't matter.
- **The token must be a plain ERC-20**, with no fee-on-transfer or rebasing (USDC qualifies).

**Human gate**
- **World ID gates funding through a trusted signer, not an on-chain proof check.** World ID 4.0 has no verifier contract on Ethereum Sepolia (and a 3.0 verifier cannot check a 4.0 proof), so `WorldIdV4Gate` trusts the RP signer `0xbb80…42CA`. The rule "sign only after `POST /api/v4/verify` returns `success: true` with this wallet as the signal" lives in the off-chain backend, outside this repo. On-chain, the signature is bound to chain id, gate, action, wallet, nullifier and deadline, and each nullifier registers once (tested against cross-chain, cross-gate, cross-action and wallet-substitution replays). The signer key is immutable: no rotation, no revocation and no unregister. If it leaked, anyone could register any wallet until the gate owner swaps in a new gate.
- **One World ID, one wallet, for good.** A registered wallet cannot be moved or unregistered, and a human whose nullifier is spent for an action cannot register another wallet for it.
- **The gate owner is trusted for access only.** The deployer EOA can refuse funding of new leases by choosing the verifier. It can never touch funded leases or funds. A verifier that reverts blocks new funding (fail closed) until the owner fixes or clears it.

**Lease shares**
- **Shares are not cash-flow rights.** Rent goes to `lease.landlord` whoever holds the shares; a share records the lease position.
- **The share owner is trusted.** It sets the allowlist (the KYC stand-in), can change the minter and can mint directly. Shares of a cancelled lease stay with the landlord (there is no burn). One `LeaseShare1155` per `RentEscrow`, because lease ids restart at 1 in every escrow.
- **Contract recipients must implement `onERC1155Received`.** That includes a landlord whose `createLease` mints shares.

**ENS identity**
- **The ENS admin is powerful.** The deployer holds all root roles on our `UserRegistry` and `PermissionedResolver` proxies (it can rewrite records and upgrade them) and admins `RentoutsSubnames`. Issuers can overwrite escrow-derived records until they are removed, and `sync` restores them. Names are deliberately not emancipated, so they stay revocable.
- **EIP-7702-delegated wallets.** A subname is an ERC-1155 token. An address with delegation code that doesn't implement `onERC1155Received` can't receive a name, and the same applies to lease shares. Some well-known test EOAs on Sepolia are delegated this way. The app warns when the connected account has code.
- **Sepolia ENS resets.** ENS resets the Sepolia v2 beta every few weeks, which would wipe `rentouts.eth` and every subname. All ENS phases are re-runnable, and [`ens/script/EnsSepolia.sol`](./ens/script/EnsSepolia.sol) is the only file to update for a new ENS tag.
- **Records go stale until someone syncs.** Nothing pushes updates, so after a lease closes someone has to call `sync`. The app shows when ENS is behind the escrow.
- **Availability heuristics.** A null `getEnsAddress` doesn't mean a label is free, because revoked labels resolve to null too. The app simulates `register` instead.
- **Some ENS tools may not show the names.** Tools such as the ENS app may not display ENSv2 beta names yet. Etherscan, `cast resolve-name` and the Universal Resolver always work.

---

## 12. Repo layout and running the tests

```
.
├── ARCHITECTURE.md      this file
├── src/                 RentEscrow.sol, HumanGate.sol, AIArbiter.sol, LeaseShare1155.sol,
│                        interfaces/IRentEscrow.sol, interfaces/IHumanGate.sol
├── test/                RentEscrow.t.sol, RentEscrow.invariant.t.sol, RentEscrow.blacklist.t.sol,
│                        HumanGate.t.sol, AIArbiter.t.sol, AIArbiter.invariant.t.sol,
│                        DeployEscrow.t.sol, DeployAIArbiter.t.sol, LeaseShare1155.t.sol, helpers/
├── script/              DeployAIArbiter.s.sol, DeployEscrow.s.sol (Ethereum Sepolia),
│                        DeployLeaseShare.s.sol (Base Sepolia)
├── deployments.json     "baseSepolia" (standalone LeaseShare1155); "sepolia" and
│                        "sepoliaAIArbiter" (the live deploy, written by the deploy scripts)
├── judge/               AI dispute judge (TypeScript): chain reads, prompt, providers, rubric, propose
├── ens/                 separate Foundry package: RentoutsSubnames, CredentialSync, IENSv2,
│   │                    a copy of IRentEscrow, phased deploy script, fork tests
│   └── deployments/sepolia.json
├── app/                 Vite + React + wagmi/viem frontend (reads ens/deployments/sepolia.json)
└── docs/                DECISIONS, PLAN, DEMO; diagrams/ (Mermaid sources); ens/ (HANDOFF, LOG, research)
```

`ens/src/interfaces/IRentEscrow.sol` is a verbatim copy of `src/interfaces/IRentEscrow.sol`; both include `humanGate()` and `NotVerifiedHuman`. If the core interface changes, copy it again.

```bash
# Root package: RentEscrow, HumanGate, AIArbiter, LeaseShare1155 (Foundry, OpenZeppelin v5.1)
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git      # once (a plain copy under lib/)
forge test                                        # all 163, incl. both invariant campaigns
forge test --match-path 'test/RentEscrow*' -vv    # escrow only (INV-1..INV-4, 64 runs x 256 calls)
forge test --match-path 'test/AIArbiter*' -vv     # AI arbiter (AI-1..AI-3)

# AI judge (Node >= 24, no build step)
cd judge
npm ci
npx tsc --noEmit && npx vitest run                # 92 tests, no real API calls (one needs cast on PATH)
npm run judge -- --input fixtures/damage-admitted.json --provider mock   # offline, no key, no chain
npm run judge -- --input fixtures/injection.json --provider mock         # ABSTAIN, escalated to the human

# ENS package: fork tests against live ENSv2 on Ethereum Sepolia
cd ens
git submodule update --init --recursive           # forge-std
forge test                                        # 42 fork tests; uses SEPOLIA_RPC_URL, or a public Sepolia RPC

# App
cd app
npm install
npm test                                          # vitest unit tests
npm run build                                     # tsc --noEmit + vite build
npm run ens:smoke                                 # live read of alice.rentouts.eth through the Universal Resolver
npm run dev                                       # local app; set VITE_* addresses in .env.local (DEMO.md lists the live values)
```

---

## 13. Diagram sources

Every diagram in this file is a Mermaid block and renders on GitHub. The two `LeaseShare1155` diagrams also have editable sources: [`docs/diagrams/architecture.mmd`](./docs/diagrams/architecture.mmd) and [`docs/diagrams/compliance-gate.mmd`](./docs/diagrams/compliance-gate.mmd). Render any of them to SVG with `npx -y @mermaid-js/mermaid-cli@11 -i <file>.mmd -o <file>.svg`.
