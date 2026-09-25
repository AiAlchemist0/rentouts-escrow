#!/usr/bin/env bash
# RentOuts ENSv2 setup on Ethereum Sepolia. Run from ens/:  ./scripts/ens.sh <phase>
#
#   ./scripts/ens.sh status            read-only report (no signer needed)
#   ./scripts/ens.sh parent            infra -> commit -> wait 65s -> register   (sends txs)
#   ./scripts/ens.sh subnames          deploy RentoutsSubnames + wire roles      (sends txs)
#                                      refuses an ENS_ISSUER that removeIssuer removed, unless
#                                      ENS_REINSTATE_ISSUER=<that address>
#   ./scripts/ens.sh profile           parent records from ENS_PROFILE_*         (sends txs)
#   ./scripts/ens.sh claim             mint ENS_DEMO_LABEL to ENS_DEMO_HOLDER    (sends txs)
#   ./scripts/ens.sh all               parent + subnames + profile + claim
#   ./scripts/ens.sh removeIssuer      disable ENS_REMOVE_ISSUER (contract + resolver roles) and record it
#                                      so subnames/all won't grant it back   (sends txs)
#   ./scripts/ens.sh credentialSync    deploy/reuse CredentialSync(ESCROW_ADDRESS), make it an issuer, retire
#                                      older ones (sends txs), then finalize
#   ./scripts/ens.sh finalize          record a pending CredentialSync once the chain confirms it (no txs)
#   ./scripts/ens.sh sync              CredentialSync.sync(ENS_SYNC_TENANT), permissionless    (sends txs)
#
# Sends nothing unless BROADCAST=true. Without it every phase is a dry-run simulation.
# Signs with the Foundry keystore account $FOUNDRY_ACCOUNT (default rentouts-deployer):
# forge prompts for its password. Never put a private key in .env or on the command line.
#
# Local rehearsal on an anvil fork of Sepolia: RPC_OVERRIDE=http://127.0.0.1:8545 (UNLOCKED=1 signs with
# anvil's unlocked accounts, LOCAL_MINE=1 moves the fork's clock). The fork keeps chain id 11155111, so
# receipts go to broadcast-local/ and state to deployments/local.json (seeded from sepolia.json). The
# committed live receipts in broadcast/ and deployments/sepolia.json are never written.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

: "${SEPOLIA_RPC_URL:?set SEPOLIA_RPC_URL}"
: "${ENS_PARENT_LABEL:?set ENS_PARENT_LABEL (e.g. rentouts)}"
: "${DEPLOYER:?set DEPLOYER to the address of your keystore account (cast wallet address --account rentouts-deployer)}"
ACCOUNT="${FOUNDRY_ACCOUNT:-rentouts-deployer}"
BROADCAST="${BROADCAST:-false}"
export BROADCAST

if [ -n "${RPC_OVERRIDE:-}" ] || [ -n "${UNLOCKED:-}" ]; then
  : "${RPC_OVERRIDE:?UNLOCKED is for a local anvil fork: set RPC_OVERRIDE too}"
  export FOUNDRY_BROADCAST=broadcast-local
  ENS_STATE="${ENS_STATE:-deployments/local.json}"
  case "$ENS_STATE" in
    *sepolia.json) echo "RPC_OVERRIDE is set: refusing to write the live state file $ENS_STATE"; exit 1 ;;
  esac
  if [ ! -f "$ENS_STATE" ] && [ -f deployments/sepolia.json ]; then
    cp deployments/sepolia.json "$ENS_STATE"
    echo ">> seeded $ENS_STATE from deployments/sepolia.json"
  fi
  export ENS_STATE
  echo ">> local rehearsal: RPC $RPC_OVERRIDE, receipts -> $FOUNDRY_BROADCAST/, state -> $ENS_STATE"
fi
RPC="${RPC_OVERRIDE:-$SEPOLIA_RPC_URL}"

phase() {
  local sig="$1"
  local args=(script script/DeployEns.s.sol:DeployEns --sig "${sig}()" --rpc-url "$RPC" --sender "$DEPLOYER")
  if [ "$BROADCAST" = "true" ]; then
    if [ -n "${UNLOCKED:-}" ]; then args+=(--unlocked --broadcast); else args+=(--account "$ACCOUNT" --broadcast); fi
    args+=(--slow)
  fi
  echo ">> forge ${args[*]}"
  forge "${args[@]}"
}

# Reads the chain and writes only the state file (when BROADCAST=true): no transactions, no keystore prompt.
state_phase() {
  local args=(script script/DeployEns.s.sol:DeployEns --sig "${1}()" --rpc-url "$RPC" --sender "$DEPLOYER")
  echo ">> forge ${args[*]}"
  forge "${args[@]}"
}

# Forge writes the state file while it simulates, before sending anything, so credentialSync records its
# contract as pending. Once the broadcast has succeeded, promote it (retrying while the RPC catches up).
finalize_sync() {
  [ "$BROADCAST" = "true" ] || return 0
  local i
  for i in 1 2 3 4; do
    state_phase finalizeCredentialSync && return 0
    if [ "$i" -lt 4 ]; then echo ">> not visible on the RPC yet; retrying in 15s"; sleep 15; fi
  done
  echo "CredentialSync not confirmed. Re-run: BROADCAST=true ./scripts/ens.sh credentialSync (it reconciles what landed)"
  return 1
}

# The registrar needs the commitment >= 60s old *in the latest block* (Sepolia blocks are ~12s apart),
# so wait well past 60s. LOCAL_MINE=1 (anvil rehearsal) mines a block so the fork's clock moves.
wait_commit() {
  if [ "$BROADCAST" = "true" ]; then
    local secs="${COMMIT_WAIT_SECS:-90}"
    if [ "${LOCAL_MINE:-0}" = "1" ]; then
      echo ">> (local fork) advancing the chain clock ${secs}s"
      cast rpc evm_increaseTime "$secs" --rpc-url "$RPC" >/dev/null
      cast rpc evm_mine --rpc-url "$RPC" >/dev/null
    else
      echo ">> waiting ${secs}s for the ENS commitment to mature"; sleep "$secs"
    fi
  fi
}

need_issuer() {
  : "${ENS_ISSUER:?set ENS_ISSUER to a SECOND account (not DEPLOYER), e.g. cast wallet address --account rentouts-issuer}"
  [ "$(echo "$ENS_ISSUER" | tr A-F a-f)" != "$(echo "$DEPLOYER" | tr A-F a-f)" ] || { echo "ENS_ISSUER must differ from DEPLOYER"; exit 1; }
}

case "${1:-status}" in
  status)   phase status ;;
  infra)    phase infra ;;
  commit)   phase commit ;;
  register) phase register ;;
  parent)   phase infra; phase commit; wait_commit; phase register ;;
  subnames) need_issuer; phase subnames ;;
  profile)  phase profile ;;
  claim)    phase claim ;;
  removeIssuer)
    : "${ENS_REMOVE_ISSUER:?set ENS_REMOVE_ISSUER to the issuer address to disable}"; export ENS_REMOVE_ISSUER
    phase removeIssuer ;;
  credentialSync)
    : "${ESCROW_ADDRESS:?set ESCROW_ADDRESS to the RentEscrow on Sepolia}"; export ESCROW_ADDRESS
    phase credentialSync; finalize_sync ;;
  finalize) state_phase finalizeCredentialSync ;;
  sync)
    : "${ENS_SYNC_TENANT:?set ENS_SYNC_TENANT to the tenant address (must hold a rentouts name)}"; export ENS_SYNC_TENANT
    phase sync ;;
  all)      need_issuer; phase infra; phase commit; wait_commit; phase register; phase subnames; phase profile; phase claim; phase status ;;
  *) echo "unknown phase: $1"; exit 1 ;;
esac
