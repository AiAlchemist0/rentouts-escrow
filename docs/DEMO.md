# Demo script (about 3 minutes)

A runnable script for the judge demo and the video. Everything happens on **Ethereum Sepolia** with **Circle test USDC**. How the pieces fit is in [ARCHITECTURE.md](../ARCHITECTURE.md).

The story: *a landlord leases to `alice.rentouts.eth` by name. Alice's money sits in a contract, not with RentOuts or the landlord. Rent unlocks period by period, the deposit comes back, and the finished lease lands on Alice's ENS credential, where any app can read it. When a lease is disputed, an AI judge proposes a split in seconds, but it only proposes: the parties can appeal and a human arbiter has the last word.*

**Hosted app:** [https://rentouts-escrow-demo.dofusd.workers.dev](https://rentouts-escrow-demo.dofusd.workers.dev) (static build of `app/` on Cloudflare Workers, no secrets, addresses from the repo's deployment records). It works in place of `npm run dev` for every step below. The build there was made before the `judge.rentouts.eth` label landed on `main`: until it is rebuilt from `main`, its AI judge panel shows "AI judge key" and the address instead of "Proposed by judge.rentouts.eth ✓"; everything else is the same.

The demo runs on the live Sepolia deployment, broadcast Sat 2026-09-26 between 03:05 and 03:09 JST and source verified on Sourcify and Blockscout ([ARCHITECTURE §10](../ARCHITECTURE.md#10-deployments)). The same addresses are in the root `deployments.json` (`"sepolia"`, `"sepoliaAIArbiter"`, `"sepoliaEnsAgentRelay"`) and in `ens/deployments/sepolia.json`.

| Contract | Address |
|---|---|
| `RentEscrow` | [`0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18`](https://eth-sepolia.blockscout.com/address/0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18) |
| `AIArbiter` (the escrow's arbiter, bound to it) | [`0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5`](https://eth-sepolia.blockscout.com/address/0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5) |
| `EnsAgentRelay` (`AIArbiter.agent()` since Sat 12:51 JST, [tx `0x0fc2c12c…bb44ad`](https://sepolia.etherscan.io/tx/0x0fc2c12c8686c3b24ee9435a560cc9e795ae675eb057095066969b2ce3bb44ad); forwards proposals only from the holder of `judge.rentouts.eth`) | [`0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE`](https://eth-sepolia.blockscout.com/address/0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE) |
| `HumanGate` (verifier = the `fund-lease-wallet` `WorldIdV4Gate` since Sat 12:42 JST, [tx `0xcd93549e…b86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671)) | [`0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd`](https://eth-sepolia.blockscout.com/address/0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd) |
| `WorldIdV4Gate` (World ID 4.0, action `fund-lease-wallet`, **alice registered**; the live verifier since Sat 12:42 JST) | [`0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`](https://eth-sepolia.blockscout.com/address/0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa) |
| `WorldIdV4Gate` (first gate, action `fund-lease`, nobody registered; verifier Sat 12:09–12:42 JST, **superseded**) | [`0x27052bD69b3d961940bCD093C21ba729b6c1B209`](https://eth-sepolia.blockscout.com/address/0x27052bD69b3d961940bCD093C21ba729b6c1B209) |
| `LeaseShare1155` (minter = `RentEscrow`) | [`0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09`](https://eth-sepolia.blockscout.com/address/0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09) |
| `CredentialSync` | [`0xd0783EC7B0668652718f3977Ca92235fe6bF9c56`](https://eth-sepolia.blockscout.com/address/0xd0783EC7B0668652718f3977Ca92235fe6bF9c56) |
| `RentoutsSubnames` | [`0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60`](https://eth-sepolia.blockscout.com/address/0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60) |
| Circle test USDC | [`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`](https://sepolia.etherscan.io/address/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) |

---

## Cast

Two accounts in one MetaMask, switched between steps. The app follows whichever account is selected. Two more keys are used only from a terminal.

| Role | Account | Where | Needs |
|---|---|---|---|
| **Tenant: alice** | `0x484811c8c967809bE644A89d677933c29fb9e936`, holds `alice.rentouts.eth` (Foundry keystore `rentouts-alice`) | MetaMask and terminal | ~0.01 Sepolia ETH (she has 0.01), **≥ 3.0 test USDC** (she has 3.0 since Sat 12:56 JST; 2.0 is the bare minimum), and **registered in the live `WorldIdV4Gate`** (see pre-flight step 0) |
| **Landlord: deployer** | `0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE` (keystore `rentouts-deployer`). Allowlisted on `LeaseShare1155` by `DeployEscrow`; also owns the share contract and the `HumanGate`. | MetaMask and terminal | ~0.02 Sepolia ETH |
| **AI judge** | `0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA` (keystore `rentouts-judge`), the holder of **`judge.rentouts.eth`**. `AIArbiter.agent` is the `EnsAgentRelay` `0xe56E…C3eE`, so the key proposes only through the relay, and only while it holds the name. It only ever calls `propose`. | terminal: `JUDGE_RELAY=0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE ./run.sh` in `judge/` | ~0.01 Sepolia ETH |
| **Human arbiter** | `0x798b01Cef62b889943Ce1D3C5011a755B297e486`, which is `AIArbiter.human`. It bound the escrow once, made the relay the agent (`setAgent`, Sat 12:51 JST), and rules on appealed or abstained leases (`resolveByHuman`). | terminal (its own keystore) | ~0.005 Sepolia ETH |

`RentEscrow`'s arbiter is the `AIArbiter` **contract**, not a wallet. The app's footer lists it on the *Arbiter* row.

Two more addresses are only typed in, never connected:
- **Investor**: a team-controlled EOA with no other demo role. The share owner allowlists it in pre-flight.
- **Stranger**: `0x000000000000000000000000000000000000dEaD`, which is not allowlisted.

**Demo lease terms:** deposit **0.20**, rent **0.10** per period, period **60** seconds, **3** periods. Alice prepays 0.50 USDC per lease, and each lease runs 3 minutes. (The app's defaults are larger: 0.25 / 0.20 / 120 s / 3.) The demo uses four leases (A, B, C and the one created live), so alice needs at least 2.0 USDC. She holds **3.0** since Sat 12:56 JST (1.0 USDC from the deployer in [`0xb315f812…a170`](https://sepolia.etherscan.io/tx/0xb315f812ad413cc9b4bd9115b040719bb903303db7e706bcc4c644168515a170), block 11783705), which leaves 1.0 USDC of slack for a mistyped term or a re-created lease. Type 0.20 / 0.10 / 60 / 3 exactly.

---

## Pre-flight (T-30 min)

In a terminal, set the addresses once:

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com   # or a private RPC
ESCROW=0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18   # RentEscrow
ARB=0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5      # AIArbiter
SHARES=0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09   # LeaseShare1155
GATE=0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd     # HumanGate
WORLD=0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa    # WorldIdV4Gate fund-lease-wallet (alice registered): HumanGate.verifier since Sat 12:42 JST
SYNC=0xd0783EC7B0668652718f3977Ca92235fe6bF9c56     # CredentialSync
RELAY=0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE    # EnsAgentRelay = AIArbiter.agent() since Sat 12:51 JST
JUDGE=0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA    # the judge key = judge.rentouts.eth
```

0. **The World gate accepts alice: check it before any lease is funded.** The gate is ON: `fundLease` reverts `NotVerifiedHuman` for every wallet the `HumanGate`'s verifier hasn't registered. Status at Sat 12:45 JST, read on-chain:
   - `HumanGate.verifier()` = `WORLD`, the `WorldIdV4Gate` `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa` (action `fund-lease-wallet`), since Sat 12:42 JST: `setVerifier` from the deployer, tx [`0xcd93549e…b86671`](https://sepolia.etherscan.io/tx/0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671), block 11783640.
   - Alice is registered there (`register` tx [`0xdbbfc6dd…148908`](https://sepolia.etherscan.io/tx/0xdbbfc6dd08fdaa4da200b51e6515a7b60423a7c3f94feb06f4a3b28f65148908), block 11783569), so `isVerified(alice)` is `true` and **alice can fund**. She is the only registered wallet: any other tenant reverts `NotVerifiedHuman`. A fork rehearsal of the switch confirmed both (alice funds, an unregistered wallet reverts) and that `setVerifier(0)` rolls back.
   - The first gate `0x27052bD69b3d961940bCD093C21ba729b6c1B209` (action `fund-lease`, the verifier from Sat 12:09 to 12:42 JST) is **superseded**. Nobody is registered there, and nobody on the team can be: Dean's phone spent its `fund-lease` nullifier off-chain (signal `rentouts-fund-lease`).

   Both checks must hold before pre-staging leases A, B and C:
   ```bash
   cast call ${GATE} "verifier()(address)" --rpc-url ${SEPOLIA_RPC_URL}      # = WORLD
   cast call ${GATE} "isVerified(address)(bool)" 0x484811c8c967809bE644A89d677933c29fb9e936 --rpc-url ${SEPOLIA_RPC_URL}   # = true
   ```
   `npm run live:smoke` in `app/` checks the same two things: it fails unless `verifier()` is the gate with the latest recorded `setVerifier` in `deployments.json` (`sepoliaWorldIdV4Wallet`) and `isVerified(alice)` is `true`. One World ID registers one wallet on a gate, for good, so don't spend another human's proof on a second wallet unless the demo needs it. If the gate breaks at demo time, the last resort is `setVerifier(0x0000000000000000000000000000000000000000)` from the deployer (see Fallbacks): the gate is then open, which removes World from the funding path.
1. **Funds.** Top up the four accounts above with Sepolia ETH from the [ETHGlobal faucet](https://ethglobal.com/faucet), and alice with USDC from the ETHGlobal faucet (1 USDC per claim) or [Circle's faucet](https://faucet.circle.com).
2. **MetaMask.** On Sepolia, with alice and the deployer imported. A Foundry keystore is a standard JSON keystore, so MetaMask can import it (*Import account → JSON file*). Start on **alice**.
3. **App.** Either open the hosted build, [https://rentouts-escrow-demo.dofusd.workers.dev](https://rentouts-escrow-demo.dofusd.workers.dev) (no setup; see the note at the top about the judge-name label), or run it locally. From `app/`: `npm install`, then create `.env.local` with the live addresses. These are every `VITE_*` value the app reads (`app/src/config.ts`):
   ```bash
   VITE_ESCROW_ADDRESS=0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18
   VITE_CREDENTIAL_SYNC_ADDRESS=0xd0783EC7B0668652718f3977Ca92235fe6bF9c56
   VITE_AI_ARBITER_ADDRESS=0xC3D50752a1f42cc54d3c90a1261779eEF5bbdCb5
   VITE_LEASE_SHARE_ADDRESS=0x9A9Fd2c881Ad7d6164F4F6b6cdB6F3207F3e1E09
   # Leave empty: Circle USDC is the default, and the escrow's token() wins anyway
   VITE_TOKEN_ADDRESS=
   # A private Sepolia RPC if you have one (public RPCs rate-limit); empty = publicnode
   VITE_SEPOLIA_RPC_URL=
   ```
   `VITE_CREDENTIAL_SYNC_ADDRESS` is required for the Sync button. Without the other address variables, the app falls back to the root `deployments.json`. Once it reads the escrow, the escrow's `token()`, `leaseShare()`, `humanGate()` and `arbiter()` take precedence. There is no variable for the gate: the app always reads `RentEscrow.humanGate()`. ENS addresses come from `ens/deployments/sepolia.json`. Then run `npm run dev`. The footer should list every contract with a link and none marked "not configured".
4. **ENS is live.** `npm run ens:smoke` prints `getEnsAddress 0x4848…e936`, `rentouts.credential = "tenant/v1"` and `rentouts.status = "active"`.
5. **The AI arbiter is wired, and ENS gates the AI judge.** These reads should print the escrow, the relay, the human arbiter and the judge key:
   ```bash
   cast call ${ARB} "escrow()(address)" --rpc-url ${SEPOLIA_RPC_URL}   # = ESCROW (bound Sat 03:07 JST)
   cast call ${ARB} "agent()(address)"  --rpc-url ${SEPOLIA_RPC_URL}   # = RELAY = 0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE (EnsAgentRelay, since Sat 12:51 JST)
   cast call ${RELAY} "judge()(address)" --rpc-url ${SEPOLIA_RPC_URL}  # = JUDGE = 0x4a444685F3E700D0d5B8Fe53d987f8029cced0dA (holder of judge.rentouts.eth)
   cast call ${RELAY} "name()(string)" --rpc-url ${SEPOLIA_RPC_URL}    # = "judge.rentouts.eth"
   cast resolve-name judge.rentouts.eth --rpc-url ${SEPOLIA_RPC_URL}    # = JUDGE (through the ENSv2 Universal Resolver)
   cast call ${ARB} "human()(address)"  --rpc-url ${SEPOLIA_RPC_URL}   # = 0x798b01Cef62b889943Ce1D3C5011a755B297e486
   cast call ${ARB} "challengeWindow()(uint32)" --rpc-url ${SEPOLIA_RPC_URL}   # = 120
   cast call ${ESCROW} "arbiter()(address)" --rpc-url ${SEPOLIA_RPC_URL}   # = ARB
   cast call ${GATE} "verifier()(address)" --rpc-url ${SEPOLIA_RPC_URL}    # = WORLD = 0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa (see step 0); 0x0000…0000 would mean the gate is open
   ```
   `agent()` must be `RELAY` and `judge.rentouts.eth` must resolve to `relay.judge()`, or the judge refuses `--propose`. `npm run live:smoke` in `app/` checks both against `deployments.json` (`"sepoliaAIArbiter".agent` = the relay, `.judgeKey` = `JUDGE`) and fails on any mismatch. If the human has rolled back (`agent()` = `JUDGE`), run the judge without `JUDGE_RELAY`.
6. **The judge runs.** In `judge/`: `npm ci`, then `export JUDGE_RELAY=0xe56E49cAA4780B71F667bF08a9ADb2C659d9C3eE` in the demo terminal (every live judge command below needs it). `run.sh` loads the team secrets file (it provides `ZAI_API_KEY`; the script never prints it). Check that `npm run judge -- --input fixtures/damage-admitted.json --provider mock` prints a ruling. Any live read-only run (`./run.sh --lease <id>` on a disputed lease) prints `judge ENS judge.rentouts.eth -> 0x4a44…d0dA = the relay's judge ✓`.
7. **Allowlist the investor** (share owner = deployer):
   ```bash
   cast send ${SHARES} "setAllowlist(address,bool)" <INVESTOR> true \
     --account rentouts-deployer --rpc-url ${SEPOLIA_RPC_URL}
   ```
8. **Pre-stage three leases.** All use the demo terms; the landlord creates each in the app and alice approves and funds it.
   - **Lease A** (for claim and close): fund it **at least 4 minutes before recording**, so its term has ended when you reach it.
   - **Lease B** (for the live AI ruling): alice clicks **Open dispute** in the app, then both parties post a statement:
     ```bash
     cast send ${ARB} "submitEvidence(uint256,string)" <B> \
       "The tenant broke the kitchen window. The glazier invoice is 0.15 USDC (invoice INV-2231, dated 26 Sep)." \
       --account rentouts-deployer --rpc-url ${SEPOLIA_RPC_URL}
     cast send ${ARB} "submitEvidence(uint256,string)" <B> \
       "I broke the kitchen window by accident, I'm sorry. Everything else was left clean and I returned the keys." \
       --account rentouts-alice --rpc-url ${SEPOLIA_RPC_URL}
     ```
   - **Lease C** (for execute): the same as B, then run the judge on it **at least 3 minutes before recording** (`JUDGE_RELAY=${RELAY} ./run.sh --lease <C> --propose`), and don't appeal. Its 120 s window is then over, so it is executable on camera. Check it with `cast call ${ARB} "getRuling(uint256)((uint8,uint16,uint16,uint64,uint64,bytes32))" <C> --rpc-url ${SEPOLIA_RPC_URL}`: status `1` (PROPOSED) and a deadline in the past.
9. **Sync alice once**, so her card shows real numbers before the demo adds to them: landlord, tab *Run the lease*, a closed lease, *Sync tenant's credential to ENS*.
10. **Screen.** Browser tabs: the app on `#identity`, the app on `?name=alice.rentouts.eth#identity` (her public credential), and Blockscout on `AIArbiter` (its verified source and events). A terminal in `judge/` with the commands for B and C typed in.

---

## Script

| Time | Account | Where | Do | The viewer sees |
|---|---|---|---|---|
| 0:00–0:15 | (any) | app header, footer | One line of pitch: *"Rent held by a contract, not a company."* Scroll to the footer. | Every contract on Sepolia with an explorer link. `RentEscrow` has no owner, no admin and no fee. Its arbiter is the `AIArbiter` contract, and the human gate sits in front of funding. |
| 0:15–0:35 | alice | **1 Claim your name** | Alice already has her name, so the tab shows her credential. | A card reading *Verified on-chain*: `alice.rentouts.eth` resolves to `0x4848…e936` with credential `tenant/v1`, plus her stats. All of it is read live through the ENSv2 Universal Resolver. Say: *soulbound (ENS refuses the transfer), revocable, and only RentOuts issuers can write `rentouts.*`*. |
| 0:35–1:00 | **landlord** | **2 Create a lease** | Tenant field: type `alice.rentouts.eth`. Enter the demo terms and click **Create lease**. | *"alice.rentouts.eth resolves to 0x4848…"* and her compact card, then a summary: *the tenant prepays 0.50 USDC*. After the tx: *Lease #N created*. 100 shares of lease #N go to the landlord, and a landlord who isn't allowlisted couldn't list at all. |
| 1:00–1:20 | **alice** | **3 Fund the lease** | Point at the human-gate notice. Click **Approve 0.50 USDC**, then **Fund lease**. | The notice says who may fund: only wallets registered in the World ID 4.0 gate (alice passes because she is registered on the live gate; an unregistered wallet sees a red notice and disabled buttons, and `fundLease` would revert `NotVerifiedHuman`). Say: *the escrow never changed; the gate owner plugged World in with one call*. Her USDC balance drops by 0.50, and *Lease funded. Rent starts unlocking now*. Only the contract can move that money from here on. |
| 1:20–1:45 | **landlord** | **4 Run the lease** | On **Lease A** (term over): click **Release … rent**, then **Close lease**. Then **Sync tenant's credential to ENS**. | Rent goes to the landlord, the deposit goes back to alice, and the state becomes *Closed*. After the sync, which the landlord can pay for because `sync` is permissionless, alice's card shows **Leases completed +1** and more rent paid. |
| 1:45–2:10 | AI judge | terminal, then app **4 Run the lease** | **Lease B** is disputed, with one statement from each side. Run `JUDGE_RELAY=${RELAY} ./run.sh --lease <B> --propose` and type the judge keystore password. | Within seconds: the model's three answers with their probabilities and a severity, then the rubric arithmetic in code, the proposed `tenantBps`, the model latency, the `rulingHash`, the line `judge ENS judge.rentouts.eth -> 0x4a44… = signer = the relay's judge ✓`, `sent … via EnsAgentRelay 0xe56E…`, and the appeal deadline. In the app, the proposal reads **Proposed by judge.rentouts.eth ✓**. Say: *the model answers questions; code computes the split; it's only a proposal. And the AI can only propose while ENS says it is judge.rentouts.eth: revoke the name and AIArbiter won't take its proposals*. |
| 2:10–2:30 | anyone (landlord) | terminal, then app **4 Run the lease** | **Lease C** was proposed minutes ago and nobody appealed: `cast send ${ARB} "execute(uint256)" <C> --account rentouts-deployer --rpc-url ${SEPOLIA_RPC_URL}`. | The lease closes in the app, and each side receives its share of what was left. Say: *either party could have appealed inside the window, and the human arbiter can overrule at any time; the arbiter can only ever pay these two parties*. |
| 2:30–2:50 | **landlord** | **5 Lease shares** | Transfer 10 shares of lease #N to **the investor**, which succeeds. Then try the **stranger** `0x…dEaD`. | The first transfer goes through. For the second, the app warns *isn't on the compliance allowlist*, and the pre-flight simulation shows `NotAllowlisted` before MetaMask even opens. |
| 2:50–3:05 | (any) | `?name=alice.rentouts.eth` | Open alice's public credential link. | The same record, readable by any ENS-aware app. No RentOuts API is involved. |

**After recording.** Lease B's proposal stays open for 120 s. Leave it to execute (anyone can), or show an appeal (`appeal(uint256)` from alice or the landlord) and a human ruling. **Lease #N**, created live at 0:35, keeps running: close it later, or leave it `ACTIVE` as a live example for judges.

---

## Fallbacks

| If… | Then… |
|---|---|
| A transaction hangs (Sepolia congestion) | Carry on with a pre-staged lease, and show the pending tx on Etherscan. |
| **Release rent** is disabled or says `NothingToClaim` | The next period hasn't elapsed yet (60 s). Talk through the countdown on the card. |
| **Close lease** is disabled | The term isn't over yet. Use Lease A, which was funded ≥ 4 min earlier. Only the landlord can close before `endTime + periodSeconds`. |
| `createLease` fails with `NotAllowlisted` | The landlord isn't on the share allowlist. Run `setAllowlist(<landlord>, true)` as the share owner, or use the deployer as the landlord. |
| `createLease` fails with `InvalidTerms` | Check that the period is ≥ 60 s, the tenant isn't the landlord, and neither is the arbiter. |
| `fundLease` fails with `NotVerifiedHuman` | The World verifier is plugged in and this wallet isn't registered on it. Check pre-flight step 0 (`verifier()` must be `WORLD`, where alice is registered). Use a registered tenant, or, as a last resort, have the gate owner reopen the gate: `cast send ${GATE} "setVerifier(address)" 0x0000000000000000000000000000000000000000 --account rentouts-deployer --rpc-url ${SEPOLIA_RPC_URL}`. |
| The judge prints **ABSTAIN, escalated to human arbiter** | That is the safety valve working: say so. It also abstains when only one side has posted, so check that both statements landed. The human arbiter rules instead: `cast send ${ARB} "resolveByHuman(uint256,uint16)" <B> 5000 --account <human arbiter keystore> --rpc-url ${SEPOLIA_RPC_URL}`. |
| The model API errors or is slow | Re-run with `--provider mock` and say it is the deterministic offline stand-in (keyword matching, not a judge). A mock proposal says so on-chain: its summary starts with `[mock judge, keyword matching]`. |
| The judge refuses to propose (`refused: …`) | Read the message. `JUDGE_RELAY is …, but AIArbiter.agent() is …`: `agent()` must be `RELAY`; if the human rolled back to the judge key, drop `JUDGE_RELAY`. `the relay's ENS judge is …`: `cast call ${RELAY} "judge()(address)"` must be `JUDGE`. `judge.rentouts.eth resolves to …` / `does not resolve`: check `cast resolve-name judge.rentouts.eth` (a public RPC hiccup: retry, or set `SEPOLIA_RPC_URL`). Last resort, the human rolls back: `cast send ${ARB} "setAgent(address)" ${JUDGE} --account <human arbiter keystore> --rpc-url ${SEPOLIA_RPC_URL}` (`../sign-judge-name.sh rollback`), then run the judge without `JUDGE_RELAY`. **Never revoke `judge.rentouts.eth`**: labels are single-use, so it could not be issued again. |
| The judge says the lease isn't disputed or the escrow's arbiter doesn't match | Open the dispute first, and check `ARB` is bound (`escrow()`) to the escrow the app uses. |
| `execute` reverts `ChallengeWindowOpen` | The 120 s window isn't over yet. Use Lease C, which was proposed earlier. |
| `execute` reverts `NoOpenProposal` | The lease was appealed, already executed or ruled by the human. Only `resolveByHuman` can close an appealed lease. |
| Sync fails with `NotIssuer` | `CredentialSync` isn't an issuer (it was made one at deploy, in [`0x5f9d8b78…`](https://sepolia.etherscan.io/tx/0x5f9d8b786cbd15a7337cc754ceb6964723f4494bb00ffa3d107c98dbb2612ee4)). From `ens/`: `ESCROW_ADDRESS=0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18 BROADCAST=true ./scripts/ens.sh credentialSync`. |
| Sync fails with `NoName` | That tenant has no `rentouts.eth` name. Use alice. |
| The app shows *escrow not configured* | Set `VITE_ESCROW_ADDRESS` in `app/.env.local` and restart `npm run dev`. Meanwhile, demo steps 1 and 5 (ENS and shares) and show the test suites below. |
| Reads fail or show rate-limit errors | Point `VITE_SEPOLIA_RPC_URL` (app) and `SEPOLIA_RPC_URL` (terminal) at a private Sepolia RPC. |
| MetaMask is on the wrong network | The app's banner offers a switch to Sepolia. |
| The ENS app doesn't show `alice.rentouts.eth` | Expected: it may not display ENSv2 beta names yet. Use the app's card, `npm run ens:smoke` or `cast resolve-name`. |
| Live chain unusable | Run `forge test` (root, including the invariant suites), `cd judge && npx vitest run`, and `cd ens && forge test` (fork tests against live ENSv2). Run the judge offline: `npm run judge -- --input fixtures/damage-admitted.json --provider mock`. Show the Base Sepolia `LeaseShare1155` compliance txs linked in [ARCHITECTURE §10](../ARCHITECTURE.md#10-deployments). |

---

## Optional CLI proofs

These `cast call` commands only simulate: they read state and send nothing. The ENS ones were re-checked against live Sepolia on Sat 2026-09-26 at 01:22 JST, and the issuer's derived-key reverts at 03:18 JST, after the role cleanup.

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
SUB=0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60        # RentoutsSubnames
RES=0xBB8A105f48Ac836F549eC0B6A1a45BB7BA0961E5        # PermissionedResolver
REG=0xD2D122000D4725a863376EcAe4220BC20590f382        # UserRegistry
ISSUER=0xF6048B190D178Fb6F0870c65CD2F7E06381713C4
ALICE=0x484811c8c967809bE644A89d677933c29fb9e936

# Resolution through ENSv2: prints 0x484811c8c967809bE644A89d677933c29fb9e936
cast resolve-name alice.rentouts.eth --rpc-url ${SEPOLIA_RPC_URL}

DNS=$(cast call ${SUB} "dnsName(string)(bytes)" alice --rpc-url ${SEPOLIA_RPC_URL})

# Key-scoped roles: the issuer MAY write rentouts.rating (prints 0x) ...
cast call ${RES} "setText(bytes,string,string)" ${DNS} rentouts.rating 5 --from ${ISSUER} --rpc-url ${SEPOLIA_RPC_URL}
# ... but NOT avatar: reverts 0x4b27a133 = EACUnauthorizedAccountRoles(uint256,uint256,address)
cast call ${RES} "setText(bytes,string,string)" ${DNS} avatar x --from ${ISSUER} --rpc-url ${SEPOLIA_RPC_URL}
# ... and alice can't forge her own record (same revert)
cast call ${RES} "setText(bytes,string,string)" ${DNS} rentouts.rating 5 --from ${ALICE} --rpc-url ${SEPOLIA_RPC_URL}
# ... and since the role cleanup, the issuer can't write escrow-derived keys directly either (same revert;
# also rentouts.disputes, rentouts.escrow, rentouts.rentPaid, rentouts.depositReturnRate). Only CredentialSync writes them.
cast call ${RES} "setText(bytes,string,string)" ${DNS} rentouts.leasesCompleted 9 --from ${ISSUER} --rpc-url ${SEPOLIA_RPC_URL}

# Soulbound: alice can't move her name
TOKEN=$(cast call ${REG} "getTokenId(uint256)(uint256)" $(cast keccak alice) --rpc-url ${SEPOLIA_RPC_URL} | cut -d' ' -f1)
# reverts 0xe58f6d5a = TransferDisallowed(uint256,address)
cast call ${REG} "unsafeTransfer(address,uint256,bytes)" 0x000000000000000000000000000000000000dEaD ${TOKEN} 0x --from ${ALICE} --rpc-url ${SEPOLIA_RPC_URL}
# reverts 0x54838f98 = TransferUnsafeUntilRegistryIsEmancipated()
cast call ${REG} "safeTransferFrom(address,address,uint256,uint256,bytes)" ${ALICE} 0x000000000000000000000000000000000000dEaD ${TOKEN} 1 0x --from ${ALICE} --rpc-url ${SEPOLIA_RPC_URL}

# Never expires: prints 18446744073709551615 (2^64 - 1)
cast call ${REG} "getExpiry(uint256)(uint64)" $(cast keccak alice) --rpc-url ${SEPOLIA_RPC_URL}
```

The AI arbiter and the gate can be checked the same way (with `ESCROW` and `ARB` from the pre-flight):

```bash
# A lease's ruling: (status, tenantBps, confidenceBps, proposedAt, deadline, rulingHash)
# status 0 NONE, 1 PROPOSED, 2 APPEALED, 3 EXECUTED, 4 HUMAN_RESOLVED
cast call ${ARB} "getRuling(uint256)((uint8,uint16,uint16,uint64,uint64,bytes32))" <leaseId> --rpc-url ${SEPOLIA_RPC_URL}
# The ruling file the judge saved after a confirmed --propose (from judge/). --verify recomputes rulingHash and
# inputHash; --onchain also compares the file with AIArbiter.getRuling(leaseId). The arbiter is lowercase in the name:
npm run judge -- --verify out/ruling-11155111-<aiArbiter>-<leaseId>.json --onchain
npm run judge -- --verify out/ruling-11155111-0xc3d50752a1f42cc54d3c90a1261779eef5bbdcb5-<leaseId>.json --onchain
# The human gate: must print WORLD = 0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa (the WorldIdV4Gate alice is registered on); 0 would mean open
cast call $(cast call ${ESCROW} "humanGate()(address)" --rpc-url ${SEPOLIA_RPC_URL}) "verifier()(address)" --rpc-url ${SEPOLIA_RPC_URL}
```

ENS gates the AI judge, shown live with simulations only (nothing is sent). Lease 1 is used as a placeholder id:

```bash
H=0x0000000000000000000000000000000000000000000000000000000000000001
# The judge key can't go around the relay: reverts 0x0d9ab13f = NotAgent()
cast call ${ARB} "propose(uint256,uint16,bytes32,uint16,string)" 1 5000 ${H} 9000 x --from ${JUDGE} --rpc-url ${SEPOLIA_RPC_URL}
# A wallet without judge.rentouts.eth is refused by the relay: reverts 0x04135e48 = NotEnsJudge(caller, holder = JUDGE)
cast call ${RELAY} "propose(uint256,uint16,bytes32,uint16,string)" 1 5000 ${H} 9000 x --from 0x000000000000000000000000000000000000dEaD --rpc-url ${SEPOLIA_RPC_URL}
# The name's holder gets through the relay to AIArbiter, which then checks the lease: reverts 0x7ead52b7 = NotDisputed(1, 0)
cast call ${RELAY} "propose(uint256,uint16,bytes32,uint16,string)" 1 5000 ${H} 9000 x --from ${JUDGE} --rpc-url ${SEPOLIA_RPC_URL}
```

### Optional: "revoke the judge's name, the AI is refused" (fork only)

**Never revoke `judge.rentouts.eth` on Sepolia.** Labels are single-use, so a revoked `judge` could never be issued again, and a new judge would need a new label and a new relay. Show the beat on a fork of the live chain instead. Rehearsed, both green (Sat 13:36 JST):

```bash
# From the repo root: a real lease on the live escrow goes to dispute; after revoke("judge") on the fork, the judge key's
# proposal through the live relay reverts NotEnsJudge(judge, 0), and the human still rules (resolveByHuman)
forge test --match-path test/EnsAgentRelay.fork.t.sol --match-test test_RevokingTheNameStopsTheAI -vvvv
# From ens/: the revoke empties judge.rentouts.eth and relay.judge(), and the label can't be registered again
forge test --match-path test/JudgeName.fork.t.sol --match-test test_RevokeOnForkEmptiesTheNameAndTheRelaysJudge -vvv
```

### Optional: live revoke (never on alice)

This sends real transactions, and labels are single-use, so pick a new label every time. It has not been rehearsed on Sepolia yet: rehearse it once before relying on it on camera.

```bash
LABEL=demo-revoke-1
# a throwaway holder derived from the label: no code, no key, no name yet
HOLDER=$(cast to-check-sum-address $(cast keccak ${LABEL} | cut -c1-42))
cast send ${SUB} "register(string,address)" ${LABEL} ${HOLDER} --account rentouts-issuer --rpc-url ${SEPOLIA_RPC_URL}
cast resolve-name ${LABEL}.rentouts.eth --rpc-url ${SEPOLIA_RPC_URL}                 # the holder
cast send ${SUB} "revoke(string,string)" ${LABEL} "demo" --account rentouts-issuer --rpc-url ${SEPOLIA_RPC_URL}
(cd app && npm run ens:smoke -- ${LABEL}.rentouts.eth)   # addr null, status "revoked", exits 1
```
