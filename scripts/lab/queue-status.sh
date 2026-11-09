#!/usr/bin/env bash
# Per-pod queue view for VMAgent/lab: on-disk pending bytes, total pending, pod phase.
source "$(dirname "$0")/../lib.sh"

printf '%-18s %-10s %-8s %-14s %-16s %s\n' POD PHASE TARGETS DISK_PENDING TOTAL_PENDING DELETING
for pod in $(k -n vmagent-lab get pods -l app.kubernetes.io/name=vmagent -o name 2>/dev/null | sed 's#pod/##' | sort); do
  phase="$(k -n vmagent-lab get pod "$pod" -o jsonpath='{.status.phase}')"
  deleting="$(k -n vmagent-lab get pod "$pod" -o jsonpath='{.metadata.deletionTimestamp}')"
  metrics="$(k -n vmagent-lab exec "$pod" -c vmagent -- wget -qO- -T 2 http://127.0.0.1:8429/metrics 2>/dev/null || true)"
  disk="$(awk 'index($0,"vm_persistentqueue_bytes_pending{")==1 {s+=$NF} END {printf "%.0f", s+0}' <<<"$metrics")"
  total="$(awk 'index($0,"vmagent_remotewrite_pending_data_bytes{")==1 {s+=$NF} END {printf "%.0f", s+0}' <<<"$metrics")"
  targets="$(awk 'index($0,"vm_promscrape_targets{")==1 {s+=$NF} END {printf "%.0f", s+0}' <<<"$metrics")"
  [[ -z "$metrics" ]] && disk="n/a" && total="n/a" && targets="n/a"
  printf '%-18s %-10s %-8s %-14s %-16s %s\n' "$pod" "$phase" "$targets" "$disk" "$total" "${deleting:--}"
done
echo
k -n vmagent-lab get pvc -o custom-columns='PVC:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp'
