#!/usr/bin/env bash
# Pin or release the Vector replica count via KEDA's paused-replicas annotation.
# Usage: scripts/lab/vector/pin.sh <replicas>|off
source "$(dirname "$0")/../../lib.sh"
arg="${1:?usage: pin.sh <replicas>|off}"
if [[ "$arg" == "off" ]]; then
  k -n logging annotate scaledobject/vector autoscaling.keda.sh/paused-replicas- >/dev/null 2>&1
  log "KEDA autoscaling for vector resumed"
else
  [[ "$arg" =~ ^[1-5]$ ]] || die "replicas must be 1..5"
  k -n logging annotate --overwrite scaledobject/vector autoscaling.keda.sh/paused-replicas="$arg" >/dev/null 2>&1
  log "KEDA paused; vector replicas pinned to ${arg}"
fi
