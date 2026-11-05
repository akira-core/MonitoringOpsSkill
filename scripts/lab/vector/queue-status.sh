#!/usr/bin/env bash
# Per Vector pod: ready, disk-buffer records/bytes for the rotel sink, terminating?
source "$(dirname "$0")/../../lib.sh"
printf '%-10s %-6s %-14s %-14s %s\n' POD READY BUF_RECORDS BUF_BYTES DELETING
for pod in $(k -n logging get pods -l app.kubernetes.io/name=vector -o name | sed 's#pod/##' | sort); do
  ready="$(k -n logging get pod "$pod" -o jsonpath='{.status.containerStatuses[0].ready}')"
  deleting="$(k -n logging get pod "$pod" -o jsonpath='{.metadata.deletionTimestamp}')"
  metrics="$(k -n logging exec "$pod" -- wget -qO- -T 2 http://127.0.0.1:9598/metrics 2>/dev/null || true)"
  recs="$(awk '/^vector_buffer_size_events\{/ && /component_id="rotel"/ {s+=$2} END {printf "%.0f", s+0}' <<<"$metrics")"
  bytes="$(awk '/^vector_buffer_size_bytes\{/ && /component_id="rotel"/ {s+=$2} END {printf "%.0f", s+0}' <<<"$metrics")"
  [[ -z "$metrics" ]] && recs="n/a" && bytes="n/a"
  printf '%-10s %-6s %-14s %-14s %s\n' "$pod" "${ready:-?}" "$recs" "$bytes" "${deleting:--}"
done
echo
k -n logging get pvc -l app.kubernetes.io/name=vector -o custom-columns='PVC:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp' 2>/dev/null \
  || k -n logging get pvc
