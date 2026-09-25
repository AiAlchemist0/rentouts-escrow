# RentOuts × ENSv2 — portable rental identity

Tenants get a soulbound **`<name>.rentouts.eth`** on the **ENSv2 beta (Ethereum Sepolia)**. It carries
their rental credential as ENS text records that only RentOuts issuers can write, and any
ENSv2-aware app can read it through the Universal Resolver. There is no RentOuts API in the read path.
The rental track record (leases completed, disputes, rent paid, deposit return rate) is **derived
on-chain from the RentEscrow contract** by a permissionless `CredentialSync.sync(tenant)` call. Anyone
can check those values against the escrow and restore them with `sync`. RentOuts issuers can still
overwrite them while they hold issuer status (see the trust model below).

| What | ENSv2 primitive we use |
|---|---|
| Subname registry for `rentouts.eth` | a **`UserRegistry`** proxy, deployed via ENS's `VerifiableFactory` and set as the parent's subregistry at registration |
| Soulbound credential | subnames are registered with an **empty token role bitmap**. The holder never gets `ROLE_CAN_TRANSFER_ADMIN`, so ENS reverts `unsafeTransfer` with `TransferDisallowed`. ERC-1155 safe transfers revert too, because the registry is not emancipated |
| Revocation | ENS **`unregister`**. `RentoutsSubnames` holds the root `ROLE_UNREGISTER`, so names are deliberately not emancipated. Subnames never expire; revocation is the only way a credential ends |
| Wiping a revoked record | **`linkToRecord(name, 0)`** on the resolver detaches the old record, and a fresh record then holds only `rentouts.status=revoked` |
| Multichain address | one **ENSIP-19 default EVM address** record (`0x80000000`) answers Ethereum (coin 60) *and* Base / any EVM chain |
| Escrow-derived credential | **`CredentialSync.sync(tenant)`**: anyone may call it. It reads `RentEscrow.tenantStats(tenant)` and writes the records through `RentoutsSubnames.setCredential`, as an issuer contract |
| Issuer-only credential records | one shared **`PermissionedResolver`**. Issuers hold **Enhanced Access Control** roles **scoped to specific keys** (`grantSetterRoles`), so an issuer can write `rentouts.onTimeRate` but not `avatar`, and holders can't forge their own record |
| Reads | viem `getEnsAddress` / `getEnsText` → ENSv2 **Universal Resolver**. No addresses are hard-coded in the app |

### Records

| Key | Written by | Example |
|---|---|---|
| `addr` (ENSIP-19 default EVM, coin 60 for contract wallets) | `RentoutsSubnames` on claim | holder's address |
| `rentouts.credential` | `RentoutsSubnames` on claim | `tenant/v1` |
| `rentouts.status` | `RentoutsSubnames` (claim / revoke) | `active` / `revoked` |
| `rentouts.leasesCompleted` | `CredentialSync.sync`, from `tenantStats.leasesCompleted` (closed without a dispute) | `3` |
| `rentouts.disputes` | `CredentialSync.sync`, from `tenantStats.leasesDisputed` | `0` |
| `rentouts.rentPaid` | `CredentialSync.sync`, from `tenantStats.rentPaid`: USDC (6 decimals) written with 2 decimals, rounded down | `1250.00` |
| `rentouts.depositReturnRate` | `CredentialSync.sync`: `depositsReturned * 100 / depositsPosted`, whole percent, rounded down, capped at 100. `n/a` until a lease with a deposit has ended. For a lease that ended in a dispute, the escrow counts the tenant's share of everything still escrowed (deposit plus unreleased prepaid rent), capped at the deposit, as returned. So a refund of prepaid rent raises the rate even when the landlord kept the deposit | `100`, `50`, `n/a` |
| `rentouts.escrow` | `CredentialSync.sync`: CAIP-10 id of the escrow the stats come from | `eip155:11155111:0x…` (lowercase) |
| `rentouts.onTimeRate`, `rentouts.rating`, `rentouts.verified` | issuer EOA (key-scoped EAC role on the resolver, or `setCredential`): judgments the escrow can't derive | `100`, `5`, `true` |
| `avatar`, `description`, `url`, `com.twitter`, `com.github` | holder via `setProfileText` | … |

## Layout

```
ens/
  src/RentoutsSubnames.sol         register / setCredential / setProfileText / revoke
  src/CredentialSync.sol           permissionless sync(tenant): escrow tenantStats -> rentouts.* records
  src/interfaces/IENSv2.sol        minimal ENSv2 interfaces (contracts-v2 tag sepolia-deployment-2026-09-15)
  src/interfaces/IRentEscrow.sol   escrow interface, copied verbatim from the core escrow package
  script/EnsSepolia.sol            ENSv2 Sepolia addresses (the only file to touch if ENS redeploys)
  script/DeployEns.s.sol           phased deploy: status | infra | commit | register | subnames | profile | claim
                                   | removeIssuer | credentialSync | finalizeCredentialSync | sync
  scripts/ens.sh                   wrapper: dry-run by default, BROADCAST=true to send
  test/EnsForkBase.sol             shared fork setup: fresh ENSv2 proxies, parent via commit/reveal
  test/RentoutsSubnames.fork.t.sol fork tests against live ENSv2 on Sepolia
  test/CredentialSync.fork.t.sol   CredentialSync against live ENSv2, with a mock escrow for the stats
  test/DeployEnsRoles.fork.t.sol   the script's issuer key roles: judged keys only, removeIssuer revokes all
  test/DeployEnsPhases.fork.t.sol  the script's phases end to end: credentialSync fresh/reuse/replace/interrupted,
                                   removeIssuer sticks, subnames re-run, state-file checks
  test/DeployEnsHarness.sol        the deploy script with per-test env and sender (no vm.setEnv races)
  deployments/sepolia.json         written by the deploy script (addresses for the app)
```

## Run it

Requires [Foundry](https://getfoundry.sh).

```bash
cd ens
forge test                                   # fork tests (uses SEPOLIA_RPC_URL or a public Sepolia RPC)
cp .env.example .env                         # then fill DEPLOYER, ENS_ISSUER (a 2nd account) and ENS_DEMO_HOLDER
./scripts/ens.sh status                      # read-only
BROADCAST=true ./scripts/ens.sh all          # parent -> subnames -> profile -> claim (asks for the keystore password)

# once RentEscrow is deployed:
ESCROW_ADDRESS=0x... BROADCAST=true ./scripts/ens.sh credentialSync   # deploy/reuse CredentialSync, make it an issuer, record it
ENS_SYNC_TENANT=0x... BROADCAST=true ./scripts/ens.sh sync            # refresh one tenant's records
```

`sync` is permissionless, so any wallet can also call it directly:
`cast send <credentialSync> "sync(address)" <tenant> --account <you> --rpc-url $SEPOLIA_RPC_URL`.
Pass `ESCROW_ADDRESS` / `ENS_SYNC_TENANT` inline or in `.env`, not both: `.env` is sourced last and wins.

Signing uses a Foundry keystore account (`rentouts-deployer` by default). No private keys go in `.env` or on the command line.

- **Registering the parent:** commit/reveal through ENS's `ETHRegistrar`. The fee is paid in ENS's Sepolia MockUSDC, about 8 USDC per year for a 5+ character label.
- **Wait between steps:** the wrapper waits 90 s between `commit` and `register`.
- **Re-running:** every phase is safe to re-run. ENS resets the Sepolia v2 beta every few weeks; if that happens, bump `EnsSepolia.sol` to the new tag and run `all` again.
- **Rehearsing on an anvil fork:** `anvil --fork-url $SEPOLIA_RPC_URL --auto-impersonate`, then `RPC_OVERRIDE=http://127.0.0.1:8545 UNLOCKED=1 BROADCAST=true ./scripts/ens.sh <phase>`. The fork keeps Sepolia's chain id, so the wrapper sends receipts to `broadcast-local/` and state to `deployments/local.json` (copied from `sepolia.json` the first time; both gitignored). It refuses `ENS_STATE=deployments/sepolia.json`. The committed receipts in `broadcast/` only ever record real Sepolia transactions.

## On-chain credential sync

`CredentialSync` (`src/CredentialSync.sol`) replaces an off-chain relayer. `sync(tenant)`:

1. reverts with `NoName(tenant)` if the tenant has no active rentouts name (`labelOf(tenant) == ""`, which also covers revoked names);
2. reads `escrow.tenantStats(tenant)`;
3. writes the five escrow-derived keys in the records table through `RentoutsSubnames.setCredential`, and emits `Synced(tenant, label, leasesCompleted, disputes)`.

It is an issuer on `RentoutsSubnames`. If the admin removes it (`setIssuer(sync, false)`), `sync` reverts with `NotIssuer`. A sync writes 5 text records: about 350k gas for the first write and about 210k gas for a refresh (fork-test gas report).

The `credentialSync` phase is safe to re-run:
- **Same `ESCROW_ADDRESS`:** it reuses the deployed contract and sends nothing.
- **New `ESCROW_ADDRESS`, or a new `RentoutsSubnames`:** it first takes the issuer right away from every older `CredentialSync`, on the `RentoutsSubnames` that sync writes through. Then it deploys the new contract and makes it an issuer. Stale stats can't be written.
- **Recording:** forge writes the state file before it sends anything, so the run records the contract as `pendingCredentialSync` and keeps the older ones in `retiredCredentialSyncs`. The wrapper then runs `finalize`, which writes `credentialSync` and `escrow` only once the chain shows the contract deployed, an issuer, and every retired sync revoked. If a broadcast stops half way, re-run `credentialSync`: it reuses whatever landed and still revokes the old contract. `BROADCAST=true ./scripts/ens.sh finalize` repeats only that check-and-record step.
- **After an escrow change,** names keep the old escrow's stats and `rentouts.escrow` until someone calls `sync` for them. An app should compare `rentouts.escrow` with the escrow it uses before showing the values.

**Trust model.** The escrow-derived keys are verifiable, but not write-protected against RentOuts issuers:
- Any `RentoutsSubnames` issuer, including the issuer EOA, can call `setCredential` on any `rentouts.*` key, so it can overwrite these records until the admin removes it (`removeIssuer`).
- On the resolver itself, the `subnames` phase gives the issuer EOA key-scoped roles for `rentouts.onTimeRate`, `rentouts.rating` and `rentouts.verified` only. It revokes any role the issuer EOA holds on an escrow-derived key. The first live deploy granted `rentouts.leasesCompleted`, `rentouts.disputes` and `rentouts.escrow`. Re-running `BROADCAST=true ./scripts/ens.sh subnames` once removes them (3 `revokeRoles` txs; the other steps are skipped). The same fix with cast, per key: `cast send <resolver> "revokeRoles(uint256,uint256,address)" $(cast keccak rentouts.leasesCompleted) 16 <issuer> --account rentouts-deployer --rpc-url $SEPOLIA_RPC_URL`.

The values are a pure function of public escrow state, though. Anyone can call `sync` to restore them (tested), and an app can compare them with `escrow.tenantStats(tenant)` before showing them.

This is testnet only: Ethereum Sepolia and Circle's test USDC. The escrow's dispute arbiter is a single EOA for the hackathon; production would use a Safe.

## Notes

- **Issuer account:** `ENS_ISSUER` must be a second account, not the deployer. The deployer holds root resolver roles, so it can write any key and would hide the key-scoped limit.
- **Removing an issuer:** `ENS_REMOVE_ISSUER=<address> BROADCAST=true ./scripts/ens.sh removeIssuer` disables the issuer on the contract *and* revokes its resolver key roles. It also drops the account from `issuer` in the state file and adds it to `removedIssuers`. A later `subnames` or `all` run refuses a removed `ENS_ISSUER` instead of granting it back: put a new account in `ENS_ISSUER`, or set `ENS_REINSTATE_ISSUER=<that address>` to re-enable it on purpose.
- **Frontend claim check:** before enabling Claim, call `simulateContract` on `register(label, account)` and map its custom errors: `InvalidLabel`, `AlreadyHasName`, `LabelRetired`, `LabelTaken`. A null `getEnsAddress` does **not** mean a label is free, because revoked labels also resolve to null. On wallet connect, read `labelOf(account)` to skip the claim step for returning tenants. Validate input with viem `normalize()`.
- **Frontend trust check:** only show `rentouts.*` values when `rentouts.status == "active"`, `addr(name)` equals the expected tenant, and `RentoutsSubnames.labelOf(tenant)` equals the name's label. All three are needed; see [Known limitations](#known-limitations-and-operations).
- **Keeping records fresh:** records only change when someone calls `sync`. The app can call `CredentialSync.sync(account)` after a lease closes, or show a "Sync" button. It can read `escrow.tenantStats(account)` to tell whether the ENS records are behind.
- **Wallets with EIP-7702 delegations:** a subname is an ERC-1155 token. A holder address with contract code must implement `onERC1155Received`. Some EOAs on Sepolia have 7702 delegations to contracts that don't, and minting to them reverts.
- **Revocation wipes records:** the credential shares the parent's resolver, so after `unregister` the Universal Resolver falls back to the parent resolver and would still find the old record. `revoke` therefore detaches it (`linkToRecord(name, 0)`), leaves only `rentouts.status=revoked`, and retires the label.

## Known limitations and operations

The live `RentoutsSubnames` stays as deployed: `alice.rentouts.eth` and every address above keep working. These are the known gaps and how we handle them without a redeploy (team decisions, 2026-09-26).

- **Revoke retires the label, not the wallet.** `revoke` wipes the record, burns the token and retires the label for good, but it doesn't ban the address. The same wallet can `register` a new label straight away and get a fresh `rentouts.status=active` record, without the issuer-judged keys. A per-address ban would be cosmetic, because anyone can make a new wallet. The real fix is one human, one name: World ID through the escrow's `HumanGate` seam. Until then, an app that cares about sanctions can look up `Revoked(label, holder, reason)` events for the holder (`holder` is indexed). It should also rely on the escrow-derived records: `escrow.tenantStats` is keyed by address, so a wallet's disputes follow it to a new label after `sync`.
- **Issuer key roles are resolver-global.** `grantSetterRoles` scopes a role to a text key, not to a name. The issuer EOA can write `rentouts.onTimeRate`, `rentouts.rating` and `rentouts.verified` on any name that uses this resolver. That includes the parent and the resolver's default record (name `0x00`), which every unregistered `*.rentouts.eth` falls back to. It still can't write `addr`, `rentouts.status` or `rentouts.credential`, because those need root roles that only `RentoutsSubnames` holds. So an app must check three things before it shows `rentouts.*` values: `rentouts.status == "active"`, `addr(name)` equals the tenant, and `RentoutsSubnames.labelOf(tenant)` equals the name's label.
- **Admin handover (runbook).** `transferAdmin(newAdmin)` moves only the admin right. The old admin stays an issuer (the constructor made it one), and the new admin is not an issuer. Follow the transfer with two `setIssuer` calls from the new admin (for a Safe, use its transaction builder):

  ```bash
  cast send $SUBNAMES "transferAdmin(address)" $NEW_ADMIN --account rentouts-deployer --rpc-url $SEPOLIA_RPC_URL
  # then, as NEW_ADMIN:
  #   setIssuer(<old admin>, false)
  #   setIssuer(<new admin>, true)     only if the new admin should register or revoke names itself
  cast call $SUBNAMES "isIssuer(address)(bool)" <old admin> --rpc-url $SEPOLIA_RPC_URL   # false
  ```

  The old admin can also send both `setIssuer` calls before it transfers, because admin rights don't depend on issuer status. The phases that call `setIssuer` (`subnames`, `removeIssuer`, `credentialSync`) then need the new admin as `DEPLOYER`.
- **The deployer holds the proxy upgrade roles.** The `infra` phase gives the deployer `ALL_ROLES` on the `PermissionedResolver` and `UserRegistry` proxies. That includes `ROLE_UPGRADE` and the root `ROLE_LINK` and `ROLE_UNREGISTER`. That one key could upgrade either proxy or relink any record, so "soulbound" and "only issuers write" hold only while it is honest. That's acceptable on testnet. Later, hand both proxies to a Safe: `grantRootRoles(ALL_ROLES, safe)` on each, then `revokeRootRoles(ALL_ROLES, deployer)`. Move the `RentoutsSubnames` admin (above) and the `rentouts.eth` token to the Safe in the same step.
- **One state file per parent.** Every phase refuses a state file whose `ensParentName` isn't `<ENS_PARENT_LABEL>.eth`. It also refuses a `RentoutsSubnames` whose `parentName()`, registry or resolver differ from the state file. Serving another parent needs a new `ENS_STATE` file and a new `RentoutsSubnames`. Besides the addresses, the file holds `pendingCredentialSync` / `pendingEscrow` (a `credentialSync` run not yet confirmed), `retiredCredentialSyncs` (re-checked on every run) and `removedIssuers`.
