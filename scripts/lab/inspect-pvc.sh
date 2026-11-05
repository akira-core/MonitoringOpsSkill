#!/usr/bin/env bash
# Prove (or disprove) that a vmagent queue PVC is empty.
# For every persistent-queue PVC in vmagent-lab that no running pod mounts, start a throwaway
# pod with the PVC mounted read-only and report, per queue:
#   pending = WriterOffset - ReaderOffset   (from persistent-queue/*/metainfo.json)
# plus the tail of prestop-drain.log written by the preStop hook.
# Usage: scripts/lab/inspect-pvc.sh [pvc-name ...]
source "$(dirname "$0")/../lib.sh"
NS=vmagent-lab

mounted_pvcs() {
  k -n "$NS" get pods -o jsonpath='{range .items[*]}{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}{end}' | sort -u
}

inspect_one() {
  local pvc="$1" pod="pvc-inspect-$RANDOM"
  k -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels: { app.kubernetes.io/name: pvc-inspect }
spec:
  restartPolicy: Never
  containers:
    - name: inspect
      image: busybox:1.37
      command: ["sh", "-c"]
      args:
        - |
          cd /q || exit 1
          for m in \$(find . -name metainfo.json); do
            r=\$(sed -E 's/.*"ReaderOffset":([0-9]+).*/\1/' "\$m")
            w=\$(sed -E 's/.*"WriterOffset":([0-9]+).*/\1/' "\$m")
            echo "queue=\$(dirname "\$m") reader=\$r writer=\$w pending_bytes=\$((w - r))"
          done
          echo "--- files"; find . -type f -exec ls -l {} \; | awk '{print \$5, \$NF}'
          echo "--- prestop-drain.log (tail)"; tail -n 6 prestop-drain.log 2>/dev/null || echo "(none)"
      volumeMounts:
        - { name: q, mountPath: /q, readOnly: true }
  volumes:
    - name: q
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
    for pvc in $(k -n "$NS" get pvc -o name | sed 's#persistentvolumeclaim/##' | grep '^persistent-queue-data-'); do
      grep -qx "$pvc" <<<"$mounted" || pvcs+=("$pvc")
    done
  fi
  (( ${#pvcs[@]} > 0 )) || { log "no orphaned queue PVCs (every PVC is mounted by a pod)"; return 0; }
  for pvc in "${pvcs[@]}"; do inspect_one "$pvc"; done
}

main "$@"
