# World ID — plugging into the deployed HumanGate

The escrow is already live and does not need a redeploy. `RentEscrow.fundLease` asks `HumanGate.isVerified(tenant)`. The gate on Ethereum Sepolia (`0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd`) is **open** (`verifier == address(0)`). The gate owner turns proof-of-personhood on with one call:

```bash
cast send 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd \
  "setVerifier(address)" <WorldHumanVerifier> \
  --account rentouts-deployer --rpc-url sepolia
```

`WorldHumanVerifier` is that verifier. A tenant submits an IDKit **Orb** proof whose signal is their wallet. The contract checks it against the World ID Router (`verifyProof`, `groupId = 1`) and then `isVerified` returns true for that address. A nullifier can only be used once (one human, one verification for this action). The contract holds no tokens and cannot move escrow funds.

## Deploy (does not touch the escrow)

```bash
# WORLD_APP_ID must be the real IDKit app id from the World Developer Portal.
# WORLD_ACTION must be the action id configured there (default name: fund-lease).
export WORLD_APP_ID=app_staging_<from portal>
export WORLD_ACTION=fund-lease
forge script script/DeployWorldVerifier.s.sol --rpc-url sepolia \
  --account rentouts-deployer --broadcast
```

Default router is the Ethereum Sepolia World ID Router `0x469449f251692E0779667583026b5A1E99512157` (contract code confirmed on-chain 2026-09-26). Override with `WORLD_ID_ROUTER` only if World publishes a different address.

Until `setVerifier` is called, funding stays open. Setting the verifier back to `address(0)` opens the gate again. Leases that are already funded never consult the gate.

## What IDKit must send

`verify(account, root, nullifierHash, proof)` where `account` is the tenant wallet (the proof signal), and `root` / `nullifierHash` / `proof` come from IDKit for app id + action `fund-lease`. The external nullifier is derived in the constructor the same way World does: `hashToField(abi.encodePacked(hashToField(appId), action))`.
