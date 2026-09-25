#!/usr/bin/env bash
# Runs the judge with the team's secrets loaded, if the secrets file exists:
#   ./run.sh --lease 3                 (GLM, read only)
#   ./run.sh --lease 3 --propose       (GLM, then AIArbiter.propose, keystore password prompt)
#   ./run.sh --lease 3 --provider mock (no API key needed)
# The file (default ../../.secrets/ai.env, override with JUDGE_SECRETS_FILE) is sourced into this
# process only. Nothing from it is printed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
secrets="${JUDGE_SECRETS_FILE:-${here}/../../.secrets/ai.env}"
if [[ -f "${secrets}" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "${secrets}"
  set +a
fi
cd "${here}"
[[ -d node_modules ]] || npm ci --silent
exec node src/cli.ts "$@"
