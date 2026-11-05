#!/bin/sh
# preStop hook for a sharded, stateful vmagent (VMAgent CR with statefulMode + shardCount).
#
# Goal: a shard that is being REMOVED (scale-down) must leave an EMPTY persistent queue on its
# PVC, because no pod will ever mount that PVC again. A shard that only ROLLS (any shardCount
# change rolls every shard, since -promscrape.cluster.membersCount changes) keeps its PVC: the
# replacement pod with the same ordinal replays whatever is left, so it should exit fast.
#
# Facts this relies on (vmagent v1.155, see docs/vmagent-graceful-scaledown.md):
#   * On SIGTERM, data already in the file queue stays there; the in-memory tail only gets a
#     best-effort ~5s window. So "empty PVC" must be reached BEFORE SIGTERM.
#   * Scraping continues during preStop, so a removed shard must stop scraping first, otherwise
#     there is always a fresh in-memory tail at SIGTERM.
#   * A block a worker has already read but is still retrying (backoff, up to
#     -remoteWrite.retryMaxInterval) is NOT counted by any pending metric. SIGTERM interrupts
#     the backoff and writes the block back to the file queue. So "drained" also requires the
#     retry/error counters to stay unchanged for DRAIN_QUIET_SECONDS > retryMaxInterval.
#   * Stop-scrape rewrites the operator's config-out emptyDir. This is only safe because the
#     config-reloader sidecar has no preStop: it exits on SIGTERM right away and cannot write
#     the real config back while this hook runs. Re-check after operator upgrades.
#
# Mode (DRAIN_MODE):
#   auto     removed shard -> "full", surviving shard -> "skip"  (needs RBAC: get vmagents/scale)
#   full     stop scraping, wait until total pending (memory + disk) == 0
#   disk     keep scraping, wait until on-disk pending == 0 (in-memory tail is best-effort)
#   skip     return immediately
# Always exits 0 so kubelet proceeds to SIGTERM; a TIMEOUT is logged loudly.
set -u

PORT="${VMAGENT_PORT:-8429}"
METRICS_URL="http://127.0.0.1:${PORT}/metrics"
RELOAD_URL="http://127.0.0.1:${PORT}/-/reload"
MODE="${DRAIN_MODE:-auto}"
TIMEOUT="${DRAIN_TIMEOUT_SECONDS:-240}"
POLL="${DRAIN_POLL_SECONDS:-2}"
# Must exceed -remoteWrite.retryMaxInterval so any worker sleeping in backoff retries
# (and bumps a counter) inside the window.
QUIET_NEEDED="${DRAIN_QUIET_SECONDS:-15}"
LOG_FILE="${DRAIN_LOG_FILE:-}"
VMAGENT_NAME="${VMAGENT_NAME:-}"
# Writable mount of the operator's "config-out" emptyDir (vmagent's own mount is read-only).
WRITABLE_CONFIG="${DRAIN_WRITABLE_CONFIG:-}"
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount

log() {
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) prestop-drain pod=${HOSTNAME:-?} $*"
  echo "$line" >/proc/1/fd/1 2>/dev/null || true   # -> kubectl logs / fluent-bit / ClickHouse
  [ -n "$LOG_FILE" ] && echo "$line" >>"$LOG_FILE" 2>/dev/null   # -> survives on the PVC
  return 0
}

# Sum every series of one metric from Prometheus text format on stdin.
metric_sum() {
  awk -v m="$1" '
    index($0, m "{") == 1 || index($0, m " ") == 1 { s += $NF }
    END { printf "%.0f", s + 0 }'
}

# Retry + connection errors + non-2xx responses: changes while any block is still failing.
failure_signature() {
  awk '
    index($0, "vmagent_remotewrite_retries_count_total") == 1 { s += $NF }
    index($0, "vmagent_remotewrite_errors_total") == 1 { s += $NF }
    index($0, "vmagent_remotewrite_requests_total{") == 1 && $0 !~ /status_code="2/ { s += $NF }
    END { printf "%.0f", s + 0 }'
}

vmagent_flag() {
  tr '\0' '\n' </proc/1/cmdline 2>/dev/null | sed -n "s/^-$1=//p" | head -n 1
}

# Current desired shard count from the VMAgent /scale subresource ("" on any failure).
desired_shards() {
  [ -n "$VMAGENT_NAME" ] || return 0
  ns="$(cat "$SA_DIR/namespace" 2>/dev/null)" || return 0
  token="$(cat "$SA_DIR/token" 2>/dev/null)" || return 0
  SSL_CERT_FILE="$SA_DIR/ca.crt" wget -qO- -T 5 \
    --header "Authorization: Bearer ${token}" \
    "https://kubernetes.default.svc/apis/operator.victoriametrics.com/v1beta1/namespaces/${ns}/vmagents/${VMAGENT_NAME}/scale" \
    2>/dev/null | tr -d ' \t\n' | sed -n 's/.*"spec":{"replicas":\([0-9]*\)}.*/\1/p'
}

resolve_mode() {
  [ "$MODE" = "auto" ] || { echo "$MODE"; return; }
  member="$(vmagent_flag promscrape.cluster.memberNum)"
  if [ -z "$member" ]; then
    echo disk   # not sharded: cannot tell removal from restart; keep the conservative default
    return
  fi
  shards="$(desired_shards)"
  if [ -z "$shards" ]; then
    log "WARN cannot read ${VMAGENT_NAME}/scale; falling back to disk mode"
    echo disk
  elif [ "$member" -ge "$shards" ]; then
    log "memberNum=${member} >= shardCount=${shards}: shard is REMOVED"
    echo full
  else
    log "memberNum=${member} < shardCount=${shards}: shard SURVIVES (PVC is reused)"
    echo skip
  fi
}

stop_scraping() {
  cfg="$(vmagent_flag promscrape.config)"
  if [ -z "$WRITABLE_CONFIG" ] || [ -z "$cfg" ]; then
    log "WARN no writable scrape config; scraping continues (in-memory tail is best-effort)"
    return 1
  fi
  target="${WRITABLE_CONFIG}/$(basename "$cfg")"
  printf 'scrape_configs: []\n' >"$target" || { log "WARN cannot write ${target}"; return 1; }
  wget -qO- -T 5 --post-data='' "$RELOAD_URL" >/dev/null 2>&1 \
    || { log "WARN reload request failed"; return 1; }
  log "scrape config emptied and reloaded"
}

# Drained = chosen pending metric is 0 AND the failure signature has not moved for
# QUIET_NEEDED seconds (no block left in retry backoff).
wait_drained() {
  what="$1"   # metric used as the drain condition
  start=$(date +%s)
  quiet_since=""
  last_sig=""
  while :; do
    now=$(date +%s)
    elapsed=$((now - start))
    if ! body=$(wget -qO- -T 2 "$METRICS_URL" 2>/dev/null); then
      log "metrics endpoint unreachable after ${elapsed}s; giving up"
      return 0
    fi
    disk=$(printf '%s\n' "$body" | metric_sum vm_persistentqueue_bytes_pending)
    total=$(printf '%s\n' "$body" | metric_sum vmagent_remotewrite_pending_data_bytes)
    targets=$(printf '%s\n' "$body" | metric_sum vm_promscrape_targets)
    cur=$(printf '%s\n' "$body" | metric_sum "$what")
    sig=$(printf '%s\n' "$body" | failure_signature)

    if [ "$cur" -eq 0 ] && [ "$sig" = "$last_sig" ]; then
      [ -n "$quiet_since" ] || quiet_since=$now
    else
      quiet_since=""
    fi
    last_sig="$sig"
    quiet=0
    [ -n "$quiet_since" ] && quiet=$((now - quiet_since))
    log "elapsed=${elapsed}s targets=${targets} disk_pending_bytes=${disk} total_pending_bytes=${total} failures=${sig} quiet=${quiet}/${QUIET_NEEDED}s"

    if [ "$quiet" -ge "$QUIET_NEEDED" ]; then
      log "DRAINED after ${elapsed}s (${what}=0, no retries for ${quiet}s); letting SIGTERM through"
      return 0
    fi
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
      log "TIMEOUT after ${elapsed}s; disk=${disk} total=${total} bytes (+ any block in retry) stay on the PVC"
      return 0
    fi
    sleep "$POLL"
  done
}

main() {
  mode="$(resolve_mode)"
  log "start mode=${mode} timeout=${TIMEOUT}s poll=${POLL}s quiet=${QUIET_NEEDED}s"
  case "$mode" in
    skip|off|false)
      log "skip drain; SIGTERM goes through immediately"
      ;;
    full)
      if stop_scraping; then
        wait_drained vmagent_remotewrite_pending_data_bytes
      else
        wait_drained vm_persistentqueue_bytes_pending
      fi
      ;;
    disk|true)
      wait_drained vm_persistentqueue_bytes_pending
      ;;
    *)
      log "unknown DRAIN_MODE=${mode}; skipping"
      ;;
  esac
  exit 0
}

main
