# AI usage

ETHGlobal asks teams to say where and how AI tools were used, down to files and parts. Teams that work from specs must also commit their spec and planning artifacts. This is our disclosure for the whole repo. The ENS package keeps a per-file table in [`ens/AI_USAGE.md`](./ens/AI_USAGE.md).

## Tools

| Tool | Used for |
| --- | --- |
| **Claude Code** (Anthropic, Claude Opus 5.5) | Drafting contracts, tests, deploy scripts, the judge service, the demo app and docs (which parts: see the table below). Also research, anvil-fork rehearsals of deploys, and multi-agent code reviews with adversarial verification of each finding. |
| **Codex CLI** (OpenAI, gpt-6-astra) | Independent code review of each package before merging. |
| Additional Claude reviewer agents (Fable model) | Second-opinion reviews focused on security, ENS semantics, tests and ops ([`docs/ens/LOG.md`](./docs/ens/LOG.md), Sat 01:05 and 03:35). |

AI co-authorship is recorded in the git history. Every non-merge commit authored by Bektur ends with a `Co-Authored-By: Claude Opus 5.5` trailer. One commit is authored by `Claude` itself: the ENS research and design brief, written by a Claude Code cloud session.

## Where, by area

| Area | Files | Written by |
| --- | --- | --- |
| Escrow, human gate, AI arbiter | `src/RentEscrow.sol`, `src/HumanGate.sol`, `src/AIArbiter.sol`, `src/interfaces/`, `test/RentEscrow*`, `test/HumanGate.t.sol`, `test/AIArbiter*`, `script/DeployEscrow.s.sol`, `script/DeployAIArbiter.s.sol` | Bektur with Claude Code (drafting, tests, review fixes) |
| ENS identity | `ens/` (see [`ens/AI_USAGE.md`](./ens/AI_USAGE.md)) | Bektur with Claude Code |
| AI dispute judge service | `judge/` | Bektur with Claude Code |
| Demo app | `app/` | Bektur with Claude Code |
| Lease shares (RWA) | `src/LeaseShare1155.sol`, `test/LeaseShare1155.t.sol`, `script/DeployLeaseShare.s.sol` | Dean. His PRs were squash-merged, so the history has no per-commit AI trailer. _Dean to confirm the tools used._ |
| World ID | `src/WorldIdV4Gate.sol`, `src/WorldHumanVerifier.sol`, their tests and deploy scripts, `docs/WORLD.md`, `docs/BEKTUR-WORLD-V4.md` | Dean (squash-merged PRs #9–#11). _Dean to confirm the tools used._ |
| Docs | `README.md`, `ARCHITECTURE.md`, `docs/` | Bektur's sections drafted and fact-checked with Claude Code. Dean's sections (lease shares, World ID) are covered by the two rows above. |

**Planning artifacts in this repo:** [`docs/ens/HANDOFF.md`](./docs/ens/HANDOFF.md) (the ENS design brief), [`docs/ens/research/ensv2-docs-research.md`](./docs/ens/research/ensv2-docs-research.md), [`docs/PLAN.md`](./docs/PLAN.md), [`docs/DECISIONS.md`](./docs/DECISIONS.md) and the running build log [`docs/ens/LOG.md`](./docs/ens/LOG.md).

## What the humans did

- **Design decisions** were made by the team. Examples: one chain, Circle USDC, a soulbound and revocable ENS name, a split-only arbiter, an AI that only proposes, no redeploy after the reviews. They are recorded as team decisions in [`docs/ens/LOG.md`](./docs/ens/LOG.md) and [`docs/DECISIONS.md`](./docs/DECISIONS.md).
- **Every deployment and on-chain transaction** was signed by a team member with their own key:
  - The escrow, arbiter and ENS stack on Ethereum Sepolia used Foundry keystores. Bektur ran each broadcast and typed the keystore password himself.
  - Dean deployed `LeaseShare1155` on Base Sepolia and `WorldIdV4Gate` from his own testnet key.
  - No key or password is in this repo.
- **Every change** after the three setup commits reached `main` through a pull request (#1–#11), merged by a team member.

## AI inside the product

The dispute judge ([`judge/`](./judge/README.md)) calls **z.ai GLM 5.3** at run time. A deterministic mock provider runs without an API key.

**What the model does:**
- It answers a fixed checklist of yes/no questions, each with a probability, about a disputed lease.
- Code, not the model, turns those answers into a split.
- The judge abstains, handing the case to the human, when evidence or confidence is too low or a statement tries to steer it.

**What the model can't do:**
- It can only *propose*. [`AIArbiter`](./src/AIArbiter.sol) holds the proposal for a challenge window, either party can appeal, and a human arbiter can rule or override at any time.
- The agent key can only call `propose`, and the arbiter contract can only split one disputed lease's escrow between that lease's own tenant and landlord.
- The judge's agent key is a Foundry keystore, unlocked by a person at run time (`--propose` prompts for the password).
