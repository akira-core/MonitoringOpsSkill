#!/usr/bin/env bash
# Scale synthetic scrape load. Each avalanche replica ~ 1000 samples/s.
# This only generates load; nothing autoscales, set the shard count with pin.sh.
# Usage: scripts/lab/load.sh <avalanche-replicas>
source "$(dirname "$0")/../lib.sh"
replicas="${1:?usage: load.sh <avalanche-replicas>}"
[[ "$replicas" =~ ^[0-9]+$ ]] || die "replicas must be a non-negative integer"
k -n vmagent-lab scale deploy/avalanche --replicas="$replicas"
log "avalanche replicas=${replicas} (~$((replicas * 1000)) samples/s)"
