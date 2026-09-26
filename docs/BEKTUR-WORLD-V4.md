# Bektur: turn on World ID 4.0 for `fundLease`

Dean cannot finish this. `HumanGate` is owned by your deployer `0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE`. Only that key can call `setVerifier`. Do **not** redeploy `RentEscrow`.

## What this is

World App issues **World ID 4.0** proofs. `WorldHumanVerifier` checks World ID **3.0** and must not be used. There is no World ID 4.0 zk verifier on Ethereum Sepolia (`WorldIDVerifier` is on World Chain).

`WorldIdV4Gate` is the contract that matches the phone:

1. The iPhone approves Proof of Human for action `fund-lease`.
2. World accepts it at `POST /api/v4/verify/rp_9152be24431cdfcd` (app `app_2432bfa166623cfbbf813744d0b4b00c`).
3. The RP signer `0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA` signs `(chainId, gate, actionHash, wallet, nullifier, deadline)`.
4. Anyone submits `register`. `isVerified(wallet)` becomes true. The nullifier cannot be reused.
5. You point the live gate at that contract. After that, `fundLease` reverts `NotVerifiedHuman` for every other wallet.

ENS, `LeaseShare1155`, and `AIArbiter` do not change.

## What you run, after Dean deploys

`WorldIdV4Gate` is already deployed and Sourcify-verified:

**`0x27052bD69b3d961940bCD093C21ba729b6c1B209`**

Deploy tx: `0xf6009731cf6bd6431914961d33746cc7bfc8cd626e730f31df0f333d0a6a199c`. Signer is `0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA`. Action is `fund-lease`. You do not need to deploy it.

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com

# 1. Confirm you are the gate owner (must print your deployer).
cast call 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd "owner()(address)" --rpc-url $SEPOLIA_RPC_URL

# 2. Turn the gate on. This is the only transaction that needs your key.
cast send 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd \
  "setVerifier(address)" 0x27052bD69b3d961940bCD093C21ba729b6c1B209 \
  --account rentouts-deployer --rpc-url $SEPOLIA_RPC_URL

# 3. Confirm. Must equal <WorldIdV4Gate>, not address(0).
cast call 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd "verifier()(address)" --rpc-url $SEPOLIA_RPC_URL
```

To turn it back off for the rest of the demo: `setVerifier(address(0))`.

## If Dean has not deployed yet

The contract and tests are in PR #11 (`src/WorldIdV4Gate.sol`, 6 Foundry tests passing). Deploy args:

- signer: `0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA` (RP signer, not your deployer)
- action string: `fund-lease`

```bash
export WORLD_ID_SIGNER=0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA
export WORLD_ACTION=fund-lease
forge script script/DeployWorldIdV4Gate.s.sol --rpc-url sepolia \
  --account rentouts-deployer --broadcast
```

Then do step 2 above with the printed address.

## Do not

- Do not redeploy `RentEscrow`, `HumanGate`, ENS, or `AIArbiter`.
- Do not call `setVerifier` with `WorldHumanVerifier`.
- Do not put the RP signing private key in git. Dean has it in `~/.rentouts-world.env` on his Mac.
