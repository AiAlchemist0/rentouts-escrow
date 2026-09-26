# World ID 4.0 — live gate, alice registered

`HumanGate` `0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd` on Ethereum Sepolia points at `WorldIdV4Gate` `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa` (action `fund-lease-wallet`, alice registered) since Sat 12:42 JST: `setVerifier` tx `0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671`, block 11783640. From Sat 12:09 to 12:42 JST it pointed at the first `WorldIdV4Gate` `0x27052bD69b3d961940bCD093C21ba729b6c1B209`, now superseded. The table below is that first switch.

| | |
|---|---|
| `setVerifier` tx | `0x56b47b25c08ecec6022814b78273d2568bc7a8a4bea4eb6b4dda04180543e8ee` |
| Block | 11783482 |
| From | `0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE` |
| Action | `fund-lease` |
| RP signer | `0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA` |
| Registered wallets | 0 |

`fundLease` reverts `NotVerifiedHuman` until `register` lands for that tenant. Rollback is `setVerifier(address(0))` from the gate owner. Do not redeploy `RentEscrow`. `WorldHumanVerifier` is the unused World ID 3.0 path.

## Who registers alice

Alice `0x484811c8c967809bE644A89d677933c29fb9e936` (`alice.rentouts.eth`) is a Foundry keystore. She does not live in World App.

1. A human approves Proof of Human in World App. The IDKit signal is the wallet address they are binding, which can be alice even though the keystore is not the phone.
2. The backend sends that proof to `POST https://developer.world.org/api/v4/verify/rp_9152be24431cdfcd`. On `success: true`, the RP signer signs `(chainId 11155111, gate, actionHash, wallet, nullifier, deadline)`. It will not sign a wallet that was not the signal.
3. Anyone with Sepolia ETH submits `register`. Dean broadcasts it from `0x512983d428B10a0b2224442a891Ac9b9A3502c28`. Alice does not. One nullifier registers one wallet. The contract then returns `isVerified(alice) == true`, and alice's keystore can call `fundLease`.

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
export GATE=0x27052bD69b3d961940bCD093C21ba729b6c1B209
export ALICE=0x484811c8c967809bE644A89d677933c29fb9e936

cast send $GATE \
  "register(address,uint256,uint256,bytes)" \
  $ALICE $NULLIFIER $DEADLINE $SIGNATURE \
  --rpc-url $SEPOLIA_RPC_URL

cast call $GATE "isVerified(address)(bool)" $ALICE --rpc-url $SEPOLIA_RPC_URL
```

`$NULLIFIER`, `$DEADLINE`, and `$SIGNATURE` come from the backend after verify. The signature is EIP-191 over `keccak256(abi.encode(chainId, gate, actionHash, wallet, nullifier, deadline))`.

This iPhone already used its `fund-lease` nullifier (signal `rentouts-fund-lease`, never registered on-chain). The replacement action is `fund-lease-wallet` on a second gate. `HumanGate` has pointed at this second gate since Bektur's `setVerifier` (Sat 12:42 JST).

| | |
|---|---|
| Gate | `0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa` |
| Action | `fund-lease-wallet` (`action_v4_c64cfd41a8c538418a6a3bcc68194f1e`, production) |
| Deploy tx | `0xde17d046d4e00c95ac09af3fa4e29d4245ca0008ed2a36cbfdf81e053c161dfe` |
| Sourcify | exact match |
| Signal / tenant | `0x484811c8c967809bE644A89d677933c29fb9e936` |
| `register` tx | `0xdbbfc6dd08fdaa4da200b51e6515a7b60423a7c3f94feb06f4a3b28f65148908` (block 11783569) |
| `isVerified(alice)` | `true` on this gate |
| `setVerifier` | `0xcd93549e9a3a703be498b96bd6ad47afd46c1d332a637460f4b94e127eb86671` (block 11783640, Sat 12:42 JST), from `0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE` |

```bash
cast send 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd \
  "setVerifier(address)" 0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa \
  --account rentouts-deployer --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```
