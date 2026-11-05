#!/usr/bin/env bash
# Prove (or disprove) that a Vector PVC holds no unsent records.
# Reads the disk_v2 ledger of every buffer (<data_dir>/buffer/v2/<sink>/buffer.db, little-endian):
#   bytes 0-7   writer_next_record      bytes 16-23  reader_last_record (last acknowledged)
#   pending records = writer_next_record - reader_last_record - 1   (<= 0 -> empty)
# Only PVCs not mounted by a running pod are inspected (the ledger is final after shutdown).
# Usage: scripts/lab/vector/inspect-pvc.sh [pvc-name ...]
source "$(dirname "$0")/../../lib.sh"
NS=logging

mounted_pvcs() {
  k -n "$NS" get pods -o jsonpath='{range .items[*]}{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}{end}' | sort -u
}

inspect_one() {
  local pvc="$1" pod="vector-pvc-inspect-$RANDOM"
  k -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels: { app.kubernetes.io/name: vector-pvc-inspect }
spec:
  restartPolicy: Never
  containers:
    - name: inspect
      image: busybox:1.37
      command: ["sh", "-c"]
      args:
        - |
          for db in \$(find /data/buffer -name buffer.db 2>/dev/null); do
            w=\$(od -A n -t u8 -N 8 "\$db" | tr -d ' ')
            r=\$(od -A n -t u8 -j 16 -N 8 "\$db" | tr -d ' ')
            p=\$((w - r - 1)); [ "\$p" -lt 0 ] && p=0
            echo "buffer=\$(basename \$(dirname \$db)) writer_next_record=\$w reader_last_record=\$r pending_records=\$p"
          done
          echo "--- data files"; find /data/buffer -name 'buffer-data-*.dat' -exec ls -l {} \; | awk '{print \$5, \$NF}'
      volumeMounts:
        - { name: d, mountPath: /data, readOnly: true }
  volumes:
    - name: d
      persistentVolumeClaim: { claimName: ${pvc}, readOnly: true }
YAML
  k -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" --timeout=120s >/dev/null \
    || warn "inspect pod for ${pvc} did not succeed"
  echo "=== ${pvc}"
  k -n "$NS" logs "$pod"
  k -n "$NS" delete pod "$pod" --wait=false >/dev/null
}

main() {
  local pvcs=("$@") mounted pvc
  if (( ${#pvcs[@]} == 0 )); then
    mounted="$(mounted_pvcs)"
    for pvc in $(k -n "$NS" get pvc -o name | sed 's#persistentvolumeclaim/##' | grep '^data-vector-'); do
      grep -qx "$pvc" <<<"$mounted" || pvcs+=("$pvc")
    done
  fi
  (( ${#pvcs[@]} > 0 )) || { log "no unmounted Vector PVCs"; return 0; }
  for pvc in "${pvcs[@]}"; do inspect_one "$pvc"; done
}

main "$@"
