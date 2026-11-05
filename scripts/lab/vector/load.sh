#!/usr/bin/env bash
# Scale synthetic log load. Each loggen replica ~200 lines/s; KEDA targets 400 lines/s per
# Vector pod (min 2, max 5). Usage: scripts/lab/vector/load.sh <loggen-replicas>
source "$(dirname "$0")/../../lib.sh"
replicas="${1:?usage: load.sh <loggen-replicas>}"
[[ "$replicas" =~ ^[0-9]+$ ]] || die "replicas must be a non-negative integer"
k -n vector-lab scale deploy/loggen --replicas="$replicas" >/dev/null
log "loggen replicas=${replicas} (~$((replicas * 200)) lines/s + cluster logs -> expect ~$(( (replicas * 200 + 399) / 400 )) Vector pods, clamped to [2,5])"
