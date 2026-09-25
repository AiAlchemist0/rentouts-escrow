# AI usage — ENS package (`ens/`)

Per ETHGlobal rules, this records where AI tools were used in this package.

| File(s) | Tool | How it was used |
|---|---|---|
| `docs/ens/HANDOFF.md`, `docs/ens/research/ensv2-docs-research.md` | Claude Code (cloud session) | Research + design brief for the ENSv2 track, written during the event. |
| `ens/src/interfaces/IENSv2.sol` | Claude Code (local) | Minimal interfaces transcribed from ENS `contracts-v2` source at tag `sepolia-deployment-2026-09-15`. |
| `ens/src/RentoutsSubnames.sol` | Claude Code (local), reviewed by Bektur | Contract drafted from the handoff design; logic and role wiring reviewed by the team. |
| `ens/test/RentoutsSubnames.fork.t.sol` | Claude Code (local) | Fork tests against live Sepolia ENSv2. |
| `ens/script/*` | Claude Code (local) | Deploy/registration scripts. |

All on-chain transactions are sent by a team member from their own Foundry keystore.
