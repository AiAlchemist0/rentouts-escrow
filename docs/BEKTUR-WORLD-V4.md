# Bektur: HumanGate points at the wallet gate

`setVerifier` tx `0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671`, block 11783640, from `0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE`. `HumanGate` `0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd` `verifier()` is `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`. `isVerified(alice 0x484811c8c967809bE644A89d677933c29fb9e936)` is `true`. The first gate `0x27052bD69b3d961940bCD093C21ba729b6c1B209` (action `fund-lease`) is superseded and unused. Rollback is `setVerifier(address(0))` from your deployer. Do **not** redeploy `RentEscrow`.

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

This iPhone already spent its one `fund-lease` nullifier, so alice cannot be registered on `0x27052bD6…B209`. The replacement is deployed and Sourcify-exact:

**`0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`**

Action `fund-lease-wallet`. Deploy tx `0xde17d046d4e00c95ac09af3fa4e29d4245ca0008ed2a36cbfdf81e053c161dfe`. Same RP signer. Alice is registered. Tx `0xdbbfc6dd08fdaa4da200b51e6515a7b60423a7c3f94feb06f4a3b28f65148908`, block 11783569. Your switch tx is `0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671`. `HumanGate` now points here, so alice can `fundLease` and an unregistered wallet still cannot.

## Already on-chain

Superseded `WorldIdV4Gate` `0x27052bD69b3d961940bCD093C21ba729b6c1B209` (action `fund-lease`, deploy tx `0xf6009731cf6bd6431914961d33746cc7bfc8cd626e730f31df0f333d0a6a199c`) is unused. The live gate is `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa`. Signer on both is `0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA`.

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
