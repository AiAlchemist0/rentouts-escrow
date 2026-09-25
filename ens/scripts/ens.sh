#!/usr/bin/env bash
# RentOuts ENSv2 setup on Ethereum Sepolia. Run from ens/:  ./scripts/ens.sh <phase>
#
#   ./scripts/ens.sh status            read-only report (no signer needed)
#   ./scripts/ens.sh parent            infra -> commit -> wait 65s -> register   (sends txs)
#   ./scripts/ens.sh subnames          deploy RentoutsSubnames + wire roles      (sends txs)
#   ./scripts/ens.sh profile           parent records from ENS_PROFILE_*         (sends txs)
#   ./scripts/ens.sh claim             mint ENS_DEMO_LABEL to ENS_DEMO_HOLDER    (sends txs)
#   ./scripts/ens.sh all               parent + subnames + profile + claim
#   ./scripts/ens.sh removeIssuer      disable ENS_REMOVE_ISSUER (contract + resolver roles) (sends txs)
#
# Sends nothing unless BROADCAST=true. Without it every phase is a dry-run simulation.
# Signs with the Foundry keystore account $FOUNDRY_ACCOUNT (default rentouts-deployer):
# forge prompts for its password. Never put a private key in .env or on the command line.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

: "${SEPOLIA_RPC_URL:?set SEPOLIA_RPC_URL}"
: "${ENS_PARENT_LABEL:?set ENS_PARENT_LABEL (e.g. rentouts)}"
: "${DEPLOYER:?set DEPLOYER to the address of your keystore account (cast wallet address --account rentouts-deployer)}"
ACCOUNT="${FOUNDRY_ACCOUNT:-rentouts-deployer}"
BROADCAST="${BROADCAST:-false}"
export BROADCAST

phase() {
  local sig="$1"
  local args=(script script/DeployEns.s.sol:DeployEns --sig "${sig}()" --rpc-url "${RPC_OVERRIDE:-$SEPOLIA_RPC_URL}" --sender "$DEPLOYER")
  if [ "$BROADCAST" = "true" ]; then
    if [ -n "${UNLOCKED:-}" ]; then args+=(--unlocked --broadcast); else args+=(--account "$ACCOUNT" --broadcast); fi
    args+=(--slow)
  fi
  echo ">> forge ${args[*]}"
  forge "${args[@]}"
}

# The registrar needs the commitment >= 60s old *in the latest block* (Sepolia blocks are ~12s apart),
# so wait well past 60s. LOCAL_MINE=1 (anvil rehearsal) mines a block so the fork's clock moves.
wait_commit() {
  if [ "$BROADCAST" = "true" ]; then
    local secs="${COMMIT_WAIT_SECS:-90}"
    if [ "${LOCAL_MINE:-0}" = "1" ]; then
      echo ">> (local fork) advancing the chain clock ${secs}s"
      cast rpc evm_increaseTime "$secs" --rpc-url "${RPC_OVERRIDE:-$SEPOLIA_RPC_URL}" >/dev/null
      cast rpc evm_mine --rpc-url "${RPC_OVERRIDE:-$SEPOLIA_RPC_URL}" >/dev/null
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
  removeIssuer) phase removeIssuer ;;
  all)      need_issuer; phase infra; phase commit; wait_commit; phase register; phase subnames; phase profile; phase claim; phase status ;;
  *) echo "unknown phase: $1"; exit 1 ;;
esac
