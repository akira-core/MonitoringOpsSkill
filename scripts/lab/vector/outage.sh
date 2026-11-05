#!/usr/bin/env bash
# Simulate a downstream outage for Vector: rotel (OTLP -> ClickHouse) scaled to 0.
# Vector keeps accepting logs from fluent-bit and queues them in its disk buffer (PVC).
source "$(dirname "$0")/../../lib.sh"
case "${1:-}" in
  start)
    k -n logging scale deploy/rotel --replicas=0 >/dev/null
    k -n logging wait --for=delete pod -l app.kubernetes.io/name=rotel --timeout=120s >/dev/null 2>&1 || true
    log "rotel DOWN (replicas=0)"
    ;;
  stop)
    k -n logging scale deploy/rotel --replicas=2 >/dev/null
    wait_rollout logging deploy rotel 180s >/dev/null
    log "rotel UP (replicas=2)"
    ;;
  *) die "usage: outage.sh start|stop" ;;
esac
