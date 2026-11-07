#!/usr/bin/env bash
# Measure scrape gaps while VMAgent/lab rolls.
#   <shards>  set shardCount -> reshard: every pod restarts with a new membersCount
#   upgrade   bump a pod-template annotation -> plain rolling upgrade, shardCount unchanged
# Waits for the roll to finish, then exports the raw
# up{job="avalanche"} samples for the whole window and reports, per target, the largest interval
# between two consecutive samples. Steady state == scrape interval (5s); anything above ~1.5x
# means at least one scrape was missed while pods restarted.
# Also prints, every 2s during the roll, how many pods of each shard are Ready (rolling proof).
# Usage: scripts/lab/measure-gaps.sh <shards>|upgrade   (leaves shardCount as set; `make pin N=off` returns to 2)
source "$(dirname "$0")/../lib.sh"
LAB="$(dirname "$0")"
mode="${1:?usage: measure-gaps.sh <shards>|upgrade}"
MATCH='up{job="avalanche"}'
VMSELECT="http://vmselect-vmks.monitoring.svc.cluster.local:8481/select/0/prometheus"
LATENCY_OFFSET=35   # vmselect hides the newest ~30s (-search.latencyOffset)

# "shard:ready/total" for every shard, e.g. "0:2/2 1:1/2".
ready_per_shard() {
  k -n vmagent-lab get pods -l app.kubernetes.io/name=vmagent -o json | jq -r '
    [.items[] | {s: .metadata.labels["shard-num"],
                 r: ((.metadata.deletionTimestamp == null) and
                     ([.status.containerStatuses[]? | select(.name == "vmagent") | .ready] | all))}]
    | group_by(.s) | map("\(.[0].s):\([.[] | select(.r)] | length)/\(length)") | join(" ")'
}

trigger() {
  if [[ "$mode" == "upgrade" ]]; then
    k -n vmagent-lab patch vmagent lab --type merge \
      -p "{\"spec\":{\"podMetadata\":{\"annotations\":{\"lab/rollout\":\"$(date +%s)\"}}}}" >/dev/null
    log "rolling upgrade triggered (pod template annotation changed)"
  else
    [[ "$mode" =~ ^[2-5]$ ]] || die "shards must be 2..5 or 'upgrade'"
    "$LAB/pin.sh" "$mode"
  fi
}

wait_settled() {
  local waited=0 terminating
  local last="" cur
  sleep 3
  while (( waited < 900 )); do
    cur="$(ready_per_shard)"
    [[ "$cur" != "$last" ]] && log "ready per shard: ${cur}" && last="$cur"
    [[ "$(k -n vmagent-lab get vmagent lab -o jsonpath='{.status.updateStatus}')" == "operational" ]] && break
    sleep 2; waited=$((waited + 2))
  done
  while (( waited < 900 )); do
    terminating="$(k -n vmagent-lab get pods -l app.kubernetes.io/name=vmagent \
      -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{end}')"
    [[ -z "$terminating" ]] && return 0
    sleep 3; waited=$((waited + 3))
  done
  die "pods still terminating after 900s"
}

export_raw() {
  local start="$1" end="$2" pod
  pod="$(k -n vmagent-lab get pods -l app.kubernetes.io/name=vmagent -o jsonpath='{.items[0].metadata.name}')"
  k -n vmagent-lab exec "$pod" -c vmagent -- wget -qO- \
    "${VMSELECT}/api/v1/export?match[]=$(jq -rn --arg q "$MATCH" '$q|@uri')&start=${start}&end=${end}"
}

main() {
  require_tools jq
  local t0 t1 result
  t0=$(( $(date +%s) - 30 ))
  log "mode=${mode} shards=$(k -n vmagent-lab get vmagent lab -o jsonpath='{.spec.shardCount}') replicas/shard=$(k -n vmagent-lab get vmagent lab -o jsonpath='{.spec.replicaCount}')"
  trigger
  wait_settled
  t1=$(( $(date +%s) + 20 ))
  log "settled; waiting ${LATENCY_OFFSET}s+20s for vmselect latency offset"
  sleep $(( LATENCY_OFFSET + 20 ))

  result="$(export_raw "$t0" "$t1")"
  jq -rs '
    map(. as $s | ($s.timestamps | sort) as $t
        | [range(1; $t | length) | {gap: (($t[.] - $t[. - 1]) / 1000), at: ($t[. - 1] / 1000 | strflocaltime("%H:%M:%S"))}]
        | (max_by(.gap) // {gap: 0, at: "-"}) as $m
        | {pod: $s.metric.pod, samples: ($t | length), max_gap: $m.gap, at: $m.at})
    | (map(.max_gap) | max) as $worst
    | "targets=\(length) worst_max_gap=\($worst)s (scrape interval 5s)",
      (.[] | "  \(.pod) samples=\(.samples) max_gap=\(.max_gap)s at \(.at)")' <<<"$result"
}

main "$@"
