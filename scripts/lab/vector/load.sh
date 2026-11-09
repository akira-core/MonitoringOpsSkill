#!/usr/bin/env bash
# Scale synthetic log load. Each loggen replica ~200 lines/s. This only generates load; nothing
# autoscales, set the Vector replica count with pin.sh.
# Usage: scripts/lab/vector/load.sh <loggen-replicas>
source "$(dirname "$0")/../../lib.sh"
replicas="${1:?usage: load.sh <loggen-replicas>}"
[[ "$replicas" =~ ^[0-9]+$ ]] || die "replicas must be a non-negative integer"
k -n vector-lab scale deploy/loggen --replicas="$replicas" >/dev/null
log "loggen replicas=${replicas} (~$((replicas * 200)) lines/s + cluster logs)"
