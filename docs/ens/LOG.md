# ENS track log (ETHGlobal Tokyo 2026)

Running, timestamped log of the ENS track (owner: Bektur), updated as we go. Times are JST.
**How-to** lives in [`ens/README.md`](../../ens/README.md). **Design brief** is [`HANDOFF.md`](./HANDOFF.md). Where this log and the brief disagree, this log is the current truth.

**Deadline:** Sun 2026-09-27 09:00 JST. **ENS go/no-go gate:** Sat 03:00 — `alice.rentouts.eth` resolves `addr` + `rentouts.credential` through the Universal Resolver.

---

## Current state (keep this block up to date)

| | |
|---|---|
| Chain | Ethereum Sepolia (11155111), ENSv2 beta tag `sepolia-deployment-2026-09-15` |
| Parent | **`rentouts.eth`** — registered, expires 2027-09-25, owner = deployer |
| `PermissionedResolver` (proxy) | [`0xBB8A105f48Ac836F549eC0B6A1a45BB7BA0961E5`](https://sepolia.etherscan.io/address/0xBB8A105f48Ac836F549eC0B6A1a45BB7BA0961E5) |
| `UserRegistry` (proxy) | [`0xD2D122000D4725a863376EcAe4220BC20590f382`](https://sepolia.etherscan.io/address/0xD2D122000D4725a863376EcAe4220BC20590f382) |
| `RentoutsSubnames` | [`0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60`](https://eth-sepolia.blockscout.com/address/0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60) — source verified (Sourcify `exact_match`, Blockscout) |
| Deployer / admin (keystore `rentouts-deployer`) | `0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE` |
| Issuer (keystore `rentouts-issuer`) | `0xF6048B190D178Fb6F0870c65CD2F7E06381713C4` — key-scoped `SET_TEXT` on the six `rentouts.*` keys (target: only `onTimeRate`, `rating`, `verified`; the three escrow-derived grants are revoked by re-running `subnames`, see 23:05), **no** root resolver roles |
| Demo holder (keystore `rentouts-alice`) | `0x484811c8c967809bE644A89d677933c29fb9e936` → **`alice.rentouts.eth`** ✅ |
| Parent records | `addr` = `0x7ed696c879a1a7FD2eD3b49d9982E634a8647eb1` (RentOuts' published address), `url` = `https://rentouts.co`, `email` = `partners@rentouts.co`, `com.twitter` = `RentOuts`, `description` |
| Machine-readable | [`ens/deployments/sepolia.json`](../../ens/deployments/sepolia.json) |
| Gate | ✅ **passed Fri 22:24** (`alice.rentouts.eth` resolves `addr` + `rentouts.credential`) |
| Next | `CredentialSync` (on-chain, permissionless), `app/`, ENS writeup — see 22:40 entry |

---

## Fri 2026-09-25

**21:29 — Local session takes over from the cloud session.** The cloud VM had no Sepolia RPC and couldn't push (GitHub 403), so its handoff arrived as a `.patch`.
- Applied it on `ens-integration` with `git am` and pushed (`f9b6036`): `docs/ens/HANDOFF.md` + `docs/ens/research/ensv2-docs-research.md`.

**21:31 — Tooling.** Installed Foundry 1.8.3 via the official `foundryup`; added `~/.foundry/bin` to `~/.zshrc` (the installer hadn't).

**21:35 — Sanity checks on live Sepolia (read-only), HANDOFF §4 step 0.** All passed:
- `rentouts` available; price 8.000021 ENS-MockUSDC for 1 year; `MIN_COMMITMENT_AGE` 60 s, max 86 400 s.
- ENS MockUSDC and Circle Sepolia USDC both accepted as payment tokens.
- ENS v1 registration is off (`BaseRegistrar.controllers(v1 controller) == false`) → the brief's v1 fallback is dead; v2 is the only path.
- All seven ENSv2 contracts have code; no ENS redeploy tag after 2026-09-15.

**21:40 — `ens/` package + `RentoutsSubnames.sol` + fork tests (`11feb72`).**
- Vendored minimal ENSv2 interfaces from `contracts-v2` source at the tag instead of compiling their tree.
- Design as in HANDOFF §3, with two changes from reading the source: state is written **before** the ENS mint (the ERC-1155 mint calls `onERC1155Received`, a re-entry point), and revoked labels are **retired** (the shared resolver keeps old records).
- Finding: the stock Foundry test address `makeAddr("alice")` = `0x3288…ac6` has **EIP-7702 delegation code** on Sepolia (`0xef0100…`) that doesn't accept ERC-1155, so ENS refused to mint to it. Tests now use unique addresses. **Demo risk:** a holder wallet with such a delegation can't receive a subname.

**21:45 — Phased deploy script + wrapper (`d0ff5fa`).** `script/DeployEns.s.sol` (`status | infra | commit | register | subnames | profile | claim`) and `scripts/ens.sh` (dry-run by default, `BROADCAST=true` signs with the Foundry keystore; no private keys in files).
- Rehearsed end-to-end on an anvil fork of Sepolia. Caught a bug: waiting 65 s between commit and register can fail because the registrar checks age against the **latest block** (~12 s granularity) → the wrapper now waits 90 s.

**22:02 — Multi-agent review, fixes applied (`81adcbb`).** 17 findings survived adversarial verification (most downgraded to low). Fixed:
- **Revoke wipes everything:** before, a revoked name still resolved `tenant/v1`, issuer scores and profile via the shared parent resolver. Now `linkToRecord(name, 0)` detaches the record and a fresh one holds only `rentouts.status=revoked` (needs `ROLE_LINK`).
- **Issuer must be a separate account:** with issuer = deployer (root resolver roles) the "issuer can't write `avatar`" demo would silently pass. The deploy now refuses it.
- **Soulbound test tested the wrong thing:** `safeTransferFrom` fails first with `TransferUnsafeUntilRegistryIsEmancipated`; the real gate is `unsafeTransfer` → `TransferDisallowed`. Test fixed + a positive control.
- Subnames never expire; labels are single-use for the registry's lifetime (also across a contract redeploy); ENSIP-15 `--` check; one ENSIP-19 default-EVM address record (resolves on Base too); `removeIssuer` phase.
- **18/18 fork tests green.** Re-rehearsed on an anvil fork including the EAC demo (issuer → `rentouts.onTimeRate` ok, `avatar` reverted by ENS) and revoke (addr → `0x0`, stats wiped).

**22:05 — Wallets.** Bektur created fresh Foundry keystores `rentouts-deployer` and `rentouts-issuer` (both clean EOAs, no code). `ens/.env` written (gitignored); dry-run of `status` + `infra` OK. Fixed an unquoted value in `.env.example` (`4155343`).

**22:11 — Funded.** Deployer 0.02 ETH, issuer 0.008 ETH. Gas ~1 gwei.

**22:15–22:19 — Deployed to Sepolia (Bektur ran `parent`, `subnames`, `profile`).** 21 transactions, all `status 0x1`, total **0.004483 ETH**. Deployment committed (`2568883`).

| Phase | Tx | Hash |
|---|---|---|
| infra | `deployProxy` (PermissionedResolver) | [`0x076c6eaf…b40c`](https://sepolia.etherscan.io/tx/0x076c6eaf54d21bc71706f99814bc351e64632014c44ce004ee3dd5285096b40c) |
| infra | `deployProxy` (UserRegistry) | [`0x5e6b7490…8135`](https://sepolia.etherscan.io/tx/0x5e6b749024c1608efa5bcf8b3014fc762ce5c26ec5db75a0253961381d198135) |
| commit | `commit` | [`0xab3a2ce8…45ee`](https://sepolia.etherscan.io/tx/0xab3a2ce89b6e9f01546462b2c27fb3ba64e71828b1e26f74f7c6138d83f845ee) |
| register | `mint` / `approve` (ENS MockUSDC fee) | [`0x6b4ac086…6a28`](https://sepolia.etherscan.io/tx/0x6b4ac0860c56321fe67e929cb21840a701748f9af71d8bbfd72fc52d252a6a28), [`0xb56bbb51…b8c8`](https://sepolia.etherscan.io/tx/0xb56bbb51ed4ad42b034a8d69db69abb1524bb5cae16d39ad7c502c5394a8b8c8) |
| register | `register` → **rentouts.eth** | [`0x7100160a…ca7b`](https://sepolia.etherscan.io/tx/0x7100160abf684418f7c00b60e3a839662c6de1cae1db2bf57cd59210f125ca7b) |
| subnames | deploy `RentoutsSubnames` | [`0xf7440fd5…6bba`](https://sepolia.etherscan.io/tx/0xf7440fd589ab000785dc898b8b8a7958668db779bf65241bc63ed76e56d96bba) |
| subnames | 2× `grantRootRoles`, `setIssuer`, 6× `grantSetterRoles` | see `ens/broadcast/DeployEns.s.sol/11155111/subnames-latest.json` |
| profile | `setAddress` + 4× `setText` | see `profile-latest.json` |

**22:20 — Verified independently on-chain.**
- `cast resolve-name rentouts.eth` → `0x7ed696c879a1a7FD2eD3b49d9982E634a8647eb1`; `url`, `email`, `com.twitter`, `description` resolve through the Universal Resolver.
- Roles: `RentoutsSubnames` holds registry `REGISTRAR|UNREGISTER|RENEW` and resolver `SET_ADDRESS|SET_TEXT|LINK`; issuer has `SET_TEXT` on `rentouts.onTimeRate` = **true**, on `avatar` = **false**, root `SET_TEXT` = **false**.
- `RentoutsSubnames` source verified: Sourcify `exact_match`, Blockscout.

**22:21 — Demo holder.** Bektur created keystore `rentouts-alice` → `0x484811c8c967809bE644A89d677933c29fb9e936` (clean EOA). Set as `ENS_DEMO_HOLDER`; `claim` dry-run OK. Holder needs no ETH to receive (the deployer mints for her); she only needs gas for `setProfileText`.

**22:23 — Claimed `alice.rentouts.eth`** (Bektur ran `claim`): `register("alice", 0x4848…e936)` [`0x882d63a5…7500`](https://sepolia.etherscan.io/tx/0x882d63a54d344760d5a10dd2455c25796ca3b930e7db50c96d9dea7b5f947500), gas 307 220, status 1.

**22:24 — ✅ GO/NO-GO GATE PASSED** (target was Sat 03:00). Verified on live Sepolia:
- `cast resolve-name alice.rentouts.eth` → `0x484811c8c967809bE644A89d677933c29fb9e936`
- Universal Resolver: `rentouts.credential` = `tenant/v1`, `rentouts.status` = `active`
- `addr(node, 0x80000000|84532)` (Base Sepolia) → same address, via the ENSIP-19 default record
- `labelOf`/`nameOf` correct; registry owner = alice; expiry = `2^64-1` (never)
- Soulbound on the real chain: `unsafeTransfer` from alice → `TransferDisallowed`

**22:40 — Team decisions (Bektur).**
- **Build everything**, but the public repo gets only what judges need; internal research/strategy/runbooks live in the private product repo.
- **One chain: everything on Ethereum Sepolia** (escrow + Dean's `LeaseShare1155` + ENS). ENSv2 only exists there, and one chain lets credentials be **derived on-chain** from escrow state by a permissionless `CredentialSync.sync(tenant)` instead of a trusted off-chain relayer. There's no Base prize, so Base added nothing for judging.
- **Escrow token: Circle's USDC on Sepolia** (`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`, 6 decimals; ETHGlobal and Circle faucets), so "USDC escrow" is literally true. Demo amounts are small. A mock token stays a deploy-time fallback.
- World gate stays on hold.
- The core escrow (`RentEscrow`) had no owner and is the demo's spine: built now on `feat/core-escrow`, branched from Dean's `feat/curvegrid-rwa` so it can mint `LeaseShare1155` shares.

**23:05 — Review fix: the issuer EOA no longer gets resolver roles on escrow-derived keys.** Review found (live `roles()` read) that the issuer EOA holds `SET_TEXT` on `rentouts.leasesCompleted`, `rentouts.disputes` and `rentouts.escrow`, and that every `subnames` run granted them again.
- `DeployEns.s.sol`: `ISSUER_KEYS` is now `onTimeRate`, `rating` and `verified` only. `subnames()` revokes any issuer-EOA role on the five `CredentialSync` keys, and `removeIssuer()` revokes all eight. Fork test `test/DeployEnsRoles.fork.t.sol` covers this; it fails against the old key list.
- Live dry-run of `subnames` on Sepolia simulates exactly 3 `revokeRoles` txs and nothing else. **Not broadcast yet.**
- The README no longer claims no RentOuts server can affect the derived values. Any `RentoutsSubnames` issuer can still `setCredential` them until it is removed; `sync` restores them.

---

## Open items

- [ ] Core escrow (`feat/core-escrow`): `resolveDispute` counts the tenant's dispute share as deposit returned before unreleased prepaid rent, which inflates `rentouts.depositReturnRate` (review repro: landlord kept the whole deposit, rate showed `29`). The ENS README documents the current rule. If core changes the attribution, drop that caveat from the records table.
- [ ] Broadcast the issuer role cleanup (Bektur, deployer keystore): `BROADCAST=true ./scripts/ens.sh subnames`. Then confirm that `roles(keccak256("rentouts.leasesCompleted"), issuer)` returns 0.

- [x] Claim `alice.rentouts.eth` → **gate** (22:24).
- [ ] `CredentialSync` (replaces the off-chain relayer): permissionless `sync(tenant)` reads `RentEscrow.tenantStats` and writes `rentouts.*` via `RentoutsSubnames` (made an issuer).
- [ ] `app/src/lib/ens.ts`: claim step (`simulateContract` for availability, `labelOf(account)` on connect, `normalize()`), profile card (show `rentouts.*` only when `status == active` and `addr` matches).
- [ ] ENS section of README + `FEEDBACK.md`; paste the exact Tokyo ENS prize text into `docs/ens/PRIZE.md`.
- [ ] Ask ENS mentors: another Sepolia redeploy before Sunday? Does app.ens.dev show UserRegistry subnames + custom keys?
- [ ] World gate: **on hold** (team decision 2026-09-25).
