#!/usr/bin/env bash
# Pin or release the VMAgent/lab shard count through KEDA's paused-replicas annotation.
# Usage: scripts/lab/pin.sh <shards>   # KEDA scales to <shards> and stops autoscaling
#        scripts/lab/pin.sh off        # resume autoscaling
source "$(dirname "$0")/../lib.sh"
arg="${1:?usage: pin.sh <shards>|off}"
if [[ "$arg" == "off" ]]; then
  k -n vmagent-lab annotate scaledobject/vmagent-lab autoscaling.keda.sh/paused-replicas- >/dev/null
  log "KEDA autoscaling resumed"
else
  [[ "$arg" =~ ^[2-5]$ ]] || die "shards must be 2..5 (keep >=2, see docs)"
  k -n vmagent-lab annotate --overwrite scaledobject/vmagent-lab autoscaling.keda.sh/paused-replicas="$arg" >/dev/null
  log "KEDA paused; shardCount pinned to ${arg}"
fi
