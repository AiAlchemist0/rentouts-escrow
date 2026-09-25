# AI usage — ENS package (`ens/`)

Per ETHGlobal rules, this records where AI tools were used in this package.

| File(s) | Tool | How it was used |
|---|---|---|
| `docs/ens/HANDOFF.md`, `docs/ens/research/ensv2-docs-research.md` | Claude Code (cloud session) | Research + design brief for the ENSv2 track, written during the event. |
| `ens/src/interfaces/IENSv2.sol` | Claude Code (local) | Minimal interfaces transcribed from ENS `contracts-v2` source at tag `sepolia-deployment-2026-09-15`. |
| `ens/src/RentoutsSubnames.sol` | Claude Code (local), reviewed by Bektur | Contract drafted from the handoff design; logic and role wiring reviewed by the team. |
| `ens/test/RentoutsSubnames.fork.t.sol` | Claude Code (local) | Fork tests against live Sepolia ENSv2. |
| `ens/script/*`, `ens/scripts/ens.sh` | Claude Code (local) | Deploy/registration scripts, rehearsed on an anvil fork of Sepolia. |
| `ens/src/CredentialSync.sol`, `ens/test/CredentialSync.fork.t.sol`, `ens/test/EnsForkBase.sol` | Claude Code (local) | On-chain credential sync (escrow `tenantStats` -> `rentouts.*` records) and its fork tests; shared fork setup extracted from the existing test. The `credentialSync` / `sync` script phases were rehearsed on a local anvil fork of Sepolia with a mock escrow. |
| `ens/src/interfaces/IRentEscrow.sol` | (copied) | Verbatim copy of the team's escrow interface from the core escrow package. |
| review of `ens/src/RentoutsSubnames.sol` | Claude Code multi-agent review | Security, ENS-correctness and coverage review with adversarial verification; confirmed findings fixed (revoke record wipe, no expiry, single-use labels, ENSIP-15 label check, ENSIP-19 address, stricter tests). |

All on-chain transactions are sent by a team member from their own Foundry keystore.
