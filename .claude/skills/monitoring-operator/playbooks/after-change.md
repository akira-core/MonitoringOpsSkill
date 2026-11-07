# Playbook: verify a normal operation after the human did it

## Use when

- An SOP or the human says a routine operation was just done on a VictoriaMetrics or ClickHouse family component: scale replicas, change CPU/memory requests or limits, resize a PVC, rolling restart or upgrade.
- The question is "did it land, and is it healthy now?". Scale-down drain of vmagent/Vector is the profile's scale-down playbook instead.

## Inputs

Ask the human (the profile gives job labels, namespaces, log table):

- Operation, component (`<ns>`, `<workload>`), old and new value, and who owns replicas (the human, or an autoscaler such as an HPA).
- **T_change** in UTC, if known. Ask for a baseline read *before* the operation when it has not happened yet.
- **How it was applied**: edit of the workload or operator CR (template change, pods are recreated), or a resize of the pod itself (`resize` subresource or VPA in-place mode). Step 7 branches on it.

## Surfaces

Works through Grafana (`ds-query.js`) and vmui (`vm-query.js`). vmui covers metrics only, so any verdict that needs ClickHouse logs (new log signatures, seq completeness) is capped at INCONCLUSIVE when only vmui is available.

## Steps

All queries follow the [Request budget](../SKILL.md#request-budget): one at a time, instant before range. For `<w>` see [Freshness](../SKILL.md#freshness).

### 1. Gate

Run the profile's freshness probe for every backend you will read, then [kubernetes-resources.md § 0](../references/kubernetes-resources.md#0-trust-check).
**Done when** both pass, or the verdict is INCONCLUSIVE ("backend frozen"). WHY: the changed component may be the backend that stores the evidence (vminsert, vmstorage, vmselect, the log sink). Its panels freeze or fill late during the change and backfill after. Judge it from the other backend meanwhile, and re-run the probe before the final verdict.

### 2. Fix T_change

Take the human's time. Cross-check with the earliest of these metric signals (epoch seconds, so no arithmetic). For a KSM gauge `X` grouped by `<by>`, the **gate** `max by (<by>)(max_over_time(X[24h])) - min by (<by>)(min_over_time(X[24h]))` is above 0 when it moved, and the **time** is `max by (<by>)(tlast_change_over_time(X[24h]) and (max_over_time(X[24h]) > min_over_time(X[24h])))`.

| Signal | Query |
|---|---|
| Spec generation bumped (workload or CR edit, replica change) | gate and time with `X` = `kube_statefulset_metadata_generation{namespace="<ns>",statefulset="<sts>"}`, `<by>` = `namespace,statefulset` (Deployment: `kube_deployment_metadata_generation`, `namespace,deployment`) |
| Spec value changed (PVC resize, pod resize) | gate and time with `X` = `kube_persistentvolumeclaim_resource_requests_storage_bytes{namespace="<ns>",persistentvolumeclaim=~"<prefix>.*"}`, `<by>` = `persistentvolumeclaim`; or `kube_pod_container_resource_limits{namespace="<ns>",pod=~"<pod regex>"}` (or `_requests`), `<by>` = `pod,container,resource` |
| New pods | `max by (pod)(kube_pod_start_time{namespace="<ns>",pod=~"<pod regex>"})` |
| App restarted | `min by (pod)(vm_app_start_timestamp{job="<job>"})`; ClickHouse: `max by (hostname)(time() - chi_clickhouse_metric_Uptime)` |
| First log line of a new pod (Deployment pods only: a StatefulSet pod keeps its name, so this returns the oldest line) | `SELECT <attrs>['k8s.pod.name'] AS pod, min(<ts>) AS first_line FROM <db>.<log_table> WHERE <ts_pk> >= now() - INTERVAL 1 HOUR AND <attrs>['k8s.namespace.name'] = '<ns>' GROUP BY pod ORDER BY first_line LIMIT 20` |

- The `max_over_time > min_over_time` gate is required: `changes()` and `tlast_change_over_time` count a series' first sample as a change (a young series reported 1 change). The gate is aggregated first because KSM's own `pod`/`instance` labels are part of the series identity: a KSM restart splits the history into constant series, and the per-series time query then returns empty. If KSM restarted in the window, rely on the pod and app signals.
- Non-pod series carry the *scraper's* `pod` label: group by `statefulset`/`deployment`/`persistentvolumeclaim` ([label traps](../references/sop-translation.md#label-traps-read-these-before-writing-queries)).
- A replica-only change bumps the generation but replaces no pod; a template change replaces pods; a PVC or pod resize moves only the spec value.

**Done when** T_change is written in UTC with its source. If the signals disagree by more than 2 scrape intervals, report both and use the earliest. If no signal moved in 24 h and KSM did not restart: FAIL ("change not visible", [rung 1](../references/kubernetes-resources.md#1-did-the-controller-accept-the-change)); with a KSM restart: INCONCLUSIVE.

### 3. Wait for settle

T_settled = the moment every row below holds for the changed component. Until then every verdict is INCONCLUSIVE, naming the unmet row and when to re-ask (re-read no faster than every 60 s).

| Component | Settled when |
|---|---|
| Any workload | [rung 2](../references/kubernetes-resources.md#2-did-it-roll-out) is empty: revision settled, spec = updated = ready = available. Budget per pod and autoscaler windows: "How long to wait" there |
| vminsert, vmselect | rollout done, then the transient noise window of [victoriametrics.md § 1](../references/victoriametrics.md#1-read-the-chains-first) has passed; new vminsert pods take load gradually |
| vmstorage | every `vm_rpc_vmstorage_is_reachable` is 1 on every vminsert, rerouted rows 0 for one `<w>`, slow-insert ratio and churn back inside [section 5](../references/victoriametrics.md#5-saturation) limits |
| vmagent | rollout done, `vmagent_remotewrite_pending_data_bytes` = 0 and flat, targets per shard about total / shard count |
| ClickHouse | pod ready, reconcile completed = started ([clickhouse.md § 6](../references/clickhouse.md#6-post-change-proofs)), `chi_clickhouse_metric_ReadonlyReplica` 0, `ReplicasMaxAbsoluteDelay` back near 0 (replicated installs), merge pool and part count back to the before level, the log sender's buffer drained ([log-pipeline.md § 7](../references/log-pipeline.md#7-outage-shape-and-settling)) |

**Done when** T_settled is written, or the unmet row is named.

### 4. Timeline

One range query per row over `[T_change - 10m, T_settled + 5m]`, step 30 s: ready replicas, restarts, `sum by (job)(increase(vm_log_messages_total{level=~"error|fatal|panic",job=~"<jobs>"}[2m]))`, queue/buffer depth of the neighbouring stage.
**Done when** you can state for each signal when it first moved and when it last moved (`lastNonZeroAt`). Errors that began before T_change are baseline, not caused by it.

### 5. Windows

Before = `[T_change - W, T_change)`. After = `[T_settled, T_settled + W)`. W = 10 min (*interpreted*; at least 4x the slowest scrape interval). Evaluate each metric as an instant query with `RANGE.to` at the window end and `[W]` in the expression. Aggregate by `pod`/`job`, never `instance`, so series split by the switch do not double ([victoriametrics.md § 11](../references/victoriametrics.md#11-gotchas)).
**Done when** every matrix metric has a before and an after value with their eval times. An after window not yet elapsed is provisional (INCONCLUSIVE).

### 6. Check matrix

Run the ladder for the operation; PASS needs every OBSERVE cell. Rungs and queries live in [Operation ladders](../references/kubernetes-resources.md#operation-ladders); VM and ClickHouse side proofs in [victoriametrics.md § 6](../references/victoriametrics.md#6-post-change-proofs) (VM § 6 below) and [clickhouse.md § 6](../references/clickhouse.md#6-post-change-proofs).

| Operation | Also check | PASS |
|---|---|---|
| Replicas up/down, stateless (vminsert, vmselect) | ready count = target; VM § 6 vminsert row; `vm_vminsert_conns` and `vm_vmselect_conns` are exported by vmstorage | every pod `up` = 1; connections follow the replica count; no non-2XX at vmagent in the after window |
| vmstorage replicas | `max(kube_statefulset_replicas{statefulset="<sts>"}) - count(count by (addr)(vm_rpc_vmstorage_is_reachable{job="<vminsert job>"} == 1))`; `sum(increase(vm_rpc_rows_rerouted_from_here_total[<w>]))` and `..._to_here_total`; `sum(increase(vm_new_timeseries_created_total{job="<vmstorage job>"}[<w>])) / sum(increase(vm_rows_added_to_storage_total{job="<vmstorage job>"}[<w>]))` | first query 0, reroutes 0, churn ratio under 0.1 in the after window; per-addr load roughly equal |
| vmstorage scale-down, RF=1 | both reads now, no pre-change baseline needed: `count(count_over_time(<stable family>[5m]))` evaluated at a pre-change time (`RANGE.to` = T_change - 10m) and at a post-settle time; `<stable family>`: dozens of long-lived series that do not churn, e.g. per-CPU `node_cpu_seconds_total{mode="idle"}`; `sum(increase(vm_partial_results_total[<w>]))` | pre-change count = post-settle count. A lower pre-change count means history sits on the removed node: with RF=1 it becomes unqueryable with no `isPartial` and no partial-results increase, so FAIL. Data migration is a HUMAN step |
| vmagent shards | rung 1-2, VM § 6 vmagent row, raw-sample gap per target ([sop-translation.md](../references/sop-translation.md#victoriametrics-cluster-health)) | targets balanced; one gap per moved target of about 2 scrape intervals is expected, more is FAIL |
| ClickHouse replicas | reconcile rows, `count(count by (hostname)(chi_clickhouse_metric_Uptime))` = target | new replica's delay near 0 and merges settled. Replica catch-up needs a replicated install; on a single replica it is NOT-OBSERVABLE |
| CPU or memory | rungs 1-4 and the branch in step 7; VM § 6 CPU and memory rows; ClickHouse `chi_clickhouse_metric_CGroupMemoryTotal` | cgroup = spec; app view = new limit as VM § 6 states (CPU cores track the limit **only when a CPU limit exists**: with none the node's cores show); working set / limit under 0.8 over a 10-30 min soak |
| PVC resize | the [Resize a PVC](../references/kubernetes-resources.md#resize-a-pvc) ladder; spread of sizes across the workload's PVCs: `max(R) - min(R)`, `R` = `kube_persistentvolumeclaim_resource_requests_storage_bytes{namespace="<ns>",persistentvolumeclaim=~"<prefix>.*"}`; app total: `max by (pod)(vm_free_disk_space_bytes{job="<vmstorage job>"}) + on(pod) sum by (pod)(vm_data_size_bytes{job="<vmstorage job>"})`, ClickHouse `chi_clickhouse_metric_DiskTotalBytes` | request and PV capacity = new size, spread 0 (a nonzero spread = new replicas got the old template size). App total near the new size = growth seen. App total far above the request (node disk) or unchanged = filesystem growth NOT-OBSERVABLE, with the HUMAN step below |
| Rolling restart, upgrade | every pod start time > T_change: `count(P) - (count(P > <T_change epoch>) or vector(0))` = 0, `P` = `kube_pod_start_time{namespace="<ns>",pod=~"<regex>"}`; VM § 6 version row; `vm_app_prev_shutdown_unclean` | 0 old pods, one `short_version` per job, unclean shutdown 0 |

**Done when** each cell has a value and a verdict. A cell whose component is not observable (profile Not observable) is NOT-OBSERVABLE with its proxy; it is reported, and does not block PASS ([SKILL.md § 4](../SKILL.md#4-verdict-and-report)).

### 7. In place or recreate (CPU, memory)

Key on how it was applied (Inputs), then on the version. Read the version once: `max by (kubelet_version)(kube_node_info)`.

- **Workload or CR edit**: pods are recreated on every version. Use the step 6 rolling-restart query; pods not replaced means the change did not land (FAIL at rung 2). App budgets moved with the restart.
- **Pod resize, kubelet below 1.33**: in-place resize is alpha there and works only with the `InPlacePodVerticalScaling` feature gate on; ask the human. `kubelet_pod_in_progress_resizes` can be absent: treat an absent series as unknown, not 0.
- **Pod resize, 1.33 (beta) or 1.35 (GA) and later**: rung 3 must hold (cgroup = spec), `kubelet_pod_in_progress_resizes` back to 0 (confirm the series exists first), and the application budget must have moved too. VM reads `vm_allowed_memory_bytes` and `vm_available_cpu_cores` at start-up, so they stay stale after an in-place resize. Cgroup moved but app budget stale: INCONCLUSIVE, HUMAN step "restart the pod".

**Done when** the path is named and its conditions are checked.

### 8. Conservation

At steady state neighbouring stages agree within a few percent ([victoriametrics.md § 7](../references/victoriametrics.md#7-conservation-check), [log-pipeline.md § 3](../references/log-pipeline.md#3-conservation-and-lag)). A window that spans a pod start or a queue replay does not: counters reset and the replay inflates the downstream rate. Compare each stage *ratio* in the before window with the same ratio in the after window. Both windows start after every counter-owning pod in the path started. Drain queues first: stage `pending`/buffer depth near 0 ([victoriametrics.md § 3](../references/victoriametrics.md#3-vmagent-scrape-queue-remote-write), [log-pipeline.md § 7](../references/log-pipeline.md#7-outage-shape-and-settling)).

| Path | Stage ratios (`<w>` windows) |
|---|---|
| Metrics | r1 = `sum(rate(vm_rows_inserted_total{job="<vminsert job>"}[<w>])) / (sum(rate(vmagent_remotewrite_rows_pushed_after_relabel_total[<w>])) + <other writers>)`; r2 = `sum(rate(vm_rows_added_to_storage_total{job="<vmstorage job>"}[<w>])) / sum(rate(vm_rows_inserted_total{job="<vminsert job>"}[<w>]))` (about the replication factor; *interpreted*, measured only at RF=1). `<other writers>`: remote-write senders other than vmagent, found by metric-name discovery, e.g. `sum(rate(vmalert_remotewrite_sent_rows_total[<w>]))` |
| Logs | collector out vs aggregator source in vs sink arrival: the three S1/S2/S4 rates in [log-pipeline.md § 2-3](../references/log-pipeline.md#3-conservation-and-lag) |

PASS when each ratio after is within 5 percentage points of before (*interpreted*) and `increase` of drops, ignored rows, non-2XX and `fluentbit_output_dropped_records_total` is 0. **Log loss is proved only** by the seq completeness query in log-pipeline.md § 3 (`missing` = 0 after settling): ClickHouse only; vmui-only gives INCONCLUSIVE for the sink hop.
**Done when** every ratio has before, after and a verdict.

### 9. Errors, restarts, OOM

In `[T_change, T_settled + W]`: restarts and `OOMKilled` ([rung 4](../references/kubernetes-resources.md#4-is-it-healthy-after), `max_over_time`), `vm_app_prev_shutdown_unclean`, ClickHouse failure counters ([clickhouse.md § 6](../references/clickhouse.md#6-post-change-proofs)), and new log signatures ([log-pipeline.md § 6, "New signatures after a change"](../references/log-pipeline.md#6-classifying-error-rows)) with `change_time` = T_change. Diff the firing alerts against the before set and trust an empty result only per [victoriametrics.md § 8](../references/victoriametrics.md#8-trusting-no-firing-alerts).
**Done when** each error class has a count or a "series absent, collector alive" note. Restart transients count as PASS if they stop at T_settled.

## Verdict rules

- **PASS**: T_change fixed, T_settled reached, step 6 OBSERVE cells all PASS, conservation ratios hold, no new error signature still firing, OOM and unexpected restarts 0 (see [SKILL.md § 4](../SKILL.md#4-verdict-and-report)).
- **FAIL**: any cell fails with fresh data after T_settled, a new signature still firing, an OOM, a stranded-history count, or the change never landed.
- **INCONCLUSIVE**: not settled, after window not elapsed, a backend whose freshness probe is outside its healthy band at verdict time, the app budget stale after in-place resize, or a log check with only vmui.
- **NOT-OBSERVABLE** cells (filesystem growth, single-replica catch-up) are listed with their proxy and HUMAN step.
- Name the first failing stage or the unmet settle row.

## HUMAN steps

Copy these to the human, who runs them:

- Time stamp, right before applying: `date -u +%Y-%m-%dT%H:%M:%S.000Z`.
- PVC growth: `kubectl get pvc <pvc> -n <ns> -o jsonpath='{.status.capacity.storage}'` and `kubectl get sc <class> -o jsonpath='{.allowVolumeExpansion}'`.
- In-place resize state: `kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[*].resources}'` and, if the app budget is stale, restart it per the SOP.
- Rejected change: `kubectl get events -n <ns> --sort-by=.lastTimestamp` (events are not collected).
- vmstorage scale-down: confirm in the SOP that history was migrated or accepted as lost, before the human removes the node.
