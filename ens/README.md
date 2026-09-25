# RentOuts × ENSv2 — portable rental identity

Tenants get a soulbound **`<name>.rentouts.eth`** on the **ENSv2 beta (Ethereum Sepolia)**. It carries
their rental credential as ENS text records that only RentOuts issuers can write, and any
ENSv2-aware app can read it through the Universal Resolver. There is no RentOuts API in the read path.
The rental track record (leases completed, disputes, rent paid, deposit return rate) is **derived
on-chain from the RentEscrow contract** by a permissionless `CredentialSync.sync(tenant)` call, so no
relayer or RentOuts server decides those values either.

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
| `rentouts.depositReturnRate` | `CredentialSync.sync`: `depositsReturned * 100 / depositsPosted`, whole percent, rounded down, capped at 100. `n/a` until a lease with a deposit has ended | `100`, `50`, `n/a` |
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
                                   | credentialSync | sync
  scripts/ens.sh                   wrapper: dry-run by default, BROADCAST=true to send
  test/EnsForkBase.sol             shared fork setup: fresh ENSv2 proxies, parent via commit/reveal
  test/RentoutsSubnames.fork.t.sol fork tests against live ENSv2 on Sepolia
  test/CredentialSync.fork.t.sol   CredentialSync against live ENSv2, with a mock escrow for the stats
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
ESCROW_ADDRESS=0x... BROADCAST=true ./scripts/ens.sh credentialSync   # deploy CredentialSync, make it an issuer
ENS_SYNC_TENANT=0x... BROADCAST=true ./scripts/ens.sh sync            # refresh one tenant's records
```

`sync` is permissionless, so any wallet can also call it directly:
`cast send <credentialSync> "sync(address)" <tenant> --account <you> --rpc-url $SEPOLIA_RPC_URL`.
Pass `ESCROW_ADDRESS` / `ENS_SYNC_TENANT` inline or in `.env`, not both: `.env` is sourced last and wins.

Signing uses a Foundry keystore account (`rentouts-deployer` by default). No private keys go in `.env` or on the command line.

- **Registering the parent:** commit/reveal through ENS's `ETHRegistrar`. The fee is paid in ENS's Sepolia MockUSDC, about 8 USDC per year for a 5+ character label.
- **Wait between steps:** the wrapper waits 90 s between `commit` and `register`.
- **Re-running:** every phase is safe to re-run. ENS resets the Sepolia v2 beta every few weeks; if that happens, bump `EnsSepolia.sol` to the new tag and run `all` again.

## On-chain credential sync

`CredentialSync` (`src/CredentialSync.sol`) replaces an off-chain relayer. `sync(tenant)`:

1. reverts with `NoName(tenant)` if the tenant has no active rentouts name (`labelOf(tenant) == ""`, which also covers revoked names);
2. reads `escrow.tenantStats(tenant)`;
3. writes the five escrow-derived keys in the records table through `RentoutsSubnames.setCredential`, and emits `Synced(tenant, label, leasesCompleted, disputes)`.

It is an issuer on `RentoutsSubnames`. If the admin removes it (`setIssuer(sync, false)`), `sync` reverts with `NotIssuer`. The `credentialSync` phase is safe to re-run. It reuses the deployed contract when the escrow is unchanged. When `ESCROW_ADDRESS` changes, it deploys a new contract and takes issuer rights away from the old one, so stale stats can't be written. It records `credentialSync` and `escrow` in `deployments/sepolia.json`. A sync writes 5 text records: about 350k gas for the first write and about 210k gas for a refresh (fork-test gas report).

**Trust model.** The escrow-derived keys are verifiable, but not write-protected against RentOuts issuers:
- The issuer EOA's key-scoped roles from the first deploy include `rentouts.leasesCompleted`, `rentouts.disputes` and `rentouts.escrow`. They were granted before `CredentialSync` existed.
- Any `RentoutsSubnames` issuer can call `setCredential` on any `rentouts.*` key.

The values are a pure function of public escrow state, though. Anyone can call `sync` to restore them (tested), and an app can compare them with `escrow.tenantStats(tenant)` before showing them.

This is testnet only: Ethereum Sepolia and Circle's test USDC. The escrow's dispute arbiter is a single EOA for the hackathon; production would use a Safe.

## Notes

- **Issuer account:** `ENS_ISSUER` must be a second account, not the deployer. The deployer holds root resolver roles, so it can write any key and would hide the key-scoped limit. To remove an issuer, run `./scripts/ens.sh removeIssuer` with `ENS_REMOVE_ISSUER=<address>`. It disables the issuer on the contract *and* revokes its resolver key roles.
- **Frontend claim check:** before enabling Claim, call `simulateContract` on `register(label, account)` and map its custom errors: `InvalidLabel`, `AlreadyHasName`, `LabelRetired`, `LabelTaken`. A null `getEnsAddress` does **not** mean a label is free, because revoked labels also resolve to null. On wallet connect, read `labelOf(account)` to skip the claim step for returning tenants. Validate input with viem `normalize()`.
- **Frontend trust check:** only show `rentouts.*` values when `rentouts.status == "active"` and `addr(name)` equals the expected tenant.
- **Keeping records fresh:** records only change when someone calls `sync`. The app can call `CredentialSync.sync(account)` after a lease closes, or show a "Sync" button. It can read `escrow.tenantStats(account)` to tell whether the ENS records are behind.
- **Wallets with EIP-7702 delegations:** a subname is an ERC-1155 token. A holder address with contract code must implement `onERC1155Received`. Some EOAs on Sepolia have 7702 delegations to contracts that don't, and minting to them reverts.
- **Revocation wipes records:** the credential shares the parent's resolver, so after `unregister` the Universal Resolver falls back to the parent resolver and would still find the old record. `revoke` therefore detaches it (`linkToRecord(name, 0)`), leaves only `rentouts.status=revoked`, and retires the label.
