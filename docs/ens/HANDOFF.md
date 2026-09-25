# ENS track handoff: RentOuts × ENSv2 (ETHGlobal Tokyo 2026)

**Owner:** Bektur (Identity/ENS track). **Branch:** `ens-integration` (merge into `main` later with a PR, together with Dean).
**Written:** Fri 2026-09-25, about 21:45 JST, by the cloud Claude session. The work continues in a local Claude Code session on Bektur's laptop.
**Read this first, then** [`research/ensv2-docs-research.md`](./research/ensv2-docs-research.md). That file has the raw facts behind this doc, with sources.

> **For the local Claude session:** this doc is your brief. The cloud session had **no Sepolia RPC and no Foundry**, so nothing here has been run on-chain yet. Everything marked "(verify)" must be checked with `cast` or a fork test before you rely on it. Addresses come from ENS's own deployment file at tag `sepolia-deployment-2026-09-15`. Do not take addresses from blog posts, ensjs npm releases or community kits, which are all stale (see §9).

---

## 0. TL;DR

1. **ENSv2 on Sepolia is the only on-chain path.** ENS v1 registration on Sepolia is disabled; the official docs say "new registrations happen exclusively in ENSv2". **The v1 fallback in the build spec (§3.4/§9) is dead** unless someone already owns a v1 name. NameStone is shut down, and Durin needs a v1 parent. Treat v2 as the plan.
2. **The build spec's `RentoutsSubnames` design maps cleanly onto real v2 primitives:**
   - **Subname registry:** a `UserRegistry` proxy for `rentouts.eth`, deployed via `VerifiableFactory`.
   - **Non-transferable (soulbound):** register subnames **without** `ROLE_CAN_TRANSFER_ADMIN`. The registry then refuses transfers natively (`TransferDisallowed`).
   - **Revocable:** our contract holds root `ROLE_UNREGISTER` on the `UserRegistry`, so `unregister(tokenId)` burns the name.
   - **Credential text records only the issuer can write:** a `PermissionedResolver` proxy, where the issuer gets `ROLE_SET_TEXT` **scoped to specific keys** (for example `rentouts.leasesCompleted`) via EAC `grantSetterRoles`. That is exactly the "Enhanced Access Control delegated right" the spec wants.
3. **Gotcha:** PermissionedResolver permissions are **per record key (and root), not per name**. Whoever holds `ROLE_SET_TEXT` for key `X` can write `X` on *any* name in that resolver. So the design is **one shared resolver**:
   - The issuer holds the credential keys (`rentouts.*`).
   - The `RentoutsSubnames` contract holds the profile keys (`avatar`, `description`, …) and exposes an owner-checked `setProfileText`.
   - Users never get raw resolver roles.
4. **Cross-chain:** the escrow is on **Base Sepolia**, ENS on **Ethereum Sepolia**. The escrow cannot call ENS. A small **relayer/issuer script** reads escrow events on Base and writes credential text records on Sepolia. For the demo it can be a CLI or button-triggered script. No escrow changes are needed; it only reads the escrow's existing events.
5. **Sepolia v2 gets redeployed and reset every 4–6 weeks.** The last reset was 09-15, and names from before it vanished. Script everything so it can be re-run (register, deploy, grant roles) in minutes. Hard-code only the Universal Resolver proxy, and only the frontend's viem `sepolia` chain uses it implicitly anyway.
6. **Real deadline: Sun 09:00 JST**, not the spec's 16:30. The **ENS go/no-go gate is Sat 03:00 JST**: by then `alice.rentouts.eth` must resolve `addr` + one `rentouts.*` text through the Universal Resolver on Sepolia.

---

## 1. What you're building (from the build spec, §0 step 2 and §3.4)

> **Demo step 2, "Claim identity":** the renter mints `alice.rentouts.eth` (an ENSv2 subname on Ethereum Sepolia) carrying a non-transferable rental credential.

Spec'd interface (keep these names; the frontend and teammates expect them):

```solidity
function register(string calldata label, address owner) external;                 // mint subname (non-transferable)
function setCredential(string calldata label, string calldata key, string calldata val) external; // onlyIssuer (EAC-gated)
function revoke(string calldata label) external;                                   // onlyIssuer
```

Files per spec §2:

```
ens/
  src/RentoutsSubnames.sol      # subname registrar + resolver writer + roles
  script/DeployEns.s.sol        # deploys + wires roles + writes deployments.json "sepolia" block
  test/RentoutsSubnames.t.sol   # fork tests against live Sepolia v2 (see §6)
  scripts/ (TS, viem)           # register-parent.ts, sync-credentials.ts (relayer), resolve.ts (smoke test)
app/src/lib/ens.ts              # read helpers for the ClaimName step + profile credential (shared frontend)
```

Timeline items from the spec's build board (Identity/ENS column), re-timed to the real deadline in §8.

---

## 2. ENSv2 Sepolia ground truth

Source: `ensdomains/contracts-v2`, tag **`sepolia-deployment-2026-09-15`** (commit `f2f0a05`), file `contracts/deployments/sepolia/addresses.md`. The docs site pins commit `71a3b733`, which has the same address set.

| Contract | Address | Use |
|---|---|---|
| ETHRegistrar | `0xAbe76F6C8DFcEd81AA5A2bB8034202A7136b94ca` | commit/reveal registration of `rentouts.eth` |
| ETHRegistry | `0x657eA849311d3D5823348ddEd7C2AaAFb3EDE09E` | `.eth` registry (the 2LD's `setSubregistry` / `setResolver`) |
| RootRegistry | `0x9703dbd26dab89504490994138cf2c575251a9ce` | root |
| VerifiableFactory | `0x9e726Eb570beb6BCEb495AB8cdA7df517d4e841C` | `deployProxy(impl, salt, initData)` |
| UserRegistryImpl | `0xA80338aAA8D23831cEa25E858D1774534aBb0263` | implementation for our subname registry proxy |
| PermissionedResolverImpl | `0x14F09Fd05d4585759e54844DC9B00147131Cf243` | implementation for our resolver proxy |
| UpgradableUniversalResolverProxy | `0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe` | **the** UR; viem ≥2.35 `sepolia` already uses it |
| UniversalResolverV2 (impl) | `0x5d25c1d6acbb71b7a28aa7899618a3412a8303e3` | don't call directly |
| UniversalHelper | `0x33f571aa8a160a21b877cf6e0fb8806692b97df5` | registry walks (optional) |
| StandardRentPriceOracle | `0x9b0b9c65bdaf9794ff7697e4dcfb1f50581072bb` | pricing / `isPaymentToken` |
| MockUSDC (ENS's) | `0x16f95D91DBa7dA3Aca778Ec053dF0FF6C6A8aA8e` | pays ENS fees. Open `mint`, **but also open `nuke(owner)`, which burns anyone's balance**. Never use it for escrow funds. |
| Circle Sepolia USDC | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | also accepted by the registrar (verify `isPaymentToken`) |
| ReverseRegistrar (v1 infra) | `0xA0a1AbcDAe1a2a4A2EF8e9113Ff0e02DD81DC0C6` | primary names (`addr.reverse`), stretch |
| DefaultReverseRegistrar | `0x4F382928805ba0e23B30cFB75fC9E848e82DFD47` | ENSIP-19 `default.reverse`, stretch |
| PublicResolverV2 | `0xd7e590ad0e92a6ac1d81f4483a9b951d3585a50f` | **don't use**: it only authorizes v1-NameWrapper-known names |

The full list is in the research file. Add `ensdomains/contracts-v2` as a Foundry dependency **at the tag** (there is no npm package):

```bash
cd ens && forge install ensdomains/contracts-v2@sepolia-deployment-2026-09-15
# deployment ABIs are in lib/contracts-v2/contracts/deployments/sepolia/*.json
```

(verify) The Foundry project layout inside contracts-v2 is `contracts/` (it has `foundry.toml` and `foundry.lock` there). Its Solidity pragma is `0.8.25` for UserRegistry. Remappings may need care, so importing just the **interfaces** you need, or vendoring minimal interfaces, may be simpler than compiling their whole tree.

### 2.1 Role bits you need (copied from source at the tag)

`contracts/src/registry/libraries/RegistryRolesLib.sol`. EAC packs one role per nybble; the admin role = role `<< 128`.

```solidity
ROLE_REGISTRAR          = 1 << 0;    // register new names (root only)
ROLE_UNREGISTER         = 1 << 12;   // root or token
ROLE_RENEW              = 1 << 16;   // root or token
ROLE_SET_SUBREGISTRY    = 1 << 20;   // root or token
ROLE_SET_RESOLVER       = 1 << 24;   // root or token
ROLE_CAN_TRANSFER_ADMIN = (1 << 28) << 128; // token only; "not grantable, ignored on root"
ROLE_UPGRADE            = 1 << 124;  // root only
```

`contracts/src/resolver/libraries/PermissionedResolverLib.sol`:

```solidity
ROLE_SET_ADDRESS = 1 << 0;   ROLE_SET_TEXT = 1 << 4;   ROLE_SET_CONTENTHASH = 1 << 8;
ROLE_SET_DATA = 1 << 24;     ROLE_LINK = 1 << 28;      ROLE_UPGRADE = 1 << 124;
resource(string key) = uint256(keccak256(bytes(key)))   // key-scoped EAC resource
```

`EACBaseRolesLib.ALL_ROLES = 0x1111…1111` (bit 0 of every nybble). EAC checks pass if the account holds the role on the **specific resource OR on `ROOT_RESOURCE` (0)**.

### 2.2 Key functions (from the deployed ABIs at the tag)

```solidity
// ETHRegistrar
function makeCommitment(string label, address owner, bytes32 secret, address subregistry, address resolver, uint64 duration, bytes32 referrer) view returns (bytes32);
function commit(bytes32 commitment);
function register(string label, address owner, bytes32 secret, address subregistry, address resolver, uint64 duration, address paymentToken, bytes32 referrer);
function isAvailable(string label) view returns (bool);
function getRegisterPrice(string label, uint64 duration, address paymentToken) view returns (...);
function MIN_COMMITMENT_AGE() view returns (uint256);   // docs: 60s

// VerifiableFactory
function deployProxy(address implementation, uint256 salt, bytes initData) returns (address);

// UserRegistry (PermissionedRegistry + UUPS), proxy via VerifiableFactory
function initialize(Grant[] grants);                 // Grant = (address account, uint256 roleBitmap), granted on ROOT_RESOURCE
function register(string label, address owner, IRegistry registry, address resolver, uint256 roleBitmap, uint64 expiry) returns (uint256 tokenId);
function unregister(uint256 anyId);                  // ROLE_UNREGISTER (root or token); burns the token
function renew(uint256 anyId, uint64 newExpiry);
function setResolver(uint256 anyId, address resolver);
function grantRootRoles(uint256 roleBitmap, address account);
function grantRoles(uint256 anyId, uint256 roleBitmap, address account);
function getTokenId(uint256 anyId) view returns (uint256);   // token IDs change on re-register: key things by labelhash (anyId = uint256(keccak256(label)))
function getState(uint256 anyId) view returns (State);
function ownerOf(uint256 tokenId) view returns (address);

// PermissionedResolver, proxy via VerifiableFactory. Setters take the DNS-ENCODED NAME, not a namehash.
function initialize(Grant[] grants, bytes[] calls);
function setText(bytes name, string key, string value);             // ROLE_SET_TEXT on resource(key) or root
function setAddress(bytes name, uint256 coinType, bytes addressBytes); // coinType 60 = ETH; ROLE_SET_ADDRESS on resource(coinType) or root
function setData(bytes name, string key, bytes value);              // ENSIP-24
function linkToNode(bytes sourceName, bytes32 targetNode);          // ROLE_LINK on root (record aliasing)
function linkToRecord(bytes sourceName, uint256 recordId);
function grantSetterRoles(bytes setter, address account) returns (bool);  // e.g. setter = abi.encodeCall(setText, (hex"00", "rentouts.leasesCompleted", "")) grants ROLE_SET_TEXT for that key only
// NOTE: PermissionedResolver.grantRoles(resource,…) is overridden to always revert: use grantSetterRoles / grantRootRoles.
```

⚠️ The ENS **app-developer tutorial** shows `setText(bytes32 node, …)` / `setAddr(bytes32, address)`. **That is wrong for the 09-15 deployment.** The deployed ABI only has the `bytes name` forms above. DNS-encode with viem: `toHex(packetToBytes(normalize('alice.rentouts.eth')))`. In Solidity, build it by hand: `abi.encodePacked(uint8(len(label)), label, hex"08", "rentouts", hex"03", "eth", hex"00")`, or use contracts-v2's `NameCoder`.

---

## 3. Target architecture

```
                 Ethereum Sepolia (ENSv2)                                  Base Sepolia
 ┌──────────────────────────────────────────────────────────┐        ┌───────────────────────┐
 │ ETHRegistry: rentouts.eth ──subregistry──► UserRegistry   │        │ RentEscrow            │
 │                        └──resolver──────► PermissionedRes │        │  LeaseCreated/Funded  │
 │                                                            │        │  MonthClaimed         │
 │ UserRegistry (proxy)                                       │        │  LeaseClosed          │
 │   root roles: RentoutsSubnames = REGISTRAR|UNREGISTER|RENEW│        │  DisputeResolved      │
 │   alice (token) roles: none → soulbound, can't set resolver│        └──────────┬────────────┘
 │                                                            │                   │ events (viem getLogs,
 │ PermissionedResolver (proxy, one for all subnames)         │                   │  or MultiBaas webhooks)
 │   root: deployer (admin), RentoutsSubnames (SET_ADDRESS,   │                   ▼
 │         SET_TEXT for profile keys via contract checks)     │        ┌───────────────────────┐
 │   key-scoped ROLE_SET_TEXT: issuer on rentouts.* keys ◄────┼────────┤ issuer / relayer      │
 │                                                            │ setText│ (ens/scripts/sync-    │
 │ RentoutsSubnames (ours)                                    │        │  credentials.ts)      │
 │   register(label, owner) · revoke(label) · setCredential   │        └───────────────────────┘
 │   setProfileText(label,key,val) [owner-only, allowlisted]  │
 └──────────────────────────────────────────────────────────┘
 Frontend: viem getEnsAddress / getEnsText / getEnsName on `sepolia` → UR 0xeEeE…EeEe (no hard-coded addresses needed for reads)
```

### 3.1 Records schema (proposal; agree with the frontend)

| Key | Writer | Example | Meaning |
|---|---|---|---|
| `addr` (coin 60) | RentoutsSubnames on register | `0xAlice` | forward resolution |
| `rentouts.credential` | RentoutsSubnames on register | `tenant/v1` | marks a RentOuts rental credential |
| `rentouts.status` | issuer | `active` / `revoked` | revocation visible in resolution (in addition to unregister) |
| `rentouts.leasesCompleted` | issuer | `3` | from `LeaseClosed` events |
| `rentouts.onTimeRate` | issuer | `100` (percent) | from `MonthClaimed` timeliness |
| `rentouts.disputes` | issuer | `0` | from `DisputeOpened`/`DisputeResolved` |
| `rentouts.rating` | issuer | `4.8` | spec example |
| `rentouts.escrow` | issuer | `eip155:84532:0xEscrow` | CAIP-10 pointer to the escrow on Base Sepolia |
| `rentouts.verified` | issuer | `world-id` | set after the World ID gate passes (World × ENS overlap) |
| `avatar`, `description`, `url`, `com.twitter` | owner via `setProfileText` | … | user-editable profile, allowlisted keys only |

(Optional, ENSIP-24) Mirror the credential as one `setData("rentouts.credential.v1", abi.encode(...))` blob for contracts to read cheaply. This is a stretch goal.

### 3.2 `RentoutsSubnames.sol` sketch (design, not final code)

```solidity
// Solidity ^0.8.24 (ENS impls are 0.8.25; we only need their interfaces)
contract RentoutsSubnames is AccessControl /* or Ownable + issuer mapping */ {
    IUserRegistry public immutable registry;          // our UserRegistry proxy for rentouts.eth
    IPermissionedResolver public immutable resolver;  // our shared PermissionedResolver proxy
    bytes32 public constant ISSUER = keccak256("ISSUER");
    uint64 public constant TERM = 365 days;           // (verify) subname expiry must be > now; consider capping at parent expiry

    mapping(address => bytes32) public labelOf;       // one name per address (sybil-light; World gate is on Base)
    mapping(bytes32 => bool) public profileKeyAllowed; // avatar, description, url, com.twitter

    event Claimed(string label, address indexed owner, uint256 tokenId);
    event Revoked(string label, address indexed owner, string reason);

    function register(string calldata label, address owner) external {
        // allow self-serve: require(msg.sender == owner || hasRole(ISSUER, msg.sender))
        // validate label: 3..32 chars, [a-z0-9-], no leading/trailing '-'
        // require(labelOf[owner] == 0)
        uint256 tokenId = registry.register(label, owner, IRegistry(address(0)), address(resolver), /*roleBitmap*/ 0, uint64(block.timestamp) + TERM);
        //   roleBitmap 0 means no ROLE_CAN_TRANSFER_ADMIN (soulbound) and no SET_RESOLVER (can't detach credential)
        bytes memory dns = _dns(label);               // \x05alice\x08rentouts\x03eth\x00
        resolver.setAddress(dns, 60, abi.encodePacked(owner));
        resolver.setText(dns, "rentouts.credential", "tenant/v1");
        resolver.setText(dns, "rentouts.status", "active");
        emit Claimed(label, owner, tokenId);
    }

    function setCredential(string calldata label, string calldata key, string calldata val) external onlyRole(ISSUER) {
        // require(startsWith(key, "rentouts.")); name must be registered
        resolver.setText(_dns(label), key, val);
        // ALTERNATIVE (better EAC story): the issuer EOA calls resolver.setText directly with its key-scoped role,
        // and this function exists only for spec compatibility.
    }

    function setProfileText(string calldata label, string calldata key, string calldata val) external {
        // require(registry.ownerOf(registry.getTokenId(uint256(keccak256(bytes(label))))) == msg.sender)
        // require(profileKeyAllowed[keccak256(bytes(key))])
        resolver.setText(_dns(label), key, val);
    }

    function revoke(string calldata label) external onlyRole(ISSUER) {
        // resolver.setText(dns, "rentouts.status", "revoked"); resolver.setAddress(dns, 60, "");
        // registry.unregister(uint256(keccak256(bytes(label))));   // burns; name stops resolving via registry
        // delete labelOf[owner]; emit Revoked(...)
    }
}
```

**Roles to wire in `DeployEns.s.sol`:**

1. **UserRegistry.** Initialize with `Grant(deployer, ALL_ROLES)` and `Grant(rentoutsSubnames, ROLE_REGISTRAR | ROLE_UNREGISTER | ROLE_RENEW)`. The subnames contract address isn't known before it's deployed, so either predict it, or `grantRootRoles` after deploy.
2. **PermissionedResolver.** Initialize with `Grant(deployer, ALL_ROLES)`. Then:
   - `grantRootRoles(ROLE_SET_ADDRESS | ROLE_SET_TEXT, rentoutsSubnames)`. Root `SET_TEXT` lets the contract enforce profile-key and issuer rules itself, which is simplest.
   - **For the EAC showcase:** also grant the issuer EOA key-scoped roles: `grantSetterRoles(abi.encodeCall(IPermissionedResolver.setText, (hex"00", "rentouts.leasesCompleted", "")), issuer)`, and the same for each `rentouts.*` key.
   - In the demo, show that `issuer` can write `rentouts.onTimeRate` but reverts on `avatar`. That's the "only the issuer can write credentials" proof, enforced by ENS itself.
3. **`rentouts.eth` in ETHRegistry.** Pass `subregistry = userRegistryProxy` and `resolver = resolverProxy` **directly in `register`** (both are commitment fields), so no follow-up `setSubregistry` / `setResolver` is needed. If it was already registered: `ETHRegistry.setSubregistry(labelId, userRegistry)` and `setResolver(labelId, resolver)`. The registrant holds `ROLE_SET_SUBREGISTRY` and `ROLE_SET_RESOLVER` from registration.
4. **The parent name's own records.** Set `rentouts.eth` → `addr` (the deployer or the app treasury), `description`, `url` (`https://rentouts.co`), and `avatar`.

**Proxy salts (from the docs, verify):**
- Resolver: `keccak256(abi.encode(keccak256("OwnedResolver"), owner, version))`.
- Registry: `keccak256(abi.encode(keccak256("UserRegistry"), namehash, version))`.

The salt only affects the address. Any unique `uint256` works; use the documented ones so ENS tooling recognizes them.

### 3.3 Why these choices (for the ENS writeup)

- **Real ENSv2 primitives, not cosmetic:**
  - The subname registry is a real `UserRegistry` proxy.
  - Soulbound comes from **ENS's own transfer gate** (`ROLE_CAN_TRANSFER_ADMIN` withheld), not a custom NFT.
  - Revocation is ENS `unregister`.
  - Credential integrity comes from **EAC key-scoped resolver roles**: tenants can't forge their `onTimeRate`.
- **Resolution works everywhere.** Any ENSv2-aware client (viem, the ENS app at app.ens.dev, the explorer at explorer.ens.dev) shows `alice.rentouts.eth` and its credentials with no RentOuts code.
- **Composability for landlords:** a landlord or another dapp can call `getEnsText('alice.rentouts.eth', 'rentouts.onTimeRate')` before accepting a tenant.
- **Revocable because the root keeps roles.** Names under `rentouts.eth` are *not emancipated*: the registry root keeps `ROLE_UNREGISTER`, which is exactly what makes the credential revocable. Say this explicitly: it's a deliberate trust-model choice, and judges will notice emancipation.

---

## 4. Step-by-step: from zero to `alice.rentouts.eth` resolving

Run on the laptop (the VPN works there). Env: `SEPOLIA_RPC_URL`, deployer in the Foundry keystore (`cast wallet import rentouts-deployer --interactive`). **Never** put a private key in a file or in chat.

0. **Sanity checks (5 min):**
   ```bash
   cast chain-id --rpc-url $SEPOLIA_RPC_URL                                   # 11155111
   R=0xAbe76F6C8DFcEd81AA5A2bB8034202A7136b94ca
   cast call $R "isAvailable(string)(bool)" rentouts --rpc-url $SEPOLIA_RPC_URL
   cast call $R "MIN_COMMITMENT_AGE()(uint256)" --rpc-url $SEPOLIA_RPC_URL
   cast call $R "getRegisterPrice(string,uint64,address)" rentouts 31536000 0x16f95D91DBa7dA3Aca778Ec053dF0FF6C6A8aA8e --rpc-url $SEPOLIA_RPC_URL
   cast code 0x9e726Eb570beb6BCEb495AB8cdA7df517d4e841C --rpc-url $SEPOLIA_RPC_URL | head -c 20   # factory exists
   ```
   If `rentouts` is taken, use `rentouts-tokyo` or `rentoutsapp`. A 5+ char label costs about $8/yr in test stablecoin. Put the parent label in env (`ENS_PARENT_LABEL`) and **never hard-code it**.
1. **Get fee tokens:** `cast send 0x16f9…aA8e "mint(address,uint256)" $ME 100000000 --account rentouts-deployer --rpc-url …` (100 mock USDC). Spend it immediately: anyone can `nuke` it.
2. **Deploy the resolver proxy:** `VerifiableFactory.deployProxy(PermissionedResolverImpl, salt, abi.encodeCall(initialize, ([Grant(me, ALL_ROLES)], [])))`. Read the proxy address from the event or return value.
3. **Deploy the UserRegistry proxy:** `deployProxy(UserRegistryImpl, salt, abi.encodeCall(initialize, ([Grant(me, ALL_ROLES)])))`.
4. **Register the parent:** `approve(ETHRegistrar, price)`, then `commit(makeCommitment(label, me, secret, userRegistry, resolver, 31536000, 0x0))`. Sleep at least `MIN_COMMITMENT_AGE` + 5 s, then `register(label, me, secret, userRegistry, resolver, 31536000, mockUSDC, 0x0)`.
5. **Smoke-test the parent:** `resolver.setText(dns("rentouts.eth"), "url", "https://rentouts.co")`, then read it back through the UR with viem `getEnsText({ name: 'rentouts.eth', key: 'url' })`. **This is milestone 1.**
6. **Deploy `RentoutsSubnames`** and grant it roles (§3.2). Call `register("alice", aliceAddr)`, then check `getEnsAddress('alice.rentouts.eth')` and `getEnsText(…, 'rentouts.credential')`. **This is milestone 2 = the gate.**
7. **Issuer:** grant key-scoped roles, then run `sync-credentials.ts` once against the Base escrow (or with mocked numbers until the escrow is deployed). Show the credentials updating.
8. **Revoke** a test name. Show it stops resolving `addr`, or shows `rentouts.status=revoked`.
9. Write the `sepolia` block of `deployments.json` (see §7).

Steps 2–5 should be **one idempotent script**, `ens/script/DeployEns.s.sol` (or `ens/scripts/register-parent.ts` with viem). A Sepolia reset or a taken label then costs minutes. Foundry scripts can't sleep between commit and register across one broadcast, so either:
- split into two script runs (`--sig "commit()"` then `--sig "register()"`, with a `sleep 65` between them in a shell wrapper); or
- do the parent registration in TypeScript/viem, which is easier: `await new Promise(r => setTimeout(r, 65_000))`.

---

## 5. Frontend: `app/src/lib/ens.ts` (for the shared wizard)

- Use **plain viem** (≥ 2.35; latest is 2.56.9) with `sepolia` from `viem/chains`. Reads go through the UR automatically, with no ENS addresses in the app.
  ```ts
  const client = createPublicClient({ chain: sepolia, transport: http(import.meta.env.VITE_CONTRACT_RPC_URL_SEPOLIA) })
  await client.getEnsAddress({ name: normalize('alice.rentouts.eth') })
  await client.getEnsText({ name: normalize('alice.rentouts.eth'), key: 'rentouts.onTimeRate' })
  await client.getEnsName({ address })   // primary name, only if the user set one (stretch)
  ```
- **Avoid `@ensdomains/ensjs` npm:** `latest` is 4.3.1, and the v5 preview has **stale Sepolia v2 addresses**. ensjs `main` targets 09-15 but isn't published, and its registrar actions look up a contract key `ethRegistrar` that the Sepolia config names `ensEthRegistrar`. Plain viem + ABIs is less risky.
- **ClaimName step:**
  1. Input a label and check availability: read `UserRegistry.getState(labelId)`, or just try `getEnsAddress` and treat a null result as free.
  2. Switch the wallet to Sepolia and call `RentoutsSubnames.register(label, account)`.
  3. Poll `getEnsAddress` until it resolves, then show the badge.
- **Profile credential card:** read the `rentouts.*` keys via `getEnsText` and show them next to the name. Link to `https://app.ens.dev/<name>` or `https://explorer.ens.dev/...` (verify URL format) as "verify this on ENS".
- **"No hard-coded values" (a judging criterion in past ENSv2 prizes):** display names come from resolution, and addresses come from `deployments.json`.

---

## 6. Testing strategy

- **Prefer Foundry fork tests against live Sepolia**: `forge test --fork-url $SEPOLIA_RPC_URL`. They use the real 09-15 implementations and the real factory, which is the highest confidence for the least effort. Deploy fresh proxies inside the test, so no dependency on our live `rentouts.eth`. You can even register a random parent label in-fork with `vm.warp` past the commitment age.
- **Test cases:**
  - register → `addr` + credential text resolve (via resolver `text()` / `addr()` directly, or via the UR on the fork);
  - a second register for the same owner reverts; a duplicate label reverts;
  - `safeTransferFrom` of the subname token reverts `TransferDisallowed` (**soulbound proof**);
  - the owner can't `setResolver` on their subname (no role);
  - the issuer can `setText` on a `rentouts.*` key; the issuer **cannot** set `avatar`; a random account can't set `rentouts.*`; the owner can `setProfileText` for allowlisted keys only;
  - `revoke` burns the token, and `ownerOf`, `addr` and `status` reflect it;
  - label validation (uppercase, too short, bad chars).
- (verify) Fork-test gas and `LabelStore` side effects: `register` calls `LABEL_STORE.setLabel`, which should just work on a fork.
- Keep the escrow's invariant tests (Dean / shared) separate; the ENS package has its own `foundry.toml` under `ens/`.

---

## 7. Integration contracts with teammates

- **`deployments.json`** (spec §2): Bektur owns the `sepolia` block:
  ```json
  { "sepolia": {
      "ensParentName": "rentouts.eth",
      "userRegistry": "0x…", "permissionedResolver": "0x…", "rentoutsSubnames": "0x…",
      "issuer": "0x…",
      "ensDeployment": "sepolia-deployment-2026-09-15"
  } }
  ```
  `baseSepolia` (escrow, HumanRegistry, LeaseShare1155, MockUSDC) belongs to the escrow/RWA owners.
- **Escrow events the relayer needs**, from the spec (§3.1), on Base Sepolia: `LeaseCreated(id, tenant, landlord, deposit, rent, term)`, `MonthClaimed(id, month, amount)`, `LeaseClosed(id, toTenant, toLandlord)`, `DisputeOpened(id, by)`, `DisputeResolved(id, tenantBps)`. **Ask the escrow owner to index `tenant`/`landlord`** (`indexed`) so the relayer can filter per person cheaply. Right now the spec'd events don't index anything.
- **Mapping tenant address → ENS label:** `RentoutsSubnames.labelOf(address)` on Sepolia. The relayer reads it and writes the credential texts.
- **World × ENS overlap (optional but strong):**
  - Once `HumanRegistry.isVerified(tenant)` is true on Base, the relayer writes `rentouts.verified=world-id` on the tenant's name. Or `register` could require an issuer-signed voucher proving World verification, so "only verified humans get a rentouts.eth name".
  - Keep it off by default and enable it only if the World gate is done.
- **Curvegrid overlap (Dean's call):** MultiBaas can index the Base escrow events and fire webhooks, and the relayer could consume those instead of `getLogs`. Nice for Curvegrid's writeup; not required for ENS.

---

## 8. Time plan (JST). Deadline Sun 09:00. ENS gate Sat 03:00.

| When | Do | Done when |
|---|---|---|
| Fri 22:00–23:30 | Foundry project in `ens/`, `forge install` contracts-v2 at the tag, sanity `cast` calls (§4 step 0), mint fee USDC, **register the parent** via script | `rentouts.eth` (or the fallback label) owned, resolver + UserRegistry proxies set |
| Fri 23:30–01:30 | `RentoutsSubnames.sol` + fork tests (§6) | tests green on the fork |
| Sat 01:30–03:00 | Deploy + wire roles, register `alice`, resolve via viem | **GATE: `alice.rentouts.eth` resolves `addr` + `rentouts.credential` through the UR** |
| Sat 03:00–08:00 | Issuer key-scoped roles, `revoke`, `setProfileText`, `sync-credentials.ts` (mock data first) | the credential updates via the issuer; revoke works |
| Sat 08:00–14:00 | `app/src/lib/ens.ts`, help build the ClaimName step + profile card | the name mints and shows in the wizard |
| Sat 14:00–20:00 | Wire the relayer to the real Base escrow events; World overlap (optional); primary-name stretch | end-to-end: close a lease → credential changes |
| Sat 20:00–Sun 02:00 | ENS section of README + FEEDBACK.md; redeploy/freeze; rehearse | writeup done |
| Sun 02:00–06:00 | Record the demo segment; buffer | — |
| **Sun ≤ 08:00** | Submit, with an hour of buffer before 09:00 | — |

**If the gate fails:**
- Try wildcard records on the parent's resolver instead of per-subname registration (§10.1).
- If v2 registration itself is broken, ask ENS mentors immediately. Last resort per the spec: hot-swap Intercepta ($500) as the third prize.

Commit every 45–60 min (ETHGlobal git-history rule). Small commits with real messages.

---

## 9. Pitfalls (each of these cost someone time already)

1. **Stale addresses everywhere.** ensjs npm v5 preview, `jefflau/enspack`, blog posts and earlier tags (05-28, 06-29, 07-31) are all wrong. Use only the tag `sepolia-deployment-2026-09-15` or docs.ens.domains/learn/deployments.
2. **Sepolia reset risk.** If ENS redeploys mid-hackathon, everything registered is gone. Scripts must be re-runnable; watch the contracts-v2 tags (`git ls-remote --tags https://github.com/ensdomains/contracts-v2`).
3. **`setText(bytes32 …)` in the tutorial is wrong.** Use `setText(bytes dnsName, …)`.
4. **Resolver roles are per key, not per name.** Don't hand users raw `ROLE_SET_TEXT`: they could write any name's records.
5. **`PermissionedResolver.grantRoles` always reverts.** Use `grantRootRoles` or `grantSetterRoles`.
6. **ENS MockUSDC has public `nuke()`.** Use it only for ENS fees, never in the escrow. The escrow spec uses its own MockUSDC on Base; that's fine.
7. **Token IDs change** when a name is re-registered or its roles change (`tokenVersionId` / `eacVersionId`). Key storage by `labelId = uint256(keccak256(label))` ("anyId"). Registry functions accept any form.
8. **Commit–reveal:** register at least 60 s after commit and within the max age; the commitment includes subregistry and resolver.
9. **The ENS app (app.ens.dev)** may or may not support new v2 registrations right now (unverified). Don't depend on it; script the registration.
10. **Primary names** still go through the v1-era ReverseRegistrar at launch. The UR forward-verifies (reverts `ReverseAddressMismatch` on mismatch). This is stretch only.

---

## 10. Open questions / unverified (check on-chain or with ENS mentors)

1. **Wildcard shortcut:** if records are written on the parent's PermissionedResolver for `alice.rentouts.eth` **without** registering the subname, does the v2 UR resolve them via closest-ancestor resolver lookup? The docs and code suggest yes. It's cheaper, but you lose soulbound/revoke semantics. Useful only as a fallback. **Test it on a fork.**
2. Is Circle Sepolia USDC still `isPaymentToken` on the price oracle? Cheap check: `cast call 0x9b0b…72bb "isPaymentToken(address)(bool)" 0x1c7D…7238`.
3. What exactly does the **Tokyo ENS prize** say? ethglobal.com was blocked from the cloud VM. Search summaries say ENSv2 on Sepolia, with registry hierarchy/subname registries, EAC roles, Permissioned Resolvers, wildcard resolution and aliasing called out, plus "integrate ENSv2 into an existing project" and "agents as namespaces" as a bonus. Past ENSv2 prizes required: ENSv2 on Sepolia, "make it clear how ENSv2 improves the project (not cosmetic)", and a functional demo **without hard-coded values**. Read https://ethglobal.com/events/tokyo2026/prizes in a browser and paste the ENS section into `docs/ens/PRIZE.md`.
4. Does the subname `expiry` need to be ≤ the parent's expiry? `_register` only checks "not in the past". Cap at the parent's expiry anyway for sanity.
5. ~~Grant struct order~~: confirmed `struct Grant { address account; uint256 roleBitmap; }` (`contracts/src/access-control/interfaces/IEACGrantInitializable.sol`).
6. Does `verifyContract` on VerifiableFactory matter for the ENS app showing our registry as "verified"? Nice-to-have.
7. Is the v1 freeze confirmed on-chain? `BaseRegistrar 0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85` `.controllers(0xfb3cE5D01e0f33f41DbB39035dB9745962F1f968)` should be `false`.

**Ask ENS mentors on-site:**
- Is another Sepolia redeploy planned before Sunday?
- What's the recommended pattern for issuer-written credentials (key-scoped `grantSetterRoles` vs `setData`)?
- Does app.ens.dev display UserRegistry subnames and custom text keys?

---

## 11. Compliance and hygiene

- **Continuity Track:** all code is written during the event. Don't copy `Lease.sol` or other pre-event code wholesale. Record AI assistance in `AI_USAGE.md` (this doc and the research were produced with Claude Code). List pre-existing RentOuts work in `PRIOR_WORK.md`.
- **Verify contracts** on Sepolia Etherscan/Blockscout (the Basescan V1 API is dead; for Base use Blockscout).
- **No private keys** in repo, env files committed, or chat. Use the Foundry keystore. Keep `.env` in `.gitignore`.
- **Open-source check** before submitting: the repo is public, MIT; README has run instructions for `ens/`.

---

## 12. Suggested first prompt for the local Claude session

> Read `docs/ens/HANDOFF.md` and `docs/ens/research/ensv2-docs-research.md` on branch `ens-integration`. I'm Bektur, owner of the ENS track. My Foundry keystore account is `rentouts-deployer` and `SEPOLIA_RPC_URL` is set. Start with §4 step 0 (sanity `cast` calls) and report results. Then scaffold `ens/` as a Foundry project with contracts-v2 pinned at tag `sepolia-deployment-2026-09-15`, and write the parent-registration script (viem TS, idempotent, label from env). Don't broadcast anything without showing me the command first. Commit after each milestone.
