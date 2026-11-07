#!/usr/bin/env bash
# Set the VMAgent/lab shard count directly. Nothing autoscales: this is a plain `kubectl scale`
# on the VMAgent /scale subresource (= spec.shardCount), like a human would do in production.
# Usage: scripts/lab/pin.sh <shards>   # scale to <shards> (2..5)
#        scripts/lab/pin.sh off        # back to the baseline of 2 shards
source "$(dirname "$0")/../lib.sh"
BASELINE_SHARDS=2
arg="${1:?usage: pin.sh <shards>|off}"
if [[ "$arg" == "off" ]]; then
  arg="$BASELINE_SHARDS"
fi
[[ "$arg" =~ ^[2-5]$ ]] || die "shards must be 2..5 (keep >=2, see docs)"
k -n vmagent-lab scale vmagent/lab --replicas="$arg" >/dev/null
log "shardCount set to ${arg}"
