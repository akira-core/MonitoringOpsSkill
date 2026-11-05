#!/usr/bin/env bash
# Simulate a remote-storage outage so vmagent's on-disk queue fills up.
# start: pause the VMCluster CR (operator stops reconciling) and scale vminsert to 0.
# stop:  unpause; the operator restores vminsert replicas.
source "$(dirname "$0")/../lib.sh"
case "${1:-}" in
  start)
    k -n monitoring patch vmcluster/vmks --type merge -p '{"spec":{"paused":true}}' >/dev/null
    k -n monitoring scale deploy/vminsert-vmks --replicas=0 >/dev/null
    k -n monitoring wait --for=delete pod -l app.kubernetes.io/name=vminsert --timeout=120s >/dev/null 2>&1 || true
    log "remote storage DOWN (vminsert=0, VMCluster paused)"
    ;;
  stop)
    k -n monitoring patch vmcluster/vmks --type merge -p '{"spec":{"paused":false}}' >/dev/null
    wait_jsonpath monitoring deploy/vminsert-vmks '{.status.readyReplicas}' 2 300
    log "remote storage UP (vminsert restored by operator)"
    ;;
  *) die "usage: outage.sh start|stop" ;;
esac
