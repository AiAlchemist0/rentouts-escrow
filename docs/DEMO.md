# Demo script (about 3 minutes)

A runnable script for the judge demo and the video. Everything happens on **Ethereum Sepolia** with **Circle test USDC**. How the pieces fit is in [ARCHITECTURE.md](./ARCHITECTURE.md).

The story: *a landlord leases to `alice.rentouts.eth` by name. Alice's money sits in a contract, not with RentOuts or the landlord. Rent unlocks period by period, the deposit comes back, and the finished lease lands on Alice's ENS credential, where any app can read it.*

---

## Cast

Three accounts in one MetaMask, switched between steps. The app follows whichever account is selected.

| Role | Account | Needs |
|---|---|---|
| **Tenant: alice** | `0x484811c8c967809bE644A89d677933c29fb9e936`, holds `alice.rentouts.eth` | ~0.01 Sepolia ETH, **≥ 1.5 test USDC** |
| **Landlord: deployer** | `0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE`, allowlisted on `LeaseShare1155` by `DeployEscrow` | ~0.02 Sepolia ETH |
| **Arbiter** | `0x798b01Cef62b889943Ce1D3C5011a755B297e486` | ~0.005 Sepolia ETH |

Two more addresses are only typed in, never connected:
- **Investor**: an address the share owner allowlists before the demo.
- **Stranger**: `0x000000000000000000000000000000000000dEaD`, which is not allowlisted.

<!-- VERIFY: alice's and the arbiter's keys are available in the demo MetaMask (alice was created as Foundry keystore rentouts-alice). -->
<!-- VERIFY: pick the investor address (a team-controlled EOA with no other demo role) and allowlist it in pre-flight. -->

**Demo lease terms:** deposit **0.20**, rent **0.10** per period, period **60** seconds, **3** periods. Alice prepays 0.50 USDC per lease, and each lease runs 3 minutes. (The app's defaults are larger: 0.25 / 0.20 / 120 s / 3.)

---

## Pre-flight (T-30 min)

1. **Funds.** Top up the three accounts with Sepolia ETH from the [ETHGlobal faucet](https://ethglobal.com/faucet), and alice with USDC from the ETHGlobal faucet (1 USDC per claim) or [Circle's faucet](https://faucet.circle.com).
2. **App.** From `app/`: `npm install`, then create `.env.local` from `.env.example` with `VITE_ESCROW_ADDRESS` and `VITE_CREDENTIAL_SYNC_ADDRESS`. Also set a private `VITE_SEPOLIA_RPC_URL` if you have one, because public RPCs rate-limit. Then run `npm run dev`. The footer should list every contract with a link and none marked "not configured".
   <!-- VERIFY: RentEscrow and CredentialSync addresses (not deployed at the time of writing); whether a hosted build URL replaces npm run dev. -->
3. **ENS is live.** `npm run ens:smoke` prints `getEnsAddress 0x4848…e936`, `rentouts.credential = "tenant/v1"` and `rentouts.status = "active"`.
4. **Allowlist the investor** (share owner = deployer):
   ```bash
   cast send <LEASE_SHARE_1155> "setAllowlist(address,bool)" <INVESTOR> true \
     --account rentouts-deployer --rpc-url ${SEPOLIA_RPC_URL}
   ```
5. **Pre-stage two leases.** Both use the demo terms; the landlord creates each and alice approves and funds it.
   - **Lease A** (for claim and close): fund it **at least 4 minutes before recording**, so its term has ended when you reach step 4.
   - **Lease B** (for the dispute): fund it any time before recording. It just needs to be `ACTIVE`.
6. **Sync alice once**, so her card shows real numbers before the demo adds to them: landlord, tab *Run the lease*, a closed lease, *Sync tenant's credential to ENS*.
7. **Browser tabs.** The app on `#identity`, the app on `?name=alice.rentouts.eth#identity` (her public credential), and Etherscan on the `RentEscrow` address.
8. **MetaMask** is on Sepolia with all three accounts imported. Start on **alice**.

---

## Script

| Time | Account | App tab | Do | The viewer sees |
|---|---|---|---|---|
| 0:00–0:15 | (any) | header, footer | One line of pitch: *"Rent held by a contract, not a company."* Scroll to the footer. | Every contract on Sepolia with an explorer link. `RentEscrow` has no owner, no admin and no fee. The arbiter is a test account (a Safe in production). |
| 0:15–0:40 | alice | **1 Claim your name** | Alice already has her name, so the tab shows her credential. | A card reading *Verified on-chain*: `alice.rentouts.eth` resolves to `0x4848…e936` with credential `tenant/v1`, plus her stats. All of it is read live through the ENSv2 Universal Resolver. Say: *soulbound (ENS refuses the transfer), revocable, and only RentOuts issuers can write `rentouts.*`*. |
| 0:40–1:10 | **landlord** | **2 Create a lease** | Tenant field: type `alice.rentouts.eth`. Enter the demo terms and click **Create lease**. | *"alice.rentouts.eth resolves to 0x4848…"* and her compact card, then a summary: *the tenant prepays 0.50 USDC*. After the tx: *Lease #N created*. 100 shares of lease #N go to the landlord, and a landlord who isn't allowlisted couldn't list at all. |
| 1:10–1:35 | **alice** | **3 Fund the lease** | Click **Approve 0.50 USDC**, then **Fund lease**. | Her USDC balance drops by 0.50, and *Lease funded. Rent starts unlocking now*. Only the contract can move that money from here on. |
| 1:35–2:05 | **landlord** | **4 Run the lease** | On **Lease A** (term over): click **Release … rent**, then **Close lease**. Then **Sync tenant's credential to ENS**. | Rent goes to the landlord, the deposit goes back to alice, and the state becomes *Closed*. After the sync, which the landlord can pay for because `sync` is permissionless, alice's card shows **Leases completed +1** and more rent paid. |
| 2:05–2:30 | **alice**, then **arbiter** | **4 Run the lease** | Alice clicks **Open dispute** on **Lease B**. Switch to the arbiter, leave the slider at 50 %, and click **Resolve dispute**. | *"Frozen until the arbiter resolves the dispute."* Then the payout: half of what is left goes to each side, and the lease closes. The arbiter can only split between these two parties. |
| 2:30–2:50 | **landlord** | **5 Lease shares** | Transfer 10 shares of lease #N to **the investor**, which succeeds. Then try the **stranger** `0x…dEaD`. | The first transfer goes through. For the second, the app warns *isn't on the compliance allowlist*, and the pre-flight simulation shows `NotAllowlisted` before MetaMask even opens. |
| 2:50–3:00 | (any) | `?name=alice.rentouts.eth` | Open alice's public credential link. | The same record, readable by any ENS-aware app. No RentOuts API is involved. |

**Lease #N**, created live at 0:40, keeps running after the video. Close it later, or leave it `ACTIVE` as a live example for judges.

---

## Fallbacks

| If… | Then… |
|---|---|
| A transaction hangs (Sepolia congestion) | Carry on with the pre-staged lease, and show the pending tx on Etherscan. |
| **Release rent** is disabled or says `NothingToClaim` | The next period hasn't elapsed yet (60 s). Talk through the countdown on the card. |
| **Close lease** is disabled | The term isn't over yet. Use Lease A, which was funded ≥ 4 min earlier. Only the landlord can close before `endTime + periodSeconds`. |
| `createLease` fails with `NotAllowlisted` | The landlord isn't on the share allowlist. Run `setAllowlist(<landlord>, true)` as the share owner, or use the deployer as the landlord. |
| `createLease` fails with `InvalidTerms` | Check that the period is ≥ 60 s, the tenant isn't the landlord, and neither is the arbiter. |
| Sync fails with `NotIssuer` | `CredentialSync` isn't an issuer. From `ens/`: `ESCROW_ADDRESS=<RentEscrow> BROADCAST=true ./scripts/ens.sh credentialSync`. |
| Sync fails with `NoName` | That tenant has no `rentouts.eth` name. Use alice. |
| The app shows *escrow not configured* | Set `VITE_ESCROW_ADDRESS` in `app/.env.local` and restart `npm run dev`. Meanwhile, demo steps 1 and 5 (ENS and shares) and show the test suites below. |
| Reads fail or show rate-limit errors | Point `VITE_SEPOLIA_RPC_URL` at a private Sepolia RPC. |
| MetaMask is on the wrong network | The app's banner offers a switch to Sepolia. |
| The ENS app doesn't show `alice.rentouts.eth` | Expected: it may not display ENSv2 beta names yet. Use the app's card, `npm run ens:smoke` or `cast resolve-name`. |
| Live chain unusable | Run `forge test` (root) and `cd ens && forge test` (fork tests against live ENSv2). Show the Base Sepolia `LeaseShare1155` compliance txs linked in [ARCHITECTURE §8](./ARCHITECTURE.md#8-deployments). |

---

## Optional CLI proofs

These `cast call` commands only simulate: they read state and send nothing. All of them were checked against live Sepolia on Fri 2026-09-25 at 23:10 JST.

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

# Soulbound: alice can't move her name
TOKEN=$(cast call ${REG} "getTokenId(uint256)(uint256)" $(cast keccak alice) --rpc-url ${SEPOLIA_RPC_URL} | cut -d' ' -f1)
# reverts 0xe58f6d5a = TransferDisallowed(uint256,address)
cast call ${REG} "unsafeTransfer(address,uint256,bytes)" 0x000000000000000000000000000000000000dEaD ${TOKEN} 0x --from ${ALICE} --rpc-url ${SEPOLIA_RPC_URL}
# reverts 0x54838f98 = TransferUnsafeUntilRegistryIsEmancipated()
cast call ${REG} "safeTransferFrom(address,address,uint256,uint256,bytes)" ${ALICE} 0x000000000000000000000000000000000000dEaD ${TOKEN} 1 0x --from ${ALICE} --rpc-url ${SEPOLIA_RPC_URL}

# Never expires: prints 18446744073709551615 (2^64 - 1)
cast call ${REG} "getExpiry(uint256)(uint64)" $(cast keccak alice) --rpc-url ${SEPOLIA_RPC_URL}
```

### Optional: live revoke (never on alice)

This sends real transactions, and labels are single-use, so pick a new label every time.

```bash
LABEL=demo-revoke-1
# a throwaway holder derived from the label: no code, no key, no name yet
HOLDER=$(cast to-check-sum-address $(cast keccak ${LABEL} | cut -c1-42))
cast send ${SUB} "register(string,address)" ${LABEL} ${HOLDER} --account rentouts-issuer --rpc-url ${SEPOLIA_RPC_URL}
cast resolve-name ${LABEL}.rentouts.eth --rpc-url ${SEPOLIA_RPC_URL}                 # the holder
cast send ${SUB} "revoke(string,string)" ${LABEL} "demo" --account rentouts-issuer --rpc-url ${SEPOLIA_RPC_URL}
(cd app && npm run ens:smoke -- ${LABEL}.rentouts.eth)   # addr null, status "revoked", exits 1
```

<!-- VERIFY: the live revoke block has not been rehearsed on Sepolia (register / revoke / smoke output); rehearse once before relying on it on camera. -->
