#!/usr/bin/env bash
# Shared helpers for lab scripts. Source, don't execute.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-monops}"
KCTX="kind-${CLUSTER_NAME}"

# shellcheck source=../helm/versions.env
source "${ROOT_DIR}/helm/versions.env"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

k() { kubectl --context "$KCTX" "$@"; }
h() { helm --kube-context "$KCTX" "$@"; }

require_tools() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
}

# Random alnum password (no shell/URL-hostile chars).
# (finite producer: avoids SIGPIPE under `set -o pipefail`)
gen_password() { openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"; }

# Create a secret only if absent, so re-runs keep existing credentials.
ensure_secret() {
  local ns="$1" name="$2"; shift 2
  if k -n "$ns" get secret "$name" >/dev/null 2>&1; then return 0; fi
  k -n "$ns" create secret generic "$name" "$@" >/dev/null
  log "created secret ${ns}/${name}"
}

wait_rollout() {
  local ns="$1" kind="$2" name="$3" timeout="${4:-300s}"
  k -n "$ns" rollout status "${kind}/${name}" --timeout "$timeout"
}

# Poll until a jsonpath on a resource equals the expected value.
wait_jsonpath() {
  local ns="$1" res="$2" path="$3" want="$4" timeout="${5:-600}"
  local waited=0 got=""
  while (( waited < timeout )); do
    got="$(k -n "$ns" get "$res" -o "jsonpath=${path}" 2>/dev/null || true)"
    [[ "$got" == "$want" ]] && return 0
    sleep 5; waited=$((waited + 5))
  done
  die "timeout waiting for ${ns}/${res} ${path}=${want} (last: '${got}')"
}
