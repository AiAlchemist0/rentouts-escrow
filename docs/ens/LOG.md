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
| `CredentialSync` | [`0xd0783EC7B0668652718f3977Ca92235fe6bF9c56`](https://eth-sepolia.blockscout.com/address/0xd0783EC7B0668652718f3977Ca92235fe6bF9c56) — live Sat 03:08, issuer on `RentoutsSubnames`, reads `RentEscrow`; source verified (Sourcify `exact_match`, Blockscout) |
| Escrow stack (`feat/ai-judge`) | `RentEscrow` [`0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18`](https://eth-sepolia.blockscout.com/address/0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18) (Circle USDC), `AIArbiter` `0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5`, `HumanGate` `0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd` → `WorldIdV4Gate` `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa` (alice verified), `LeaseShare1155` `0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09`; all source verified (see Sat 03:05 and 03:15) |
| Issuer (keystore `rentouts-issuer`) | `0xF6048B190D178Fb6F0870c65CD2F7E06381713C4` — key-scoped `SET_TEXT` on `rentouts.onTimeRate`, `rating`, `verified` only (the three escrow-derived grants were revoked Sat 03:09; `roles()` is 0 on all five derived keys), **no** root resolver roles |
| Demo holder (keystore `rentouts-alice`) | `0x484811c8c967809bE644A89d677933c29fb9e936` → **`alice.rentouts.eth`** ✅ |
| Parent records | `addr` = `0x7ed696c879a1a7FD2eD3b49d9982E634a8647eb1` (RentOuts' published address), `url` = `https://rentouts.co`, `email` = `partners@rentouts.co`, `com.twitter` = `RentOuts`, `description` |
| Machine-readable | [`ens/deployments/sepolia.json`](../../ens/deployments/sepolia.json) |
| Gate | ✅ **passed Fri 22:24** (`alice.rentouts.eth` resolves `addr` + `rentouts.credential`) |
| Next | first live `sync` (alice after a demo lease), `app/` ENS claim + profile card, ENS writeup, Etherscan verification (needs an API key) |

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
| subnames | 2× `grantRootRoles`, `setIssuer`, 6× `grantSetterRoles` | see `ens/broadcast/DeployEns.s.sol/11155111/run-1790342293969.json` (`subnames-latest.json` now holds the Sat 03:09 cleanup) |
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

## Sat 2026-09-26

**00:46 — `ens-integration` rebased onto `origin/main` (`a4ef88a`, Dean's `LeaseShare1155` + ARCHITECTURE).** Clean rebase, no conflicts; Dean's files are unchanged.
- `ens/src/interfaces/IRentEscrow.sol` is again a verbatim copy of the core interface, which now has `humanGate()` and `NotVerifiedHuman` (World ID seam). `CredentialSync` only reads `tenantStats`, so nothing else changed. `forge test` in `ens/`: 30/30 pass against live Sepolia.
- Root `README.md`: short "ENS identity" section pointing to `ens/README.md`. Root `.gitignore`: `!ens/broadcast/`, because Dean's `broadcast/` rule would otherwise hide new ENS broadcast receipts (dry-runs stay ignored).

**01:05 — Review of `ens/` (Codex + two Fable reviewers).** No critical or high findings, and the live `RentoutsSubnames` is byte-identical to the source. Team decisions (Bektur): **no redeploy.** "Revoke retires the label, not the wallet" is documented as a known limitation, because a ban is cosmetic without proof of personhood (the fix is World ID, one human, one name). "`transferAdmin` keeps the old admin as issuer" gets a runbook. The deploy-script and test findings are fixed below.

**02:05 — Review fixes in the deploy script, wrapper and tests.** `ens/src/` unchanged, nothing broadcast.
- **`credentialSync` survives a half-finished broadcast (Codex M1, M2).** Forge writes the state file before it sends anything. So the phase now records its contract as `pendingCredentialSync` and keeps every superseded one in `retiredCredentialSyncs`. Every run first revokes the retired ones, each on the `RentoutsSubnames` it writes through (before, it checked the new one), then deploys or reuses. After a successful broadcast `ens.sh` runs `finalizeCredentialSync` (no txs), which writes `credentialSync` / `escrow` only once the chain shows the contract deployed, an issuer, and every retired sync revoked. If a run stops half way, re-running it finishes the job. The phase also warns when the escrow changes: names keep the old stats until `sync`.
- **One state file per parent (Codex L3).** Every phase refuses a state file whose `ensParentName` isn't `ENS_PARENT_LABEL.eth`. It also refuses a `RentoutsSubnames` whose `parentName()`, registry or resolver differ.
- **`removeIssuer` sticks (Fable ops M).** The account goes into `removedIssuers` and out of `issuer`. `subnames` / `all` refuse to grant a removed `ENS_ISSUER` again unless `ENS_REINSTATE_ISSUER` names it.
- **Rehearsals can't overwrite live receipts (Fable L1).** With `RPC_OVERRIDE` / `UNLOCKED`, receipts go to `broadcast-local/` and state to `deployments/local.json` (seeded from `sepolia.json`, both gitignored). The wrapper refuses `ENS_STATE=deployments/sepolia.json`.
- **Tests: 42/42 fork tests.** `DeployEnsRoles` seeds the issuer with all five derived keys and checks the script's key lists against `CredentialSync`'s constants. The new `DeployEnsPhases.fork.t.sol` (11 tests) runs the phases end to end: credentialSync fresh / reuse (0 txs) / replace / interrupted / never landed / new `RentoutsSubnames` / old retired sync re-enabled, removeIssuer persistence, the `subnames` re-run and the state-file checks. Env and sender go through a harness, not `vm.setEnv`, which would race between parallel tests. Mutation-checked: each of these makes at least one test fail: dropping two derived keys, revoking on the wrong `RentoutsSubnames`, dropping the retired list, skipping the removed-issuer guard, keeping the removed issuer in state, skipping the state-parent check.
- **Rehearsed with `ens.sh` on an anvil fork of Sepolia** (impersonated deployer, stub escrows). credentialSync fresh, then reuse (no txs), then replace (old revoked, finalized). `subnames` sent exactly the 3 `revokeRoles` of the pending cleanup. `removeIssuer` worked, then `subnames` refused. Committed receipts and `sepolia.json` untouched. A live **dry run** of `subnames` still simulates exactly those 3 `revokeRoles`.
- **README:** new "Known limitations and operations" section. It covers revoke-not-ban, issuer key roles being resolver-global (apps check `status == active`, `addr` and `labelOf`), the admin handover runbook, the deployer's proxy upgrade roles (to a Safe later) and one state file per parent.

**03:05–03:09 — Escrow stack and `CredentialSync` live on Ethereum Sepolia (Bektur ran the deploys).** 11 txs, all `status 0x1`, about 0.0062 ETH in total (the ENS part: 5 txs, 0.00105 ETH). The escrow stack comes from `feat/ai-judge` (`DeployAIArbiter.s.sol`, then `DeployEscrow.s.sol`); its addresses are in that branch's `deployments.json` (`sepolia`, `sepoliaAIArbiter`).

| Contract | Address | Deploy tx | Wiring |
|---|---|---|---|
| `AIArbiter` | [`0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5`](https://eth-sepolia.blockscout.com/address/0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5) | [`0xc82a9176…977a`](https://sepolia.etherscan.io/tx/0xc82a9176171588129ef6244ab9f655b39319a661456d0daedbf7d7673b47977a) | agent `0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA`, human `0x798b01Cef62b889943Ce1D3C5011a755B297e486`, challenge window 120 s; `bindEscrow(RentEscrow)` sent by the human: [`0xe4771261…b875`](https://sepolia.etherscan.io/tx/0xe47712614a63eec77c960c9f27cd31ed34de7d2e7bc3a4b0098172195088b875) |
| `LeaseShare1155` | [`0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09`](https://eth-sepolia.blockscout.com/address/0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09) | [`0x05ce482f…f64b`](https://sepolia.etherscan.io/tx/0x05ce482f57de77b09f73efed346c889b0f6012c3a0b426f8bc76abf7e124f64b) | owner = deployer, deployer allowlisted, minter = `RentEscrow` (`setMinter` [`0xc0d8b854…9f84`](https://sepolia.etherscan.io/tx/0xc0d8b854aad94e8fd1cab7488c2e3f29390aa5af2d5127dd2236298534149f84)) |
| `HumanGate` | [`0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd`](https://eth-sepolia.blockscout.com/address/0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd) | [`0x2351a01f…c232`](https://sepolia.etherscan.io/tx/0x2351a01fdc504feeb7bd8026029c287765e16568aa8370431a498e089e89c232) | owner = deployer, verifier `0x0` = open (World gate on hold) |
| `RentEscrow` | [`0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18`](https://eth-sepolia.blockscout.com/address/0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18) | [`0xf8b1d3c0…8f00`](https://sepolia.etherscan.io/tx/0xf8b1d3c05a146a85205a215e96e3c3c1eb20015db12323cdc7013eae795c8f00) | token = Circle USDC `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`, arbiter = `AIArbiter`, `humanGate`, `leaseShare` |
| `CredentialSync` | [`0xd0783EC7B0668652718f3977Ca92235fe6bF9c56`](https://eth-sepolia.blockscout.com/address/0xd0783EC7B0668652718f3977Ca92235fe6bF9c56) | [`0x47fc7cc4…422c`](https://sepolia.etherscan.io/tx/0x47fc7cc42a2b0d35de69f00019f80840618f1778f759b21d21cdfbeebcdb422c) | escrow = `RentEscrow`, subnames = `RentoutsSubnames`; `setIssuer(CredentialSync, true)` [`0x5f9d8b78…2ee4`](https://sepolia.etherscan.io/tx/0x5f9d8b786cbd15a7337cc754ceb6964723f4494bb00ffa3d107c98dbb2612ee4) |

Deployer for all of them: `0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE`.
- **`credentialSync` phase** (`ESCROW_ADDRESS=0x2357…cd18 BROADCAST=true ./scripts/ens.sh credentialSync`): deploy at block 11780915 (03:08:12), then `setIssuer`. `finalize` wrote `credentialSync` and `escrow` to `ens/deployments/sepolia.json`; no `pending*` fields are left. Receipts: `ens/broadcast/DeployEns.s.sol/11155111/credentialSync-latest.json` = `run-1790359704652.json`.
- **Issuer cleanup** (`BROADCAST=true ./scripts/ens.sh subnames`, 03:09:12): exactly the 3 `revokeRoles(keccak256(key), ROLE_SET_TEXT = 16, issuer)` txs on the `PermissionedResolver`, nothing else. `rentouts.leasesCompleted` [`0x7e1373ad…47bf`](https://sepolia.etherscan.io/tx/0x7e1373adb27cfc551b9844d3122958b1e1fbbadedde07072cdb35c644d6247bf), `rentouts.disputes` [`0xa79c86c9…c06c`](https://sepolia.etherscan.io/tx/0xa79c86c93083d5d0d1550a4839241dd84b42a339bc3fdc6b7ad877caf46cc06c), `rentouts.escrow` [`0x6f3603dc…b0bd`](https://sepolia.etherscan.io/tx/0x6f3603dc5544747bbcb4702af27a8c4bf336f978badacc4a05a773c2fd90b0bd). `rentPaid` and `depositReturnRate` were never granted. Receipts: `subnames-latest.json` = `run-1790359754352.json`.
- **Checked read-only afterwards:** `roles(keccak256(key), issuer)` is `0` for all five escrow-derived keys and `16` for `onTimeRate`, `rating` and `verified`. `RentoutsSubnames.isIssuer(CredentialSync)` is `true`. `CredentialSync.escrow()` and `subnames()` are the addresses above, and `escrowAccountId()` = `eip155:11155111:0x2357705a8382067d9be9dada2eef70e23fa4cd18`. `labelOf(alice)` is still `alice`. The wiring of the whole stack was also checked read-only: 27/27.
- `forge test` in `ens/`: 42/42 against live Sepolia.
- **The live `RentEscrow` already has the new dispute accounting.** Its tenant payout first refunds rent that wasn't earned yet, and only the rest counts as deposit returned. So a ruling that refunds unused rent but keeps the deposit records 0 returned (confirmed in the Sourcify-verified source). The `depositReturnRate` caveat in `ens/README.md` now describes this rule, and the open item is closed.

**03:15 — All five new contracts source-verified on Sourcify and Blockscout.** Both are keyless, and both show an exact match.
- Before submitting, both projects were rebuilt, and each contract's creation bytecode was compared byte for byte with the input of its deploy tx. All five match, including the metadata hash. The constructor args match `cast abi-encode` of the broadcast arguments. Settings: the four escrow-stack contracts use solc 0.8.24, cancun, optimizer 200, no via-IR. `CredentialSync` uses solc 0.8.28, cancun, optimizer 200.
- Sourcify v2 API: `match`, `creationMatch` and `runtimeMatch` are all `exact_match`. Blockscout v2 API: `is_fully_verified = true` with the right compiler; Blockscout picked the sources up from Sourcify within seconds.

| Contract | Sourcify | Blockscout | Etherscan |
|---|---|---|---|
| `AIArbiter` | `exact_match` | fully verified | not verified |
| `LeaseShare1155` | `exact_match` (already verified at 18:07Z, before this run) | fully verified | not verified |
| `HumanGate` | `exact_match` | fully verified | not verified |
| `RentEscrow` | `exact_match` | fully verified | not verified |
| `CredentialSync` | `exact_match` | fully verified | not verified |

Sourcify pages: `https://repo.sourcify.dev/11155111/<address>`. Etherscan needs an `ETHERSCAN_API_KEY`, which wasn't used here (open item).

**Sat 03:35: merged to `main` (PRs #3 to #7, merge commits, 84 build commits kept).**
- PRs: [#3 RentEscrow + human gate](https://github.com/AiAlchemist0/rentouts-escrow/pull/3), [#4 ENS identity + CredentialSync](https://github.com/AiAlchemist0/rentouts-escrow/pull/4), [#5 AI dispute judge](https://github.com/AiAlchemist0/rentouts-escrow/pull/5), [#6 demo frontend](https://github.com/AiAlchemist0/rentouts-escrow/pull/6), [#7 docs](https://github.com/AiAlchemist0/rentouts-escrow/pull/7). `main` = `b8b6441`.
- Before merging, the full order was rehearsed in a scratch clone of GitHub `main` (all clean). Codex (gpt-6-astra) + Fable reviewed every package; each finding was adversarially verified, and the confirmed ones were fixed before the merge.
- A fresh clone of `main` is green: root forge 137/137 (incl. invariants INV-1…4, AI-1…3), ens fork tests 42/42 against live Sepolia, judge 92/92, app 94/94 + production build, `app/scripts/live-smoke.mjs` all wiring checks passed with no local env, and ENS live read OK.
- Still open: Etherscan verification (needs an API key; Sourcify + Blockscout are exact-match), the first live demo lease + `CredentialSync.sync(alice)`, World ID via `HumanGate.setVerifier` (Sat), and the ENS writeup + FEEDBACK.md.

**Sat 12:09–12:39: World ID 4.0 gate live (PRs #9–#11), final QA (branch `qa/final`).**
- Dean merged `WorldHumanVerifier` (World ID 3.0, now marked deprecated, never deployed; #9), the World docs (#10) and `WorldIdV4Gate` (World ID 4.0 with RP-signed `register`; #11). `WorldIdV4Gate` `0x27052bD69b3d961940bCD093C21ba729b6c1B209` (action `fund-lease`) is Sourcify `exact_match`.
- Sat 12:09: `HumanGate.setVerifier(0x27052bD69b3d961940bCD093C21ba729b6c1B209)` from the deployer ([`0x56b47b25…43e8ee`](https://sepolia.etherscan.io/tx/0x56b47b25c08ecec6022814b78273d2568bc7a8a4bea4eb6b4dda04180543e8ee), block 11783482). From then on `fundLease` reverts `NotVerifiedHuman` for every wallet not registered there, and nobody was: the phone's one `fund-lease` proof had been spent off-chain.
- Dean deployed a second gate `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa` (action `fund-lease-wallet`, same RP signer, Sourcify `exact_match`) and registered alice on it ([`0xdbbfc6dd…148908`](https://sepolia.etherscan.io/tx/0xdbbfc6dd08fdaa4da200b51e6515a7b60423a7c3f94feb06f4a3b28f65148908), block 11783569). PR #12 records both in `deployments.json` / `docs/WORLD.md`.
- An anvil fork of Sepolia rehearsed the remaining step: `setVerifier(0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa)` from the deployer, then alice's `fundLease` succeeds (before it: `NotVerifiedHuman`).
- QA fixes: the app no longer says "World ID coming soon", tells a rejected wallet how to register, shows the verifier in the footer and re-reads the gate every 12 s; `live-smoke` fails on an open or unrecorded verifier and on an unverified demo tenant; 12 new `WorldIdV4Gate` security and end-to-end tests (root forge 163/163 in 12 suites, app 95/95 + build).
- Still open: the `setVerifier(0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa)` tx (deployer keystore), merging PR #12, and topping alice up past 2.0 USDC.

**Sat 12:42: `HumanGate` switched to the `fund-lease-wallet` gate; alice can fund (branch `qa/final`).**
- Bektur sent `HumanGate.setVerifier(0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa)` from the deployer `0xdD9c…CCCE` ([`0xcd93549e…b86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671), block 11783640, 12:42:48 JST, status 1, 33,301 gas). It emitted `VerifierUpdated(0x2705…B209 → 0x5Cb8…aABa)`. No escrow redeploy.
- Read back at 12:45 JST: `HumanGate.verifier()` = `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`; `HumanGate.isVerified(alice 0x4848…e936)` = `true`. Alice is the one registered wallet, so every other tenant reverts `NotVerifiedHuman`. The first gate `0x2705…B209` (action `fund-lease`, 0 registrations, `isVerified(alice)` = `false`) is superseded. `nextLeaseId` = 1, so no lease was funded under either gate. Alice holds 2.0 USDC and 0.01 ETH.
- The two gates' runtime code is identical except the `actionHash` immutable (`fund-lease` vs `fund-lease-wallet`); gate #2 is Sourcify `exact_match`. The anvil fork rehearsal before the switch showed alice funding after it, an unregistered wallet reverting `NotVerifiedHuman`, and `setVerifier(0)` rolling back.
- Merged `origin/main` into `qa/final` twice, merge commits only. PR #12 (Dean's World docs, no conflicts) was written before the switch and still said `setVerifier` was pending, so `qa/final` first made a minimal factual fix in `deployments.json`, `docs/WORLD.md` and `docs/BEKTUR-WORLD-V4.md`. Dean's PR #13 then recorded the switch in those files himself (`sepoliaWorldIdV4Wallet`: `status` live, `setVerifier` tx, block 11783640; `sepoliaWorldIdV4`: `status` superseded), and the second merge takes his versions of his files unchanged. The conflicts in README, ARCHITECTURE, DEMO, DECISIONS and PLAN were resolved by keeping the `qa/final` text (both gates, timestamps, trust limits, the corrected diagrams) and adding PR #13's facts (the live action/signal rows, the World ID verifier row, the `0x5Cb8…` address in the checks).
- README, ARCHITECTURE, DEMO (pre-flight step 0: alice can fund; both checks), DECISIONS (ADR-10, ADR-12), PLAN and app/README now say the verifier is gate #2 since 12:42 JST and list gate #1 as superseded. `live-smoke` now fails unless `HumanGate.verifier()` is the gate with the latest recorded `setVerifierBlock` in `deployments.json`, and checks `isVerified(alice)`.
- Checks at 12:53 JST, rerun at 12:58 after merging PR #13 (same results): root forge 163/163 (12 suites); app `tsc` clean, production build, vitest 95/95, `live-smoke` all wiring checks passed (`humanGate.verifier()` = `0x5Cb8…aABa`, `isVerified(alice)` = `true`, first gate listed as superseded; a scratch copy with a mismatched `setVerifierBlock` fails as intended), `ens-smoke` OK.
- Seen in the same smoke run: `AIArbiter.agent()` is now `0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE`. The human arbiter `0x798b…e486` called `setAgent` at 12:51 JST ([`0x0fc2c12c…bb44ad`](https://sepolia.etherscan.io/tx/0x0fc2c12c8686c3b24ee9435a560cc9e795ae675eb057095066969b2ce3bb44ad), block 11783678). The docs and `deployments.json` still say `0x4a44…d0dA` (`rentouts-judge`); not changed here.
- Still open: top alice up to at least 3.0 USDC before pre-staging the demo leases, Etherscan verification, and the first live lease + `CredentialSync.sync(alice)`.

**Sat 12:47: Tokyo restoration rules pack for the AI judge (`feat/judge-tokyo-rules`, not merged yet).** `judge/src/rules/tokyo.ts` = `tokyo-restoration v1.0.0`, rules TKY-1…7 paraphrasing TMG + MLIT guidance, hashed into every ruling. Answers cite rule ids and the `Proposed` summary ends with them (e.g. `[tokyo-restoration v1.0.0: TKY-2, TKY-4, TKY-5]`, inside the 1000-byte cap); the app shows it as-is. After merging `main` `1f592ac`: judge 109/109, app 94/94 + build, live-smoke + ens-smoke OK.

---

## Open items

- [x] Core escrow: dispute rulings inflated `rentouts.depositReturnRate` (the tenant's share counted as deposit returned before unearned rent). Fixed in the live `RentEscrow` (unearned rent is refunded first); the README caveat now describes the new rule (Sat 03:05).
- [x] Broadcast the issuer role cleanup: 3 `revokeRoles`, Sat 03:09. `roles()` is 0 on all five escrow-derived keys.
- [ ] Etherscan verification of the five new contracts (Bektur, needs `ETHERSCAN_API_KEY`): `forge verify-contract <address> <Contract> --chain sepolia --verifier etherscan --constructor-args <hex> --watch`, run in the project that built it (escrow stack: `feat/ai-judge`; `CredentialSync`: `ens/`), with the constructor args from the deploy tx. Sourcify and Blockscout are done.
- [ ] First live `sync`: after alice's demo lease closes, call `CredentialSync.sync(alice)` and read `rentouts.leasesCompleted` / `rentouts.escrow` back through the Universal Resolver.

- [x] Claim `alice.rentouts.eth` → **gate** (22:24).
- [x] `CredentialSync` (replaces the off-chain relayer): live at `0xd0783EC7B0668652718f3977Ca92235fe6bF9c56` (Sat 03:08), issuer on `RentoutsSubnames`, reads `RentEscrow` `0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18`.
- [ ] Later (post-hackathon): hand the `RentoutsSubnames` admin and both proxies' root roles to a Safe, following the handover runbook in `ens/README.md`.
- [ ] `app/src/lib/ens.ts`: claim step (`simulateContract` for availability, `labelOf(account)` on connect, `normalize()`), profile card (show `rentouts.*` only when `status == active` and `addr` matches).
- [ ] ENS section of README + `FEEDBACK.md`; paste the exact Tokyo ENS prize text into `docs/ens/PRIZE.md`.
- [ ] Ask ENS mentors: another Sepolia redeploy before Sunday? Does app.ens.dev show UserRegistry subnames + custom keys?
- [x] World gate: live since Sat 12:09 JST ([`0x56b47b25…43e8ee`](https://sepolia.etherscan.io/tx/0x56b47b25c08ecec6022814b78273d2568bc7a8a4bea4eb6b4dda04180543e8ee)). Since 12:42 JST `HumanGate.verifier` = `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa` ([`0xcd93549e…b86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671)), where alice is registered, so alice can fund (see the Sat 12:42 entry).
- [ ] Top alice up to at least 3.0 test USDC before pre-staging the demo leases (she holds 2.0).
