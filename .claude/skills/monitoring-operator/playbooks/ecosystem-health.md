# Playbook: ecosystem health (whole stack, no SOP)

## Use when

- The user asks for a health check, a "morning check" or "is everything OK" and names no SOP and no component.
- An SOP says "verify the monitoring stack is healthy" without listing checks.

## Inputs

- Profile: `job` names (Signals), Freshness probes, Blind spots, Not observable, Standing health check. A profile row for a component replaces the portable row of the same id.
- Baseline firing alerts: the profile's list if it has one, else the human's, else snapshot the current set first ([VM §8](../references/victoriametrics.md#8-trusting-no-firing-alerts)) and say the diff has no baseline.
- Window `<w>`: the user's, else 30m; at least 4x the slowest scrape interval involved ([Freshness](../SKILL.md#freshness)). If a pod rolled inside `<w>`, start the window about 7 min after the last pod became Ready ([VM §1](../references/victoriametrics.md#1-read-the-chains-first) transient noise).
- Surfaces: Grafana (`ds-query.js`) and/or vmui (`vm-query.js`), up to 6 queries per paste, one paste at a time ([Request budget](../SKILL.md#request-budget)). Core (steps 1-3, S1, S9-S11, alert ladder steps 1-4, one report row per component): about 100 queries, and that is the budget for the whole task. "A full health check" means the core set. State the count before starting. Extended rows (S2-S8: about 15; ladder steps 5-9: about 13) and any follow-up of a failed row spend only what the core left. When the budget is spent, list each remaining check under **Next checks** with its query count and stop. A health check is a survey: a failed row is reported with its evidence and becomes the starting point of a separate [Investigation](../SKILL.md#investigation), which the user asks for and which has its own budget.
- Authority column: `shipped:X` = alert rule X of the VictoriaMetrics Kubernetes stack (confirm it in the rules endpoint, [VM §8](../references/victoriametrics.md#8-trusting-no-firing-alerts)); `kube-prom:X` = kubernetes-mixin rule; `interp.` = judgment, the user's threshold overrides it. A row that only borrows a rule's threshold says how its query differs.

## Steps

### 1. Freshness and trust

1. Run the profile's probe on every backend ([Freshness](../SKILL.md#freshness)); label each LIVE, FROZEN or ABSENT with its age.
2. Run the collector check, [kubernetes-resources §0](../references/kubernetes-resources.md#0-trust-check): an empty kube-state-metrics answer means nothing while that collector is down.
3. Record the Kubernetes version: `max by (kubelet_version)(kube_node_info)`.

**Done when** each backend has a state and an age, and the collectors read 1. Rows on a FROZEN backend are INCONCLUSIVE ([Verdict rules](#verdict-rules)).

### 2. Up and ready

| Row | Query | PASS | Authority |
|---|---|---|---|
| U1 targets | `min by (job)(up) < 1`; detail: `up == 0` | empty | shipped:ServiceDown covers VM jobs only (`== 0` for 2 m); other jobs interp. |
| U2 vanished job | `count by (job)(last_over_time(up[1h])) unless count by (job)(up)` | empty | interp. A pod name gone from a live job is rollout churn, not a vanished target |
| U3 ready | `kube_pod_status_ready{condition="true"} == 0 unless on(namespace,pod) kube_pod_status_phase{phase="Succeeded"} == 1` | empty (completed Jobs excluded) | [k8s §4](../references/kubernetes-resources.md#4-is-it-healthy-after) Readiness; kube-prom:KubePodNotReady also counts Pending and holds 15 m |
| U4 replicas | `kube_deployment_spec_replicas - kube_deployment_status_replicas_available != 0`; `kube_statefulset_replicas - kube_statefulset_status_replicas_ready != 0`; `kube_daemonset_status_desired_number_scheduled - kube_daemonset_status_number_ready != 0` | all empty | desired = ready |
| U5 restarts | `sum by (namespace,pod,container)(increase(kube_pod_container_status_restarts_total[<w>])) > 0`, then `max by (namespace,pod,reason)(max_over_time(kube_pod_container_status_last_terminated_reason[<w>]))` for those pods | empty; a restart is FAIL when the reason is `OOMKilled` or `Error`, else INCONCLUSIVE until the human names the planned change | interp. (kube-prom:KubePodCrashLooping fires only on `waiting_reason="CrashLoopBackOff"`) |
| U6 nodes | [Node health](../references/kubernetes-resources.md#node-saturation-use) | Ready, no `*Pressure`, schedulable | node conditions |

**Done when** every U row has a value and the failing pods or jobs are named.

### 3. Data path, in flow order

Metrics chain: scrape, vmagent queue, remote write, insert, storage. Log chain: collector, aggregator buffer, sink, ClickHouse. Run the rows in flow order; judge from the sink back ([VM §1](../references/victoriametrics.md#1-read-the-chains-first), [log-pipeline §4](../references/log-pipeline.md#4-localizing-a-stall-walk-upstream-from-the-sink)). The sink ends are in step 4 (S1-S4 storage, S9-S11 ClickHouse), so the stage decision waits for it.

| Row | Signal | PASS | Authority |
|---|---|---|---|
| D1 queue, remote write | backlog, outcome, retries: [VM §3](../references/victoriametrics.md#3-vmagent-scrape-queue-remote-write) | pending about 0 and not climbing over `<w>`; status `2XX` only; retries flat | drained = pending 0 |
| D2 queue run-out | `vm_persistentqueue_free_disk_space_bytes / (deriv(vm_persistentqueue_bytes_pending[<w>]) > 0) < 43200` | empty and `vm_persistentqueue_free_disk_space_bytes` exists; any row FAIL (under 14400 s names the 4 h rule) | shipped:PersistentQueueRunsOutOfSpaceIn12Hours / 4Hours (rule uses `[1m]`, widened to `<w>`) |
| D3 loss sweep | `sum by (job,__name__)(increase({__name__=~"vmagent_remotewrite_packets_dropped_total\|vm_persistentqueue_bytes_dropped_total\|vm_rpc_rows_dropped_on_overload_total\|vm_rows_ignored_total\|vm_rows_invalid_total\|fluentbit_output_dropped_records_total\|vector_component_discarded_events_total\|vector_buffer_discarded_events_total"}[<w>]) keep_metric_names) >= 0` | every listed value 0 | shipped:PersistentQueueIsDroppingData, RejectedRemoteWriteDataBlocksAreDropped, RowsRejectedOnIngestion (ignored rows); a dropped or discarded record is a loss by definition ([log-pipeline §2](../references/log-pipeline.md#2-stage-signals)). Retried errors are not loss: D6, D7 |
| D4 insert to storage | `min by (pod,addr)(vm_rpc_vmstorage_is_reachable)`, `max by (pod)(vm_rpc_vmstorage_is_read_only)`, send saturation: [VM §4](../references/victoriametrics.md#4-vminsert-and-vmstorage-ingest-and-rpc) | 1, 0, under 0.9 | shipped:VminsertVmstorageConnectionIsSaturated |
| D5 metrics conservation | [VM §7](../references/victoriametrics.md#7-conservation-check) | the three sides within 5% | interp. |
| D6 collector | `max(fluentbit_input_ingestion_paused) + max(fluentbit_input_storage_overlimit)`; retries and errors: [log-pipeline §2](../references/log-pipeline.md#2-stage-signals) | 0; `retries_failed`, `errors` 0 | log-pipeline §2 |
| D7 aggregator buffer, sink | `max by (pod)(max_over_time(vector_buffer_size_bytes{buffer_id="<sink_id>"}[<w>]) / vector_buffer_max_size_bytes{buffer_id="<sink_id>"})`; buffer in minus out and sink errors ([log-pipeline §2](../references/log-pipeline.md#2-stage-signals)) | under 0.1, in minus out about 0, sink errors absent or 0; 0.8 or more FAIL; between, or sink errors with a flat buffer, INCONCLUSIVE (read the trend) | interp. A raw `deriv` of a near-empty buffer is noise |
| D8 log conservation | `sum(rate(vector_component_received_events_total{component_id="<source_id>"}[<w>])) / sum(rate(fluentbit_output_proc_records_total{name="<out>"}[<w>]))`; and `sum(deriv(chi_clickhouse_table_parts_rows{database="<db>",table="<log_table>",active="1"}[<w>]))` against that denominator | both within 0.95 to 1.05 once settled | interp. ([log-pipeline §3](../references/log-pipeline.md#3-conservation-and-lag)) |
| D9 log age | the profile's SQL probe, [Lag](../references/log-pipeline.md#3-conservation-and-lag) | inside the profile's healthy band | profile |

**Done when** each D row reads PASS, FAIL or INCONCLUSIVE (or is a NOT-OBSERVABLE row with its proxy), and each D3 series that moved is mapped to its stage.

### 4. Storage, saturation, ClickHouse

Vmstorage `<vmstorage job>`, all VM jobs `<vm jobs>`.

| Row | Signal | PASS | Authority |
|---|---|---|---|
| S1 vmstorage disk | `max by (pod)(sum by (pod)(vm_data_size_bytes{job="<vmstorage job>"}) / (sum by (pod)(vm_free_disk_space_bytes{job="<vmstorage job>"}) + sum by (pod)(vm_data_size_bytes{job="<vmstorage job>"})))`; `min by (pod)(vm_free_disk_space_bytes{job="<vmstorage job>"} - vm_free_disk_space_limit_bytes{job="<vmstorage job>"})`; `max by (pod)(vm_storage_is_read_only)`; days to full: [VM §5](../references/victoriametrics.md#5-saturation) | under 0.8; above 0; 0; above 3 days | shipped:DiskRunsOutOfSpace (by `job,instance`); free minus limit at 0 is the read-only point ([VM §4](../references/victoriametrics.md#4-vminsert-and-vmstorage-ingest-and-rpc)); runway shipped:DiskRunsOutOfSpaceIn3Days (NodeBecomesReadonlyIn3Days is the same runway to the limit) |
| S2 slow inserts, churn | `sum by (job)(rate(vm_slow_row_inserts_total[<w>])) / sum by (job)(rate(vm_rows_added_to_storage_total[<w>]))`; `sum by (job)(rate(vm_new_timeseries_created_total[<w>])) / sum by (job)(rate(vm_rows_added_to_storage_total[<w>]))` | under 0.05; under 0.1 | shipped:TooHighSlowInsertsRate, TooHighChurnRate |
| S3 churn 24h | `sum by (job)(increase(vm_new_timeseries_created_total[24h])) / (3 * sum by (job)(vm_cache_entries{type="storage/hour_metric_ids"}))` | under 1 | shipped:TooHighChurnRate24h. A stack younger than 24 h counts its first series as new: INCONCLUSIVE |
| S4 index | `max by (job)(increase(vm_indexdb_items_dropped_total[<w>]))`; `max by (job)(increase(vm_missing_tsids_for_metric_id_total[<w>]))` | 0; 0 | shipped:IndexDBRecordsDrop, TooManyTSIDMisses |
| S5 memory, CPU | [VM §5](../references/victoriametrics.md#5-saturation) Memory and CPU rows | anon RSS / available memory under 0.8; working set / limit under 0.8; CPU ratio under 0.9 | shipped:TooHighMemoryUsage (anon RSS), TooHighCPUUsage; working set / limit interp. |
| S6 file descriptors | `min by (job,pod)(process_max_fds{job=~"<vm jobs>"} - process_open_fds{job=~"<vm jobs>"})`; early warning `max by (job,pod)(process_open_fds / process_max_fds) > 0.8` | at least 100 left; the ratio query empty | shipped:ProcessNearFDLimits; 0.8 is interp. |
| S7 scheduling latency | `histogram_quantile(0.99, sum by (le,job,pod)(rate(go_sched_latencies_seconds_bucket{job=~"<vm jobs>"}[<w>])))` | under 0.1 s | shipped:TooHighGoroutineSchedulingLatency |
| S8 app budget = limit | `max by (pod)(vm_allowed_memory_bytes{job=~"<vm jobs>"}) / on(pod) max by (pod)(kube_pod_container_resource_limits{resource="memory",container=~"vm.*"})` | 0.6 (default `-memory.allowedPercent`) | [VM §6](../references/victoriametrics.md#6-post-change-proofs). Off 0.6: a non-default flag (`flag{name=~"memory.allowed.*"}`) or a limit changed without a restart ([version gate](saturation.md#scaling-levers-advice-the-human-decides-and-acts)): INCONCLUSIVE until the human confirms |
| S9 ClickHouse reach | `min(up{job="<ch exporter job>"})`; `max(chi_clickhouse_metric_fetch_errors)`; `max_over_time(chi_clickhouse_metric_fetch_errors[<w>]) > 0`; `chi_clickhouse_metric_Uptime` | 1; 0; empty; larger than `<w>` | [clickhouse §2](../references/clickhouse.md#2-reachability-and-restart-detection) |
| S10 ClickHouse writes | `(sum(increase(chi_clickhouse_event_DelayedInserts[<w>])) or vector(0)) + (sum(increase(chi_clickhouse_event_RejectedInserts[<w>])) or vector(0)) + (sum(increase(chi_clickhouse_event_FailedInsertQuery[<w>])) or vector(0)) + (sum(increase(chi_clickhouse_event_FailedAsyncInsertQuery[<w>])) or vector(0))`; `max(max_over_time(chi_clickhouse_metric_MaxPartCountForPartition[<w>]))`; merge pool occupancy: [clickhouse §4](../references/clickhouse.md#4-parts-and-merges) | 0; under 300 (FAIL at 1000, the `parts_to_delay_insert` default in 25.x; confirm per version); pool under 1 | [clickhouse §3](../references/clickhouse.md#3-insert-path); 300 is interp. |
| S11 ClickHouse state | `max(chi_clickhouse_metric_ReadonlyDisks) + max(chi_clickhouse_metric_BrokenDisks)`; `max(chi_clickhouse_metric_ReadonlyReplica)`, judged only when `max(chi_clickhouse_metric_AttachedReplicatedTable) > 0` (else 0 by construction; leave it out); memory: [clickhouse §5](../references/clickhouse.md#5-memory-saturation-chain-worked-example) | 0; 0; RSS ratio under 0.8, `MEMORY_LIMIT_EXCEEDED` increase 0 | [clickhouse §4, §5](../references/clickhouse.md#4-parts-and-merges); 0.8 is interp. |

**Done when** each S row run has a verdict, with units and the pod or job it came from, and each skipped row is listed with the reason. Then name, per chain, the stage that stands: the most downstream stage with a failing row (failing rows upstream of it are backpressure), "none", or "the evidence does not pick one" when two failing stages are not linked by backpressure.

### 5. Alerts

Alerts come last: an empty firing list means nothing until the read path and rule evaluation are proven.

1. Climb the [VM §8 ladder](../references/victoriametrics.md#8-trusting-no-firing-alerts): steps 1-4 (Watchdog present, continuity, no vmalert restart, groups evaluated) always, steps 5-9 (evaluation health, path, silences, blind rules, set equality) in the extended run. The first failed step makes row A1 INCONCLUSIVE; steps not run are listed.
2. Bucket the set: `count by (alertgroup,alertname,severity)(ALERTS{alertstate=~"firing|pending",alertname!~"Watchdog|InfoInhibitor"})`.
3. Diff against the baseline firing set (Inputs). Row A1 is this diff.

**Done when** the ladder step reached, the bucketed set and A1's verdict are written down.

## Verdict rules

| Verdict | Condition |
|---|---|
| PASS | backend LIVE, value meets PASS |
| FAIL | value breaks a `shipped:`, reference or `interp.` threshold (name which); A1: a new firing alert of a stack group (`vmcluster`, `vm-health`, `vmagent`, `vmoperator`), or (interp.) any new `critical`; other new alerts are listed for the human |
| INCONCLUSIVE | backend FROZEN or stale; window clipped by a restart or rollout; stack younger than the window; alert ladder broken; borderline `interp.` range |

A row nothing can see is kind NOT-OBSERVABLE ([SKILL.md](../SKILL.md#sop-path)), carries no verdict, and names its proxy (profile: Not observable).

**Absent series**, in this order:

1. Backend FROZEN: INCONCLUSIVE. A frozen `up` still reads 1 and no 0 can be recorded ([Blind spots](../SKILL.md#freshness)); read the other backend and name the cause in the overall verdict.
2. A job in `last_over_time(up[1h])` but not in `up` now (U2): FAIL, the target vanished.
3. A job that never appears in `up`, or has no scrape job (exporter-less hops such as the OTLP exporter): NOT-OBSERVABLE with a proxy ([log-pipeline §5](../references/log-pipeline.md#5-blind-hops)).
4. A lazy counter (errors, discards, delayed or rejected inserts, backpressure wait) absent while its job's `up` is 1: it never fired since the process started, so PASS when the process is older than `<w>`, else INCONCLUSIVE. Add `or vector(0)` only to such counters and only after this `up` check, never to state gauges ([Absent is not zero](../references/clickhouse.md#absent-is-not-zero)).

**Frozen metrics, live logs**: log rows (D9, error signatures in [log-pipeline §6](../references/log-pipeline.md#6-classifying-error-rows)) are the only evidence; overall INCONCLUSIVE. **Live metrics, frozen logs**: D8's `deriv` arrival rate says whether ClickHouse still ingests; D9 is INCONCLUSIVE.

**Overall**: FAIL if any row fails, else INCONCLUSIVE if any row is, else PASS. A proxy-only PASS is written "PASS (proxy)" and listed.

## HUMAN steps

The human runs these. Offer them to settle INCONCLUSIVE or NOT-OBSERVABLE rows:

- Restart cause: `kubectl -n <ns> describe pod <pod>` and `kubectl -n <ns> get events --sort-by=.lastTimestamp`
- Data volume fill (no volume metrics): `kubectl -n <ns> exec <pod> -- df -h <data path>`
- Alertmanager silences and matchers: `kubectl -n <ns> port-forward svc/<alertmanager> 9093`, then `amtool --alertmanager.url=http://127.0.0.1:9093 silence query`
- ClickHouse insert-delay thresholds: `clickhouse-client -q "SELECT name, value FROM system.merge_tree_settings WHERE name IN ('parts_to_delay_insert','parts_to_throw_insert')"`
- S8 off 0.6: show the pod's memory flags and limit with `kubectl -n <ns> get pod <pod> -o jsonpath='{.spec.containers[*].args}{.spec.containers[*].resources.limits}'`

## Surfaces

Both surfaces run every metrics row. vmui covers metrics only: D9, the log-error signatures and any SQL row are NOT-OBSERVABLE there, so with vmui alone the overall verdict is capped at INCONCLUSIVE. The arrival-rate proxy in D8 supports, never replaces, the log-age probe.

## Report

1. Header: time, `<w>`, profile, surface, Kubernetes version, backend states and ages (step 1).
2. One table: id, signal and query, value, PASS condition, authority, verdict. Include one row for each component, even when one query covers several of them: scrape targets, vmagent, vminsert, vmstorage, vmselect, vmalert, alertmanager, the collector, the aggregator, the sink, the log database, Grafana, and CPU saturation. A shared query cites the same value in each row. A component with no row was not checked.
3. Overall verdict, the deciding rows, and the stage that stands per chain (or "none"); a standing stage is the first entry in Next checks, as the start of an [Investigation](../SKILL.md#investigation).
4. NOT-OBSERVABLE rows with proxies; other firing alerts for baseline review.
5. HUMAN steps offered; *interpreted* thresholds used; query count against the [budget](../SKILL.md#request-budget).
6. Next checks: the extended rows and follow-ups not run, each with its query count and the row that calls for it.
