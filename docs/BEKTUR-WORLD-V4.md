# Bektur: World ID 4.0 is on, and no wallet is registered yet

`setVerifier` is done. Tx `0x56b47b25c08ecec6022814b78273d2568bc7a8a4bea4eb6b4dda04180543e8ee`, block 11783482, from `0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE`. `HumanGate` `0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd` `verifier()` is `0x27052bD69b3d961940bCD093C21ba729b6c1B209`. `WorldIdV4Gate` has zero `HumanRegistered` events, so every `fundLease` reverts `NotVerifiedHuman`, including alice. Rollback is `setVerifier(address(0))` from your deployer. Do **not** redeploy `RentEscrow`.

## What this is

World App issues **World ID 4.0** proofs. `WorldHumanVerifier` checks World ID **3.0** and must not be used. There is no World ID 4.0 zk verifier on Ethereum Sepolia (`WorldIDVerifier` is on World Chain).

`WorldIdV4Gate` is the contract that matches the phone:

1. The iPhone approves Proof of Human for action `fund-lease`.
2. World accepts it at `POST /api/v4/verify/rp_9152be24431cdfcd` (app `app_2432bfa166623cfbbf813744d0b4b00c`).
3. The RP signer `0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA` signs `(chainId, gate, actionHash, wallet, nullifier, deadline)`.
4. Anyone submits `register`. `isVerified(wallet)` becomes true. The nullifier cannot be reused.
5. You already pointed the live gate at that contract. `fundLease` reverts `NotVerifiedHuman` until that wallet is `register`ed.

ENS, `LeaseShare1155`, and `AIArbiter` do not change.

## How alice gets registered

Alice `0x484811c8c967809bE644A89d677933c29fb9e936` does not need to exist in World App. World App proves a human. The backend then attests **one wallet address that human approved as the signal**. That address can be a Foundry keystore. One World ID nullifier can be registered to one wallet, and the contract rejects that nullifier after that.

The contract does not read the zk proof. It trusts the RP signer `0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA`. That signer will only sign after `POST /api/v4/verify/rp_9152be24431cdfcd` returns `success: true` for action `fund-lease` and signal equal to the wallet. Anyone with Sepolia ETH can then submit `register`. Alice does not send that transaction. She sends `fundLease` later, from the keystore.

Dean runs the phone flow and the `register` broadcast from `0x512983d428B10a0b2224442a891Ac9b9A3502c28`. You do not sign it.

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
export GATE=0x27052bD69b3d961940bCD093C21ba729b6c1B209
export ALICE=0x484811c8c967809bE644A89d677933c29fb9e936

# After the backend prints nullifier, deadline, and signature:
cast send $GATE \
  "register(address,uint256,uint256,bytes)" \
  $ALICE $NULLIFIER $DEADLINE $SIGNATURE \
  --account rentouts-deployer --rpc-url $SEPOLIA_RPC_URL

cast call $GATE "isVerified(address)(bool)" $ALICE --rpc-url $SEPOLIA_RPC_URL
# must print true before alice calls fundLease
```

This iPhone already spent its one `fund-lease` nullifier on 2026-09-26 (signal was the text `rentouts-fund-lease`, and that proof was never submitted on-chain). World App now returns `nullifier_replayed` for the same person and the same action. A second human who has not proved `fund-lease` can register alice with the command above. Registering this same phone requires a new action string, a new `WorldIdV4Gate`, and one more `setVerifier` from you.

## Already on-chain

`WorldIdV4Gate` `0x27052bD69b3d961940bCD093C21ba729b6c1B209` is Sourcify-verified. Deploy tx `0xf6009731cf6bd6431914961d33746cc7bfc8cd626e730f31df0f333d0a6a199c`. Signer `0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA`. Action `fund-lease`. Your `setVerifier` tx is `0x56b47b25c08ecec6022814b78273d2568bc7a8a4bea4eb6b4dda04180543e8ee`.

Rollback, from your deployer only:

```bash
cast send 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd \
  "setVerifier(address)" 0x0000000000000000000000000000000000000000 \
  --account rentouts-deployer --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

## Do not

- Do not redeploy `RentEscrow`, `HumanGate`, ENS, or `AIArbiter`.
- Do not call `setVerifier` with `WorldHumanVerifier`.
- Do not put the RP signing private key in git. Dean has it in `~/.rentouts-world.env` on his Mac.
