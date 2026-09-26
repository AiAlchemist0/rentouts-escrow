# ENSv2 developer feedback (RentOuts, ETHGlobal Tokyo 2026)

Feedback for the ENS team from building on the **ENSv2 beta on Ethereum Sepolia**, contracts-v2 tag `sepolia-deployment-2026-09-15`. Everything below comes from what we built and ran. The timestamped record, with transaction hashes, is in [`LOG.md`](./LOG.md). The code is in [`ens/`](../../ens/README.md).

## What we built

Tenants get a soulbound `<name>.rentouts.eth`. Its `rentouts.*` text records carry a rental track record, and any app reads it through the Universal Resolver.

- **Registration:** `rentouts.eth` via `ETHRegistrar` commit/reveal, fee paid in ENS's MockUSDC.
- **Our proxies:** a `UserRegistry` and a `PermissionedResolver`, both deployed through `VerifiableFactory`.
- **Controller:** our `RentoutsSubnames` contract holds EAC roles on both proxies.
- **Credential sync:** a permissionless `CredentialSync` writes the track record from our escrow contract's on-chain stats.

The live `alice.rentouts.eth` resolves `addr` and `rentouts.credential` through the Universal Resolver.

**Tooling:**
- Foundry 1.8.3, with minimal interfaces vendored from the tag (`ens/src/interfaces/IENSv2.sol`).
- viem 2.56 in the app.
- 42 fork tests that run against the live Sepolia deployment.

**Time to first success:** under an hour. The first ENS code commit was Fri 21:39 JST. By 22:24 JST `alice.rentouts.eth` resolved on live Sepolia.

**Cost:** the whole ENS setup took 21 transactions and 0.004483 ETH. That covers the proxies, commit, fee, register, `RentoutsSubnames` with its role grants, and the parent profile.

---

## What worked really well

**1. `UserRegistry` + `PermissionedResolver` through `VerifiableFactory`.**
- It takes a few lines to deploy your own registry and resolver proxies with a `Grant[]` initializer. After that, `setSubregistry` on the `.eth` registry makes the subtree yours.
- We didn't have to write or audit a registry. Our contract is a thin controller that holds roles.
- This is the right shape for "an app issues names under its own parent".

**2. Key-scoped setter roles (`grantSetterRoles`).** This is the feature our design rests on.
- Our issuer account can write `rentouts.onTimeRate`, `rentouts.rating` and `rentouts.verified`, but **not** `avatar`. ENS enforces that, not our code.
- We checked it live: `roles(keccak256(key), issuer)` returns `16` (`SET_TEXT`) on the three judged keys and `0` everywhere else.
- It lets us say "only RentOuts can write the credential, and RentOuts can't touch your profile" without a custom resolver.

**3. Soulbound through an empty token role bitmap.**
- Registering with `roleBitmap = 0` means the holder never gets `ROLE_CAN_TRANSFER_ADMIN`, and admin roles can't be added later. So non-transferability comes from ENS itself.
- On live Sepolia, `unsafeTransfer` from alice reverts `TransferDisallowed`.
- Keeping `ROLE_UNREGISTER` on the registry root keeps names revocable. That also makes the registry unemancipated, which blocks ERC-1155 safe transfers too.

**4. `linkToRecord(name, 0)` as a record wipe.**
- When we revoke a credential, one call detaches the old record: addresses, credential, issuer stats and profile.
- The next `setText` then allocates a fresh record that holds only `rentouts.status=revoked`.
- It was the cleanest way we found to make revocation real on a shared resolver (see friction point 5).

**5. ENSIP-19 default EVM address (`coinType 0x80000000`).**
- One record answers coin 60 and every EVM chain.
- We checked `addr(node, 0x80000000 | 84532)` for Base Sepolia on the live name, and it returns alice's address with no extra write.

**6. Universal Resolver + viem.**
- Reads are plain `getEnsAddress` / `getEnsText`, and the Universal Resolver handles wildcard and "deepest resolver" resolution.
- There's no RentOuts API in the read path, which is the point of putting the credential on ENS.

**7. Test-friendliness.** The deployed contracts are easy to fork-test.
- Our suite deploys fresh proxies against the live registry in `setUp`.
- It registers a parent via commit/reveal inside the fork, then exercises roles, transfers and revocation.

---

## Friction we hit, and what would help

**1. Commit/reveal timing: `MIN_COMMITMENT_AGE` is checked against the latest block, not the wall clock.**
- The minimum age is 60 s, but a register sent 65 s after the commit can still fail, because Sepolia blocks are about 12 s apart.
- We caught this in an anvil-fork rehearsal. Our wrapper now waits **90 s** (`ens/scripts/ens.sh`, `wait_commit`).
- *Suggestion:* document "wait until a block with `timestamp >= commitTime + MIN_COMMITMENT_AGE` exists". Better still, add a view that returns when a commitment becomes usable, so scripts can poll instead of sleeping.

**2. Two different transfer reverts, and the one you see first isn't the soulbound one.**
- On an unemancipated registry, `safeTransferFrom` reverts `TransferUnsafeUntilRegistryIsEmancipated` before the role check runs. Only `unsafeTransfer` reaches `TransferDisallowed`, which is the real soulbound gate.
- Our first soulbound test asserted on `safeTransferFrom`. It would have passed even if the token were transferable. A review caught it, and the test now uses `unsafeTransfer` plus a positive control, a token registered *with* `ROLE_CAN_TRANSFER_ADMIN` that does move.
- *Suggestion:* the EAC docs could list which transfer checks run in which order. A `canTransfer(tokenId, from)` view would also help.

**3. EIP-7702-delegated EOAs can't receive ERC-1155 name tokens.**
- Foundry's stock test address `makeAddr("alice")` (`0x3288…`) has a 7702 delegation (`0xef0100…`) on Sepolia to a contract that doesn't accept ERC-1155. The registry refused to mint to it.
- We switched the tests to unique addresses. The app now warns before a claim when the connected account has code.
- This will reach real users as wallets upgrade EOAs to smart accounts.
- 7702 also blurs our ENSIP-19 rule. We write the default EVM record only when `holder.code.length == 0` and fall back to coin 60 for contracts, so a 7702-upgraded EOA only gets coin 60.
- *Suggestions:*
  - a docs note on 7702 and name tokens;
  - a clear revert reason when the receiver hook fails;
  - guidance on which address records to write for delegated EOAs.

**4. Labels are effectively single-use in a registry.**
- Once a label has been registered, `getExpiry(labelId)` never goes back to 0, even after `unregister`.
- We use that as the only on-chain signal that survives both `unregister` and a redeploy of our controller. A label that was used once is refused (`LabelTaken` / `LabelRetired`).
- We do this so a new holder can't inherit the old holder's records on a shared resolver.
- *Suggestion:* document what state survives `unregister`, such as expiry and records in a shared resolver. A per-label generation counter would let an app reuse labels safely.

**5. After `unregister`, a name on a shared resolver keeps resolving.**
- Subnames and their parent share one `PermissionedResolver`. After `unregister`, the Universal Resolver falls back to the parent's resolver, which still holds the subname's records.
- So a revoked credential kept resolving `addr` and `rentouts.*` until we added the `linkToRecord(name, 0)` wipe (a review finding, fixed before our deploy).
- *Suggestion:* flag this in the registry-hierarchy and Permissioned Resolver docs as a "revocation checklist". An optional "clear records on unregister" pattern would also help.

**6. Setter roles are scoped by key, not by name.**
- `grantSetterRoles` scopes a role to a text key on **every** name the resolver serves. That includes the parent and the resolver's default record (name `0x00`), which every unregistered `*.rentouts.eth` falls back to.
- Our issuer can therefore write its three keys anywhere on that resolver. It still can't write `addr`, `rentouts.status` or `rentouts.credential`, which need root roles.
- We handle it in the app: it shows `rentouts.*` only when `status == active`, `addr` matches, and our contract's `labelOf(tenant)` matches ([Known limitations](../../ens/README.md#known-limitations-and-operations)).
- *Suggestion:* a (name or subtree) × key scope would let an issuer write credentials only on names it issued.

**7. Upgrade roles come with `ALL_ROLES`.**
- Following the docs' examples, our setup grants the deployer `ALL_ROLES` in `initialize`. That includes `ROLE_UPGRADE` on both proxies, along with root `ROLE_LINK` and `ROLE_UNREGISTER`.
- So "soulbound" and "only issuers write" hold only while that one key is honest. We documented a handover to a Safe for later.
- *Suggestion:* publish recommended bitmaps for common setups, such as "operator without upgrade". Also add a short recipe for renouncing `ROLE_UPGRADE` once setup is done.

---

## Docs and tooling gaps

We wrote these down while getting started. The research notes are in [`research/ensv2-docs-research.md`](./research/ensv2-docs-research.md).

**The app-developer tutorial doesn't match the deployed contract.**
- The tutorial's write examples use `setText(bytes32 node, …)` and `authorize*Roles`.
- The deployed `PermissionedResolver` takes a DNS-encoded name (`setText(bytes name, …)`) and uses `grantSetterRoles`. The Permissioned Resolver reference page is correct.

**Pinning the contracts is left to the reader.**
- The docs install the contracts with `forge install ensdomains/contracts-v2`, which tracks the default branch rather than the deployed tag.
- We pinned to `sepolia-deployment-2026-09-15` and vendored about 30 lines of interfaces instead of compiling the contracts-v2 tree. A tag-pinned install line next to the Sepolia address table would help.

**ENSjs:**
- `@ensdomains/ensjs@latest` on npm has no ENSv2 Sepolia addresses.
- The v5 preview's Sepolia addresses predate the 2026-09-15 redeploy.
- On ensjs `main`, the registrar actions look up a contract key `ethRegistrar`, but the Sepolia config names it `ensEthRegistrar`.
- We wrote with Foundry scripts and vendored interfaces, and read with viem in the app.

**Resets:**
- The Sepolia beta is redeployed every few weeks, and names registered before a redeploy don't carry over. We kept every ENS address in one file (`ens/script/EnsSepolia.sol`) so a redeploy means bumping one file and re-running the phases.
- An announced redeploy calendar, or a guarantee of no reset during a hackathon weekend, would take out the biggest risk in building on the beta.

**v1 registration is off on Sepolia.** We confirmed that `BaseRegistrar.controllers(<v1 controller>)` is false, so v2 is the only path for a new name. That's fine, but a one-line notice at the top of the Sepolia v1 docs would save people time.

## What we'd like next

1. Setter roles scoped by name or subtree as well as by key (friction point 6).
2. A documented revocation pattern for shared resolvers, or a built-in record clear on `unregister` (points 4 and 5).
3. Guidance, and ideally a clearer revert, for EIP-7702-delegated holders of name tokens (point 3).
4. A commitment-readiness view on `ETHRegistrar` (point 1).
5. ENSjs v5 on npm with the current Sepolia addresses, and an updated app-developer tutorial.
6. Confirmation that app.ens.dev and explorer.ens.dev show subnames from a custom `UserRegistry` together with custom text keys such as `rentouts.*`. We haven't confirmed this yet.

Thanks to the ENS team: key-scoped EAC roles plus the Universal Resolver made "a credential only the issuer can write, readable by any app" possible without a custom resolver or an off-chain API.
