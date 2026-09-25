# RentOuts × ENSv2 — portable rental identity

Tenants get a soulbound **`<name>.rentouts.eth`** on the **ENSv2 beta (Ethereum Sepolia)**. It carries
their rental credential as ENS text records that only RentOuts issuers can write, and any
ENSv2-aware app can read it through the Universal Resolver. There is no RentOuts API in the read path.

| What | ENSv2 primitive we use |
|---|---|
| Subname registry for `rentouts.eth` | a **`UserRegistry`** proxy, deployed via ENS's `VerifiableFactory` and set as the parent's subregistry at registration |
| Soulbound credential | subnames are registered with an **empty token role bitmap**. The holder never gets `ROLE_CAN_TRANSFER_ADMIN`, so ENS reverts `unsafeTransfer` with `TransferDisallowed`. ERC-1155 safe transfers revert too, because the registry is not emancipated |
| Revocation | ENS **`unregister`**. `RentoutsSubnames` holds the root `ROLE_UNREGISTER`, so names are deliberately not emancipated. Subnames never expire; revocation is the only way a credential ends |
| Wiping a revoked record | **`linkToRecord(name, 0)`** on the resolver detaches the old record, and a fresh record then holds only `rentouts.status=revoked` |
| Multichain address | one **ENSIP-19 default EVM address** record (`0x80000000`) answers Ethereum (coin 60) *and* Base / any EVM chain |
| Issuer-only credential records | one shared **`PermissionedResolver`**. Issuers hold **Enhanced Access Control** roles **scoped to specific keys** (`grantSetterRoles`), so an issuer can write `rentouts.onTimeRate` but not `avatar`, and holders can't forge their own record |
| Reads | viem `getEnsAddress` / `getEnsText` → ENSv2 **Universal Resolver**. No addresses are hard-coded in the app |

### Records

| Key | Written by | Example |
|---|---|---|
| `addr` (ENSIP-19 default EVM, coin 60 for contract wallets) | `RentoutsSubnames` on claim | holder's address |
| `rentouts.credential` | `RentoutsSubnames` on claim | `tenant/v1` |
| `rentouts.status` | `RentoutsSubnames` (claim / revoke) | `active` / `revoked` |
| `rentouts.leasesCompleted`, `rentouts.onTimeRate`, `rentouts.disputes`, `rentouts.rating`, `rentouts.escrow`, `rentouts.verified` | issuer (key-scoped EAC role, or `setCredential`) | `3`, `100`, `0` … |
| `avatar`, `description`, `url`, `com.twitter`, `com.github` | holder via `setProfileText` | … |

## Layout

```
ens/
  src/RentoutsSubnames.sol         register / setCredential / setProfileText / revoke
  src/interfaces/IENSv2.sol        minimal ENSv2 interfaces (contracts-v2 tag sepolia-deployment-2026-09-15)
  script/EnsSepolia.sol            ENSv2 Sepolia addresses (the only file to touch if ENS redeploys)
  script/DeployEns.s.sol           phased deploy: status | infra | commit | register | subnames | profile | claim
  scripts/ens.sh                   wrapper: dry-run by default, BROADCAST=true to send
  test/RentoutsSubnames.fork.t.sol fork tests against live ENSv2 on Sepolia
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
```

Signing uses a Foundry keystore account (`rentouts-deployer` by default). No private keys go in `.env` or on the command line.

- **Registering the parent:** commit/reveal through ENS's `ETHRegistrar`. The fee is paid in ENS's Sepolia MockUSDC, about 8 USDC per year for a 5+ character label.
- **Wait between steps:** the wrapper waits 90 s between `commit` and `register`.
- **Re-running:** every phase is safe to re-run. ENS resets the Sepolia v2 beta every few weeks; if that happens, bump `EnsSepolia.sol` to the new tag and run `all` again.

## Notes

- **Issuer account:** `ENS_ISSUER` must be a second account, not the deployer. The deployer holds root resolver roles, so it can write any key and would hide the key-scoped limit. To remove an issuer, run `./scripts/ens.sh removeIssuer` with `ENS_REMOVE_ISSUER=<address>`. It disables the issuer on the contract *and* revokes its resolver key roles.
- **Frontend claim check:** before enabling Claim, call `simulateContract` on `register(label, account)` and map its custom errors: `InvalidLabel`, `AlreadyHasName`, `LabelRetired`, `LabelTaken`. A null `getEnsAddress` does **not** mean a label is free, because revoked labels also resolve to null. On wallet connect, read `labelOf(account)` to skip the claim step for returning tenants. Validate input with viem `normalize()`.
- **Frontend trust check:** only show `rentouts.*` values when `rentouts.status == "active"` and `addr(name)` equals the expected tenant.
- **Wallets with EIP-7702 delegations:** a subname is an ERC-1155 token. A holder address with contract code must implement `onERC1155Received`. Some EOAs on Sepolia have 7702 delegations to contracts that don't, and minting to them reverts.
- **Revocation wipes records:** the credential shares the parent's resolver, so after `unregister` the Universal Resolver falls back to the parent resolver and would still find the old record. `revoke` therefore detaches it (`linkToRecord(name, 0)`), leaves only `rentouts.status=revoked`, and retires the label.
