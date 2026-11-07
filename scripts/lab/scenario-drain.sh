#!/usr/bin/env bash
# End-to-end: scale VMAgent/lab DOWN while remote storage is unavailable, then prove whether
# the removed shard's queue was delivered before its PVC went away (or, with Retain, is empty).
#
#   1. scale to 3 shards                    -> vmagent-lab-{0,1,2}
#   2. outage start (vminsert=0)            -> on-disk queues grow on every shard
#   3. scale to 2 shards                    -> shard 2 removed, shards 0/1 roll (membersCount 3->2)
#                                              every terminating pod blocks in preStop (queue > 0)
#   4. outage stop after HOLD seconds       -> queues drain -> preStop returns -> SIGTERM
#   5. removed shard's PVCs, by VMAgent persistentVolumeClaimRetentionPolicy.whenDeleted:
#      Delete -> the PVCs must be gone once the pods are; no loss is shown by the stored samples
#                (largest gap per avalanche target) and the pods' own DRAINED lines in ClickHouse
#      Retain -> inspect the orphaned PVCs: pending_bytes must be 0 (one PVC per replica)
#
# DRAIN selects the preStop DRAIN_MODE for the run:
#   auto (default) removed shard stops scraping + drains memory and disk; survivors exit at once
#   disk           every shard waits for on-disk queue == 0 but keeps scraping (in-memory tail best-effort)
#   skip           no drain at all (control: with Delete the removed shard's queue is deleted with its
#                  PVC, so the gap report shows a hole that never heals; with Retain the bytes stay on the PVC)
# Env: DRAIN=auto|disk|skip  OUTAGE_SECONDS (default 60; 0 = no outage, healthy scale-down)
#      HOLD_SECONDS (default 45; >= ~150 makes the removed shard enter preStop while storage is
#      still down, so the drain really has work to do)
#      Nothing autoscales, so the end state stays at 2 shards. With Retain, a stranded queue on the
#      removed shard is not replayed until someone scales back up (so a verifier can still see the gap).
source "$(dirname "$0")/../lib.sh"
LAB="$(dirname "$0")"
DRAIN="${DRAIN:-auto}"
OUTAGE_SECONDS="${OUTAGE_SECONDS:-60}"
HOLD_SECONDS="${HOLD_SECONDS:-45}"

cleanup() {
  warn "interrupted: restoring remote storage and shard count"
  "$LAB/outage.sh" stop || true
  "$LAB/pin.sh" off || true
}

# Set DRAIN_MODE on VMAgent/lab (rolls every shard once while remote storage is healthy).
set_drain_mode() {
  local mode="$1" idx current
  idx="$(k -n vmagent-lab get vmagent lab -o json | jq '[.spec.extraEnvs[].name] | index("DRAIN_MODE")')"
  [[ "$idx" != "null" ]] || die "DRAIN_MODE not found in VMAgent/lab extraEnvs"
  current="$(k -n vmagent-lab get vmagent lab -o jsonpath="{.spec.extraEnvs[${idx}].value}")"
  [[ "$current" == "$mode" ]] && return 0
  log "setting DRAIN_MODE=${mode} (rolls all shards once)"
  k -n vmagent-lab patch vmagent lab --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/extraEnvs/${idx}/value\",\"value\":\"${mode}\"}]" >/dev/null
  sleep 5
  wait_jsonpath vmagent-lab vmagent/lab '{.status.updateStatus}' operational 600
  wait_no_terminating
}

# Ready (non-terminating) vmagent pods == shards x replicaCount.
wait_shards_ready() {
  local replicas want waited=0 ready
  replicas="$(k -n vmagent-lab get vmagent lab -o jsonpath='{.spec.replicaCount}')"
  want=$(( $1 * ${replicas:-1} ))
  while (( waited < 600 )); do
    ready="$(k -n vmagent-lab get pods -l app.kubernetes.io/name=vmagent \
      -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.status.containerStatuses[0].ready}{"\n"}{end}' \
      | grep -c '^|true$' || true)"
    [[ "$ready" == "$want" ]] && return 0
    sleep 5; waited=$((waited + 5))
  done
  die "timeout waiting for ${want} ready vmagent pods ($1 shards)"
}

removed_pvcs() {
  k -n vmagent-lab get pvc -o name | sed 's#persistentvolumeclaim/##' \
    | grep '^persistent-queue-data-vmagent-lab-2-' || true
}

wait_removed_pvcs_gone() {
  local waited=0
  while (( waited < 180 )); do
    [[ -z "$(removed_pvcs)" ]] && return 0
    sleep 3; waited=$((waited + 3))
  done
  warn "shard 2 PVCs still exist 180s after its pods went away: $(removed_pvcs | tr '\n' ' ')"
  return 1
}

# The removed pods' preStop lines as shipped to ClickHouse (container stdout). With Delete this is
# the only copy left: prestop-drain.log on the PVC is gone.
drain_log() {
  local since="$1" pw
  pw="$(k -n clickhouse get secret clickhouse-otel -o jsonpath='{.data.password}' | base64 -d)"
  k -n clickhouse exec chi-logs-logs-0-0-0 -- clickhouse-client --user otel --password "$pw" -q "
    SELECT substring(Body, 1, 200)
    FROM otel.otel_logs
    WHERE Timestamp >= toDateTime(${since})
      AND LogAttributes['k8s.pod.name'] LIKE 'vmagent-lab-2-%'
      AND LogAttributes['k8s.container.name'] = 'vmagent'
      AND Body LIKE '%prestop-drain%'
      AND (Body LIKE '%shard is REMOVED%' OR Body LIKE '%elapsed=0s%' OR Body LIKE '%DRAINED after%'
           OR Body LIKE '%TIMEOUT after%' OR Body LIKE '%skip drain%')
    ORDER BY Timestamp FORMAT TSV" 2>/dev/null || warn "could not read drain lines from ClickHouse"
}

# Shards that are scaled away keep running (preStop) after the others are Ready.
wait_no_terminating() {
  local waited=0 n
  while (( waited < 600 )); do
    n="$(k -n vmagent-lab get pods -l app.kubernetes.io/name=vmagent \
      -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"\n"}{end}' | grep -c . || true)"
    [[ "$n" == "0" ]] && return 0
    sleep 3; waited=$((waited + 3))
  done
  die "timeout waiting for terminating vmagent pods to go away"
}

main() {
  require_tools jq
  [[ "$DRAIN" =~ ^(auto|disk|skip)$ ]] || die "DRAIN must be auto|disk|skip"
  trap cleanup INT TERM

  set_drain_mode "$DRAIN"

  log "step 1: scale to 3 shards"
  "$LAB/pin.sh" 3
  wait_jsonpath vmagent-lab vmagent/lab '{.spec.shardCount}' 3 120
  wait_shards_ready 3
  wait_jsonpath vmagent-lab vmagent/lab '{.status.updateStatus}' operational 600
  wait_no_terminating
  "$LAB/queue-status.sh"
  local t0 policy
  t0=$(( $(date +%s) - 30 ))

  if (( OUTAGE_SECONDS > 0 )); then
    log "step 2: remote storage outage for ${OUTAGE_SECONDS}s"
    "$LAB/outage.sh" start
    sleep "$OUTAGE_SECONDS"
    "$LAB/queue-status.sh"
  else
    log "step 2: skipped (OUTAGE_SECONDS=0, remote storage stays healthy)"
  fi

  log "step 3: scale down to 2 shards"
  "$LAB/pin.sh" 2
  sleep "$HOLD_SECONDS"
  "$LAB/queue-status.sh"
  log "terminating pods above are still in preStop (DRAIN=${DRAIN})"

  if (( OUTAGE_SECONDS > 0 )); then
    log "step 4: remote storage back"
    "$LAB/outage.sh" stop
  fi
  wait_shards_ready 2
  wait_jsonpath vmagent-lab vmagent/lab '{.status.updateStatus}' operational 600
  wait_no_terminating
  "$LAB/queue-status.sh"

  policy="$(k -n vmagent-lab get vmagent lab -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy.whenDeleted}')"
  if [[ "$policy" == "Delete" ]]; then
    log "step 5: whenDeleted=Delete: the removed shard's PVCs go away after its pods"
    wait_removed_pvcs_gone && log "shard 2 PVCs deleted"
    log "step 5: largest gap between stored samples per avalanche target (window starts before the outage)"
    sleep 55   # vmselect hides the newest ~30s
    "$LAB/measure-gaps.sh" window "$t0" "$(( $(date +%s) - 35 ))"
    log "step 5: the removed pods' preStop lines (pending at start, result)"
    drain_log "$t0"
  else
    log "step 5: inspect the removed shard's PVCs (one per replica)"
    # (no mapfile: macOS ships bash 3.2)
    # shellcheck disable=SC2046
    "$LAB/inspect-pvc.sh" $(removed_pvcs)
  fi

  trap - INT TERM
  [[ "$DRAIN" == "auto" ]] || set_drain_mode auto
  log "done (DRAIN=${DRAIN})"
}

main "$@"
