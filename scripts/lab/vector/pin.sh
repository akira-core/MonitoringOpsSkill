#!/usr/bin/env bash
# Set the Vector replica count directly. Nothing autoscales: this is a plain `kubectl scale` on
# the StatefulSet, like a human would do in production.
# Before changing the count it waits (up to SETTLE_TIMEOUT s, default 120) until every pod the
# StatefulSet currently asks for is available. Scaling down while a just-added pod is not yet
# available can leave the StatefulSet controller without a requeue: the extra pod then keeps
# running until something touches the object (seen once, 7 minutes). It only waits for scale-up
# to finish; it never waits for a drain, so scenarios that scale down during an outage are not blocked.
# Usage: scripts/lab/vector/pin.sh <replicas>   # scale to <replicas> (1..5)
#        scripts/lab/vector/pin.sh off          # back to the baseline of 2 replicas
source "$(dirname "$0")/../../lib.sh"
BASELINE_REPLICAS=2
arg="${1:?usage: pin.sh <replicas>|off}"
if [[ "$arg" == "off" ]]; then
  arg="$BASELINE_REPLICAS"
fi
[[ "$arg" =~ ^[1-5]$ ]] || die "replicas must be 1..5"
settle_timeout="${SETTLE_TIMEOUT:-120}"
deadline=$(( $(date +%s) + settle_timeout ))
while :; do
  want="$(k -n logging get statefulset/vector -o jsonpath='{.spec.replicas}')"
  have="$(k -n logging get statefulset/vector -o jsonpath='{.status.availableReplicas}')"
  [[ "${have:-0}" -ge "${want:-0}" ]] && break
  if (( $(date +%s) >= deadline )); then
    warn "vector: ${have:-0}/${want} available after ${settle_timeout}s; scaling anyway"
    break
  fi
  sleep 2
done
k -n logging scale statefulset/vector --replicas="$arg" >/dev/null
log "vector replicas set to ${arg}"
