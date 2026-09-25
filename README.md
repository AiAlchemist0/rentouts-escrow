# RentOuts — On-Chain Rental Escrow (ETHGlobal Tokyo 2026)

> **Trust-minimized rental escrow** — part of [RentOuts](https://rentouts.co), a blockchain-powered rental marketplace. Deposits and rent are held in USDC by a smart contract (not a landlord), and released/refunded on agreed conditions. Built live at **ETHGlobal Tokyo 2026** (Sep 25–27).

**Status:** 🟢 Building during the event. Existing product (the RentOuts marketplace is live); the on-chain escrow + sponsor integrations here are the new hackathon work (Continuity Track).

## What's in this repo

| Path | What |
| --- | --- |
| `src/LeaseShare1155.sol` | **RWA lease-share token** — ERC-1155 tokenizing a lease/deposit with compliance-aware (allowlist) transfers |
| `test/LeaseShare1155.t.sol` | Foundry tests incl. a fuzz proving non-allowlisted recipients are always rejected |
| `script/DeployLeaseShare.s.sol` | Base Sepolia deploy script |

_Coming during the event: `RentEscrow.sol` (USDC escrow + World ID gate) and `RentoutsSubnames` (ENSv2 identity)._

---

## 🏦 Curvegrid — Best RWA Tokenization Project

**One-sentence summary:** RentOuts tokenizes a rental lease/deposit as an ERC-1155 real-world asset whose shares can only move between compliance-approved (allowlisted) wallets — the on-chain building block for fractional, transfer-restricted rental ownership.

- **What it does:** `LeaseShare1155` mints a share per lease (`tokenId == leaseId`). Every transfer — single **and batch** — runs through an allowlist check in the OZ v5 `_update` hook, so shares can only be received by KYC/eligibility-approved addresses — "compliance-aware transfer logic" for real-estate RWAs. Revoking an address blocks further transfers to it immediately.
- **How this maps to the product:** it's a minimal cut of RentOuts' Stage-3 investor surface (permissioned ERC-1155 lease shares + transfer agent, Reg D 506(c)/Reg S).
- **MultiBaas:** _(optional — TBD)_ we may register the deployed contract in MultiBaas and read balances via its REST API for the demo dashboard.
- **Deployed address (Base Sepolia):** _TBD — added after deploy_
- **MultiBaas feedback:** _TBD_

### Team
- [@AiAlchemist0](https://github.com/AiAlchemist0) (Dean) — contracts / RWA
- Bektur — ENS identity

---

## Setup & testing

Requires [Foundry](https://getfoundry.sh).

```bash
# 1. Install dependencies (OpenZeppelin v5)
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-commit

# 2. Build + test
forge build
forge test -vv
```

Expected: **12 passing** tests — mint/transfer/batch allowlist gating, revoke-mid-life, access control, and `testFuzz_TransferToRandom_RejectedUnlessAllowlisted` (256 runs) proving the compliance gate.

### Deploy to Base Sepolia

```bash
cp .env.example .env   # fill in PRIVATE_KEY (a fresh testnet EOA), RPC, Basescan key
source .env
forge script script/DeployLeaseShare.s.sol --rpc-url base_sepolia --broadcast --verify
```

## Links
- Product: https://rentouts.co
- Demo video: _coming soon (ETHGlobal submission)_

## License
[MIT](./LICENSE)
