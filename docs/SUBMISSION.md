# Judge guide: RentOuts Escrow (ETHGlobal Tokyo 2026)

RentOuts Escrow is the on-chain layer for [RentOuts](https://rentouts.co), a rental marketplace. A contract holds the tenant's USDC deposit and prepaid rent, pays the landlord period by period, and returns the deposit. Neither RentOuts nor the landlord can take the funds.

Around the escrow:
- **Disputes:** an AI judge can only *propose* a split, and only while it holds its ENS name `judge.rentouts.eth`. A human arbiter has the last word.
- **Identity:** the tenant's track record is derived on-chain and written to a soulbound ENSv2 name.
- **Access:** World ID 4.0 gates who may fund a lease.
- **Asset:** each lease is a compliance-gated ERC-1155.

Everything is on **Ethereum Sepolia** (testnet, Circle's test USDC). Start with [README](../README.md) and [ARCHITECTURE](../ARCHITECTURE.md). The demo script is [DEMO.md](./DEMO.md). The demo app is hosted at **[https://rentouts-escrow-demo.dofusd.workers.dev](https://rentouts-escrow-demo.dofusd.workers.dev)** (MetaMask on Sepolia) and also runs locally ([app/README.md](../app/README.md)).

## Live contracts

Every address below had contract code when we checked on Sat 2026-09-26 at 12:45 JST (`cast code`; `EnsAgentRelay` at 13:40 JST). Every contract we wrote is source-verified on Sourcify with an `exact_match`, including the Base Sepolia one. The Ethereum Sepolia ones are also verified on Blockscout.

| Contract | Address (Ethereum Sepolia, 11155111) | What it does |
| --- | --- | --- |
| `RentEscrow` | [`0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18`](https://eth-sepolia.blockscout.com/address/0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18) | USDC escrow. Its token, arbiter, lease shares and human gate are fixed at deployment (immutable). |
| `AIArbiter` | [`0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5`](https://eth-sepolia.blockscout.com/address/0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5) | The escrow's arbiter. AI proposes, 120 s appeal window, human override. |
| `EnsAgentRelay` | [`0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE`](https://eth-sepolia.blockscout.com/address/0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE) | `AIArbiter.agent()` since Sat 12:51 JST. Forwards AI proposals only from the current holder of `judge.rentouts.eth`. |
| `HumanGate` | [`0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd`](https://eth-sepolia.blockscout.com/address/0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd) | Asked by `fundLease`. It forwards the question to its `verifier`. |
| `WorldIdV4Gate` (live) | [`0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`](https://eth-sepolia.blockscout.com/address/0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa) | The verifier since Sat 12:42 JST: wallets registered after a World ID 4.0 Proof of Human for the `fund-lease-wallet` action. |
| `WorldIdV4Gate` (superseded) | [`0x27052bD69b3d961940bCD093C21ba729b6c1B209`](https://eth-sepolia.blockscout.com/address/0x27052bD69b3d961940bCD093C21ba729b6c1B209) | Same contract for the `fund-lease` action. It was the verifier from 12:09 to 12:42 JST. No wallet registered on it. |
| `LeaseShare1155` | [`0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09`](https://eth-sepolia.blockscout.com/address/0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09) | Lease shares. Minter = `RentEscrow`. |
| `RentoutsSubnames` | [`0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60`](https://eth-sepolia.blockscout.com/address/0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60) | Issues soulbound `*.rentouts.eth` names. |
| `CredentialSync` | [`0xd0783EC7B0668652718f3977Ca92235fe6bF9c56`](https://eth-sepolia.blockscout.com/address/0xd0783EC7B0668652718f3977Ca92235fe6bF9c56) | Permissionless `sync(tenant)`: escrow stats → `rentouts.*` records. |
| `PermissionedResolver` (ENS proxy) | [`0xBB8A105f48Ac836F549eC0B6A1a45BB7BA0961E5`](https://eth-sepolia.blockscout.com/address/0xBB8A105f48Ac836F549eC0B6A1a45BB7BA0961E5) | Resolver for `rentouts.eth` and its subnames. |
| `UserRegistry` (ENS proxy) | [`0xD2D122000D4725a863376EcAe4220BC20590f382`](https://eth-sepolia.blockscout.com/address/0xD2D122000D4725a863376EcAe4220BC20590f382) | Subname registry of `rentouts.eth`. |

The two ENS proxies were deployed through ENS's `VerifiableFactory`, so their code is ENS's.

The two `WorldIdV4Gate`s run the same code and differ only in the action fixed at deployment. World ID gives each human one nullifier per action. Our test phone had already spent its `fund-lease` nullifier on a proof whose signal wasn't a wallet, so nothing could be registered on the first gate. Dean deployed a second gate for a new action, `fund-lease-wallet`.

**Standalone deployment on Base Sepolia (84532):** `LeaseShare1155` [`0x5490e5dFcDcA741aC99127f66B4abf6204cd64C5`](https://sepolia.basescan.org/address/0x5490e5dFcDcA741aC99127f66B4abf6204cd64C5), with the on-chain compliance demo transactions listed in the README.

**External contracts we use:** Circle test USDC `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` and the ENS Universal Resolver `0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe`.

**Machine-readable addresses:** [`deployments.json`](../deployments.json) and [`ens/deployments/sepolia.json`](../ens/deployments/sepolia.json).

### Live state (Sat 2026-09-26, 12:45 JST, block 11783652; the AI judge and alice re-read at 13:40 JST)

**World ID is on, through the second gate.**
- `HumanGate.verifier()` has been `WorldIdV4Gate` `0x5Cb8…aABa` (`fund-lease-wallet`) since tx [`0xcd93549e…eb86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671) (block 11783640, 12:42 JST). The gate owner sent it, and `VerifierUpdated` records the switch from the first gate.
- The first gate `0x2705…B209` (`fund-lease`) was the verifier from tx [`0x56b47b25…43e8ee`](https://sepolia.etherscan.io/tx/0x56b47b25c08ecec6022814b78273d2568bc7a8a4bea4eb6b4dda04180543e8ee) (block 11783482, 12:09 JST) until the switch. It has no `HumanRegistered` events and is no longer consulted.
- `deployments.json` records both: `sepoliaWorldIdV4Wallet` is `live` (with the `setVerifier` tx and block 11783640), and `sepoliaWorldIdV4` is `superseded`.

**Alice is the only registered wallet.**
- `alice.rentouts.eth` (`0x4848…e936`) registered on the second gate in tx [`0xdbbfc6dd…148908`](https://sepolia.etherscan.io/tx/0xdbbfc6dd08fdaa4da200b51e6515a7b60423a7c3f94feb06f4a3b28f65148908) (block 11783569, 12:28 JST). It is the gate's only `HumanRegistered` event, so `HumanGate.isVerified` is `true` for her and `false` for everyone else.
- Any other tenant's `fundLease` reverts `NotVerifiedHuman(tenant)` until that tenant registers through the World ID 4.0 flow.
- The gate owner can reopen funding with `setVerifier(address(0))`. Leases that are already funded never consult the gate.

**The AI judge is gated by ENS** (read at 13:40 JST).
- `judge.rentouts.eth` resolves to the judge key `0x4a44…d0dA`. The deployer, a `RentoutsSubnames` issuer, registered it in [`0x5454ab9b…4e73`](https://sepolia.etherscan.io/tx/0x5454ab9bf9e6c62ba94726628daf159fbfd087aa24cdbd39f21718b72e8d4e73) (block 11783660, 12:47 JST), and the judge key set its `description` and `url`.
- `AIArbiter.agent()` is `EnsAgentRelay` `0xe56E…C3eE`: the human arbiter's `setAgent` in [`0x0fc2c12c…bb44ad`](https://sepolia.etherscan.io/tx/0x0fc2c12c8686c3b24ee9435a560cc9e795ae675eb057095066969b2ce3bb44ad) (block 11783678, 12:51 JST). `relay.judge()` is `0x4a44…d0dA`, the name's holder.
- So the judge key's direct `AIArbiter.propose` reverts `NotAgent`, any other wallet's `relay.propose` reverts `NotEnsJudge`, and revoking the name would stop AI proposals (the human still rules). The live name is never revoked, because labels are single-use; that case is a fork test.
- `deployments.json` records it: `sepoliaAIArbiter.agent` is the relay, with `judgeKey`, `judgeName` and `agentSince`, and `sepoliaEnsAgentRelay` has the deploy and `setAgent` txs.

**Alice holds 3.0 test USDC** (1.0 from the deployer at 12:56 JST, [`0xb315f812…a170`](https://sepolia.etherscan.io/tx/0xb315f812ad413cc9b4bd9115b040719bb903303db7e706bcc4c644168515a170), block 11783705), enough for the four demo leases.

**The escrow has no leases yet** (`nextLeaseId() == 1`). `alice.rentouts.eth` resolves. Its escrow-derived records appear after her first lease and a `CredentialSync.sync`.

Check any of this yourself:

```bash
RPC=https://ethereum-sepolia-rpc.publicnode.com
cast call 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd "verifier()(address)" --rpc-url $RPC   # 0x5Cb8…aABa (second WorldIdV4Gate)
cast call 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd "isVerified(address)(bool)" 0x484811c8c967809bE644A89d677933c29fb9e936 --rpc-url $RPC  # true (alice)
cast resolve-name alice.rentouts.eth --rpc-url $RPC                                       # 0x4848…e936
cast call 0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18 "humanGate()(address)" --rpc-url $RPC  # HumanGate
cast call 0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18 "nextLeaseId()(uint256)" --rpc-url $RPC  # 1 (no leases yet)
cast call 0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5 "agent()(address)" --rpc-url $RPC      # 0xe56E…C3eE (EnsAgentRelay)
cast call 0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE "judge()(address)" --rpc-url $RPC      # 0x4a44…d0dA
cast resolve-name judge.rentouts.eth --rpc-url $RPC                                        # 0x4a44…d0dA
```

`cd app && npm run live:smoke` runs all of these checks and more against `deployments.json`.

## How each sponsor's technology is used

### ENS (ENSv2 beta, Sepolia)

Tenants get a soulbound `<name>.rentouts.eth` whose `rentouts.*` text records carry their rental record.

- [`ens/src/RentoutsSubnames.sol`](../ens/src/RentoutsSubnames.sol)
  - Registers names in our own `UserRegistry` with an **empty role bitmap**, which makes them soulbound.
  - Writes an ENSIP-19 default address.
  - Revokes with `unregister` plus a `linkToRecord(name, 0)` record wipe.
- [`ens/src/CredentialSync.sol`](../ens/src/CredentialSync.sol): anyone can call `sync(tenant)`. It reads `RentEscrow.tenantStats` and writes the track-record keys.
- [`ens/script/DeployEns.s.sol`](../ens/script/DeployEns.s.sol)
  - Deploys the `VerifiableFactory` proxies.
  - Registers `rentouts.eth` via commit/reveal.
  - Grants the issuer **key-scoped** resolver roles (`grantSetterRoles`), so it can write `rentouts.onTimeRate` but not `avatar`.
- Fork tests in [`ens/test/`](../ens/test) run against the live ENSv2 deployment.
- **Live: ENS gates the AI judge.** The judge's key holds `judge.rentouts.eth` ([`ens/script/JudgeName.s.sol`](../ens/script/JudgeName.s.sol)), and since Sat 12:51 JST `AIArbiter.agent()` is [`src/EnsAgentRelay.sol`](../src/EnsAgentRelay.sol), which forwards a proposal only if the caller is `RentoutsSubnames.holderOf(judge)` **and** the ENS `UserRegistry` owner of the name. Remove ENS and the AI can't propose. The judge also resolves its own name through the Universal Resolver before signing, and the app labels proposals "Proposed by judge.rentouts.eth ✓". Tests: [`test/EnsAgentRelay.fork.t.sol`](../test/EnsAgentRelay.fork.t.sol) and [`ens/test/JudgeName.fork.t.sol`](../ens/test/JudgeName.fork.t.sol) run against the live relay and name on a fork, including the revoke case.
- **Next step, ready to deploy (not live):** [`src/EnsCredentialGate.sol`](../src/EnsCredentialGate.sol) and [`src/AllOfHumanGate.sol`](../src/AllOfHumanGate.sol) would put ENS in the funding path too. With `HumanGate.setVerifier(AllOf[WorldIdV4Gate, EnsCredentialGate])`, funding a lease needs a World ID **and** an active `rentouts.eth` name, with no escrow redeploy. A fork test against live Sepolia ([`test/EnsWorldGate.fork.t.sol`](../test/EnsWorldGate.fork.t.sol)) shows alice funding with both, and funding stopping when either is removed. Today the live verifier is still World ID only.
- The app reads names and records only through the Universal Resolver (`getEnsAddress` / `getEnsText` in [`app/src/hooks.ts`](../app/src/hooks.ts)). A landlord can create a lease for an ENS name.

Details and the trust model are in [ens/README.md](../ens/README.md). The build log with tx hashes is [docs/ens/LOG.md](./ens/LOG.md).

### World ID 4.0

World ID gates one thing: who may fund a new lease.

- [`src/HumanGate.sol`](../src/HumanGate.sol) is the seam in [`RentEscrow.fundLease`](../src/RentEscrow.sol). The owner can swap its verifier without redeploying the escrow, and did so twice on the live escrow. It never touches funds or funded leases.
- [`src/WorldIdV4Gate.sol`](../src/WorldIdV4Gate.sol) is the live verifier. The live deployment is for the action `fund-lease-wallet`.
  - World App produces a 4.0 Proof of Human for that action, with the tenant's wallet as the signal, and World's `/api/v4/verify` accepts it.
  - The RentOuts RP signer then attests `(chainId, gate, actionHash, wallet, nullifier, deadline)`.
  - `register` checks that signature and consumes the nullifier, one human per action. After that, `isVerified(wallet)` is true.
  - The IDKit page and the RP signing step run off-chain. The signing key is not in this repo.
- [`src/WorldHumanVerifier.sol`](../src/WorldHumanVerifier.sol) is the World ID 3.0 router check we wrote first. It is not used live, because a 3.0 router can't verify the 4.0 proofs World App issues.
- The app maps `NotVerifiedHuman` on the fund step ([`app/src/lib/humanGate.ts`](../app/src/lib/humanGate.ts)).
- Background: [docs/WORLD.md](./WORLD.md) and the World section of [ARCHITECTURE](../ARCHITECTURE.md).

### Compliance-gated ERC-1155 lease shares (Curvegrid RWA track)

- [`src/LeaseShare1155.sol`](../src/LeaseShare1155.sol) is an ERC-1155 with `tokenId == leaseId`. An allowlist check in the OpenZeppelin v5 `_update` hook covers mints, single transfers and batch transfers. Non-allowlisted recipients revert `NotAllowlisted`.
- `RentEscrow.createLease` mints 100 shares to the landlord, so a landlord outside the allowlist can't list a lease.
- Tests: [`test/LeaseShare1155.t.sol`](../test/LeaseShare1155.t.sol), including a fuzz test that non-allowlisted recipients are always rejected.
- The standalone Base Sepolia deployment has an on-chain compliance demo: a mint, an allowlisting, an allowlisted transfer, and a non-allowlisted transfer that reverts (README, Curvegrid section).
- MultiBaas is not used in this build.

### AI dispute judge (our own component)

- [`src/AIArbiter.sol`](../src/AIArbiter.sol) holds the proposal. The agent can only propose. The contract can only split one disputed lease's escrow between that lease's own tenant and landlord.
- The agent is [`src/EnsAgentRelay.sol`](../src/EnsAgentRelay.sol) since Sat 12:51 JST, so the judge key proposes only while it holds `judge.rentouts.eth` (see the ENS section). Rollback is the human's `setAgent(<judge key>)`.
- [`judge/`](../judge/README.md) calls z.ai GLM 5.3 with a fixed checklist. Code computes the split, and the judge abstains to the human when it isn't confident.
- The judge applies a versioned **Tokyo restoration rules pack** ([`judge/src/rules/tokyo.ts`](../judge/src/rules/tokyo.ts), TKY-1…7, paraphrasing Tokyo Metropolitan Government and MLIT guidance). Code charges the tenant only for items classed as tenant damage, and depreciates wallpaper, carpet and cushion flooring by age. The ruling hash commits to the pack, and the on-chain summary cites the rule ids.

## Built at the event vs before

**Before the event:**
- This repo was created Thu 2026-09-24 12:14 JST with three commits: an initial commit, a placeholder README and the MIT license.
- The RentOuts marketplace ([rentouts.co](https://rentouts.co)) and its separate private codebase existed before the event. That codebase includes an April 2026 lease-contract prototype and pre-event planning notes. None of it is in this repo.
- `RentEscrow` was written new here. The only lines it shares with that prototype are boilerplate: OpenZeppelin imports, a few one-line checks and common function signatures.

**During the event:** hacking began Fri 2026-09-25 21:00 JST. First commits and on-chain milestones, in JST:

| When | What | Evidence |
| --- | --- | --- |
| Fri 21:27 | ENS design brief and docs research | `9882d0d` |
| Fri 21:39 | `RentoutsSubnames` and fork tests | `944eb00` |
| Fri 22:15–22:24 | `rentouts.eth` registered, `alice.rentouts.eth` resolves on live Sepolia | [LOG](./ens/LOG.md), block 11779454 |
| Fri 22:42 | `LeaseShare1155` deployed on Base Sepolia (PR #1 merged 22:51) | block 47287732, `7330ee6` |
| Fri 22:51 | `RentEscrow` and invariant suite | `f180a25` |
| Fri 22:52 | `CredentialSync` | `cf7e309` |
| Fri 23:18 | Demo app | `7b0d7fe` |
| Sat 00:43 | `HumanGate` seam | `4ffce4c` |
| Sat 00:58 | `AIArbiter` | `75ddfcd` |
| Sat 01:14 | AI judge service | `352f3a0` |
| Sat 03:05–03:09 | Escrow stack and `CredentialSync` live on Ethereum Sepolia | [LOG](./ens/LOG.md) |
| Sat 03:32–03:35 | PRs #3–#8 merged | merge commits |
| Sat 11:42 | `WorldHumanVerifier` (World ID 3.0) | `73e06c6` |
| Sat 11:55 | `WorldIdV4Gate` deployed (PR #11 merged 11:56) | block 11783413, `6e36a33` |
| Sat 12:09 | `HumanGate.setVerifier(WorldIdV4Gate)`, first gate (`fund-lease`) | block 11783482 |
| Sat 12:25 | World ID AND ENS combined gate (`EnsCredentialGate`, `AllOfHumanGate`), fork-tested, not deployed | `2c3c87b` |
| Sat 12:26 | Second `WorldIdV4Gate` (`fund-lease-wallet`) deployed | block 11783562 |
| Sat 12:28 | `alice.rentouts.eth` registered on the second gate after a World ID 4.0 proof | block 11783569 |
| Sat 12:38 | AI judge grounded in the Tokyo restoration rules pack | `2364be3` |
| Sat 12:33–12:41 | `judge.rentouts.eth` script and fork tests, `EnsAgentRelay`, the judge's ENS check, the app's judge-name label | `6840934`, `57c1392`, `e187c53`, `d0cd2ad` |
| Sat 12:42 | `HumanGate.setVerifier` switched to the second gate | block 11783640 |
| Sat 12:47 | `judge.rentouts.eth` registered to the AI judge's key | block 11783660 |
| Sat 12:50 | `EnsAgentRelay` deployed | block 11783676 |
| Sat 12:51 | `AIArbiter.setAgent(EnsAgentRelay)` by the human arbiter: ENS gates the AI judge | block 11783678 |
| Sat 12:56 | alice topped up to 3.0 test USDC | block 11783705 |
| Sat 13:02–13:08 | PRs #14–#16 merged (QA pass, Tokyo rules, combined gate) | merge commits |
| Sat 13:11–13:14 | PRs #17–#18 merged (submission docs, counts) | merge commits |

Commit rows use git author times and on-chain rows use block times. Branches were rebased before merging, so `git log` order isn't strictly chronological. Squash-merged PRs show their merge time.

## Team

| | GitHub | Built |
| --- | --- | --- |
| Dean | [@AiAlchemist0](https://github.com/AiAlchemist0) | `LeaseShare1155` and its Base Sepolia deployment; the World ID integration (World Developer Portal app, IDKit and RP-signing flow, `WorldHumanVerifier`, both `WorldIdV4Gate` deployments, alice's registration) |
| Bektur | [@Apolotary](https://github.com/Apolotary) | `RentEscrow` and `HumanGate`, `AIArbiter` and the judge service (including the Tokyo rules pack), the ENS package, `judge.rentouts.eth` and `EnsAgentRelay`, the World ID AND ENS combined gate, the demo app, the Ethereum Sepolia deployments and both `setVerifier` switches |

## More

- [ENS developer feedback](./ens/FEEDBACK.md): what worked, what we hit, and what we'd like next.
- [AI usage](../AI_USAGE.md): which AI tools we used and where, what the humans did, and the AI inside the product.
- [Design decisions](./DECISIONS.md) and the [build plan](./PLAN.md).
