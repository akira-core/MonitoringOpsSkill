#!/usr/bin/env bash
# End-to-end: scale the Vector aggregator DOWN while its downstream (rotel) is unavailable,
# then prove whether the removed pod's PVC still holds unsent records.
#
#   1. scale to 3 replicas                 -> vector-{0,1,2}
#   2. rotel outage for OUTAGE_SECONDS     -> every pod's disk buffer grows
#   3. scale to 2 replicas                 -> vector-2 gets SIGTERM; its sink keeps retrying and
#                                             must drain the disk buffer before Vector exits
#   4. rotel back after HOLD_SECONDS       -> buffers drain -> vector-2 exits
#   5. read data-vector-2's ledger         -> pending_records must be 0
#      + vector-2's own shutdown log lines from ClickHouse
#
# Env: OUTAGE_SECONDS (default 60; 0 = healthy downstream)  HOLD_SECONDS (default 45)
#      GRACE_LIMIT (informational: VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS from the StatefulSet)
source "$(dirname "$0")/../../lib.sh"
LAB="$(dirname "$0")"
OUTAGE_SECONDS="${OUTAGE_SECONDS:-60}"
HOLD_SECONDS="${HOLD_SECONDS:-45}"

cleanup() {
  warn "interrupted: restoring rotel and replica count"
  "$LAB/outage.sh" stop || true
  "$LAB/pin.sh" off || true
}

wait_vector_ready() {
  local want="$1" waited=0 ready
  while (( waited < 600 )); do
    ready="$(k -n logging get pods -l app.kubernetes.io/name=vector \
      -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.status.containerStatuses[0].ready}{"\n"}{end}' \
      | grep -c '^|true$' || true)"
    [[ "$ready" == "$want" ]] && return 0
    sleep 3; waited=$((waited + 3))
  done
  die "timeout waiting for ${want} ready vector pods"
}

wait_pod_gone() {
  local pod="$1"
  k -n logging wait --for=delete "pod/${pod}" --timeout=600s >/dev/null 2>&1 || true
}

shutdown_log() {
  local pod="$1" pw
  pw="$(k -n clickhouse get secret clickhouse-otel -o jsonpath='{.data.password}' | base64 -d)"
  k -n clickhouse exec chi-logs-logs-0-0-0 -- clickhouse-client --user otel --password "$pw" -q "
    SELECT formatDateTime(Timestamp, '%H:%i:%S') AS t, substring(Body, 1, 220)
    FROM otel.otel_logs
    WHERE LogAttributes['k8s.pod.name'] = '${pod}'
      AND Timestamp > now() - INTERVAL 15 MINUTE
      AND (Body LIKE '%Signal received%' OR Body LIKE '%Shutting down%' OR Body LIKE '%has stopped%'
           OR Body LIKE '%Failed to gracefully%' OR Body LIKE '%Vector has started%')
    ORDER BY Timestamp FORMAT TSV" 2>/dev/null | tail -n 12
}

main() {
  trap cleanup INT TERM
  local grace
  grace="$(k -n logging get sts vector -o json | jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS") | .value')"
  log "VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS=${grace:-60(default)}"

  log "step 1: scale to 3 replicas"
  "$LAB/pin.sh" 3
  wait_vector_ready 3
  "$LAB/queue-status.sh"

  if (( OUTAGE_SECONDS > 0 )); then
    log "step 2: rotel outage for ${OUTAGE_SECONDS}s"
    "$LAB/outage.sh" start
    sleep "$OUTAGE_SECONDS"
    "$LAB/queue-status.sh"
  else
    log "step 2: skipped (OUTAGE_SECONDS=0)"
  fi

  log "step 3: scale down to 2 replicas (vector-2 is removed)"
  "$LAB/pin.sh" 2
  sleep "$HOLD_SECONDS"
  "$LAB/queue-status.sh"
  log "vector-2 above should still be terminating: sink retrying, buffer not empty"

  if (( OUTAGE_SECONDS > 0 )); then
    log "step 4: rotel back"
    "$LAB/outage.sh" stop
  fi
  wait_pod_gone vector-2
  wait_vector_ready 2
  "$LAB/queue-status.sh"

  log "step 5: inspect data-vector-2"
  "$LAB/inspect-pvc.sh" data-vector-2
  log "vector-2 shutdown log (via fluent-bit -> other vector pods -> rotel -> ClickHouse; may lag)"
  sleep 20
  shutdown_log vector-2

  trap - INT TERM
  "$LAB/pin.sh" off
  log "done"
}

main "$@"
