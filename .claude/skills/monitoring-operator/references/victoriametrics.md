# VictoriaMetrics cluster, vmagent, vmalert and vmui: read-only signals

Purpose: find where the metrics write path or read path is stalled, prove a change took effect, and decide whether "no alerts" can be trusted, using only PromQL/MetricsQL and vmui GET endpoints.

Contents:
1. [Read the chains first](#1-read-the-chains-first)
2. [Per-component health](#2-per-component-health)
3. [vmagent: scrape, queue, remote write](#3-vmagent-scrape-queue-remote-write)
4. [vminsert and vmstorage: ingest and RPC](#4-vminsert-and-vmstorage-ingest-and-rpc)
5. [Saturation](#5-saturation)
6. [Post-change proofs](#6-post-change-proofs)
7. [Conservation check](#7-conservation-check)
8. [Trusting "no firing alerts"](#8-trusting-no-firing-alerts)
9. [vmui as a read surface](#9-vmui-as-a-read-surface)
10. [Not observable read-only](#10-not-observable-read-only)
11. [Gotchas](#11-gotchas)

Conventions. `<w>` is a range window ([SKILL.md Freshness](../SKILL.md#freshness)). `<vminsert job>`, `<vmselect job>`, `<vmstorage job>`, `<vmagent job>` are the `job` values from the profile. Thresholds named "shipped alert" come from the alert rules that ship with the VictoriaMetrics Kubernetes stack; confirm the rule exists before citing it: `count(vmalert_alerting_rules_last_evaluation_series_fetched{alertname="<rule>"})` is 1 or more, or the rules endpoint in [section 9](#9-vmui-as-a-read-surface). Kubernetes-side state (pods, PVCs, throttling) is in [kubernetes-resources.md](kubernetes-resources.md) and [sop-translation.md](sop-translation.md).

## 1. Read the chains first

Write path:

```
scrape target -> vmagent (in-memory blocks; persistent queue on disk only when the remote is slow)
  -> HTTP remote write -> vminsert (hash each series to one vmstorage; RPC)
  -> vmstorage (pending rows -> in-memory parts -> merged on-disk parts)
```

Read path:

```
Grafana / vmui / vmalert -> vmselect (rollup cache, dedup) -> RPC fan-out to every vmstorage -> merge
```

vmalert evaluates through vmselect, so read-path trouble shows up as vmalert rule errors and `RecordingRulesNoData`.

**Backpressure moves upstream.** A slow vmstorage saturates the vminsert RPC, then vminsert hits its concurrency limit, then vmagent sees errors or slow sends, then its persistent queue grows. The first metric to move names the layer. Read right to left and stop at the first layer that is abnormal:

| Order | Layer | First check | Stall looks like |
|---|---|---|---|
| 1 | vmstorage | read-only flag, free disk vs limit, slow-insert ratio ([section 5](#5-saturation)) | `vm_storage_is_read_only` = 1, free disk under the limit, slow-insert ratio climbing |
| 2 | vminsert to vmstorage RPC | reachability, send-duration rate, pending rows/bytes ([section 4](#4-vminsert-and-vmstorage-ingest-and-rpc)) | not reachable, send-duration rate near 1, pending growing, rows dropped on overload |
| 3 | vminsert intake | concurrency limit counters, `/insert` HTTP errors, ignored rows | limit_reached or limit_timeout increasing, rows ignored |
| 4 | vmagent remote write | pending bytes, retries, non-2XX, send-duration ratio ([section 3](#3-vmagent-scrape-queue-remote-write)) | pending bytes rising, retries rising, status other than `2XX` |
| 5 | scrape | failed, timed-out scrapes, `up == 0` | targets down while remote write is healthy |

If layers 1-4 are clean but data is missing, the gap is upstream of vmagent (layer 5) or in the read path. Confirm with the [conservation check](#7-conservation-check), which localises a loss to one hop.

**Read-path order:** vmselect concurrency (`vm_concurrent_select_*`), vmstorage concurrency for select RPCs, `vm_partial_results_total`, slow queries, p99 latency ([section 5](#5-saturation)), then `top_queries` and `active_queries` ([section 9](#9-vmui-as-a-read-surface)). A `isPartial: true` answer means a vmstorage did not respond; treat its numbers as incomplete, not as a drop.

**Transient noise.** Rollouts and restarts always produce, for a few minutes: dial timeouts at vminsert, "N out of N vmstorage nodes unavailable" at vmselect, vmalert rule errors, scrape timeouts, `UncleanShutdown`. Judge by whether they stop (interpreted: about 7 minutes after the last pod becomes Ready), not by whether they occurred.

## 2. Per-component health

| Signal | Query | Healthy / PASS | Deviation means |
|---|---|---|---|
| Scrape liveness | `up{job=~"vm.*"}` and `min_over_time(up[<w>]) == 0` | every series 1; count per job equals the expected replica count | 0 now = down. 0 only in `min_over_time` over a window with a restart is expected |
| Version per job | `count by (job, short_version)(vm_app_version)` | one `short_version` per job | two versions in one job after the rollout window = stuck upgrade |
| Rollout finished | `kube_statefulset_status_replicas_ready{namespace=~"<ns>"} - on(namespace,statefulset) kube_statefulset_replicas` and `kube_deployment_status_replicas_available{namespace="<ns>",deployment=~"vm.*"} - on(namespace,deployment) kube_deployment_spec_replicas` | 0 | negative = rollout in progress or stuck |
| Operator CR status | `operator_object_status` | `status="operational"` = 1 for each CR; CR namespace is in `exported_namespace` | `expanding` = 1 while rolling; `failed` = 1 = change rejected |
| Operator reconcile | `sum by (controller)(increase(controller_runtime_reconcile_errors_total{job="<operator job>"}[<w>])) > 0` | empty | reconcile errors |
| Restarts | `max by (pod,container)(kube_pod_container_status_restarts_total{namespace=~"<ns>",container=~"vm.*"})` and `kube_pod_container_status_last_terminated_reason{namespace=~"<ns>",container=~"vm.*"}` | flat over the operation (use `increase` over the window) | `OOMKilled` = raise the memory limit |
| Unclean stop, uptime | `vm_app_prev_shutdown_unclean` and `time() - vm_app_start_timestamp{job="<vmstorage job>"}` | 0; if no restart was intended, uptime exceeds the time since the change | 1 = the last stop was a kill, not SIGTERM (shipped alert `UncleanShutdown`) |
| Log lines by place | `sum by (job,level,location)(increase(vm_log_messages_total{level=~"warn\|error\|fatal\|panic"}[<w>])) > 0` | `error`, `fatal`, `panic` increase = 0 (shipped alert `TooManyErrorLogs` fires on any increase for 5m); warn only bursty around restarts | rising errors; `location` names the subsystem (table below) |

`vm_log_messages_total` is complete and cheap; the log store can miss lines written before the shipper started ([log-pipeline.md](log-pipeline.md)). Counts come from here, text from the log store. Labels also include `app_version` and `is_printed`; `is_printed="false"` counts lines suppressed by log throttling, which are absent from the log store too.

| `location` contains | Subsystem |
|---|---|
| vminsert `netstorage` | storage connectivity |
| `promscrape`, `scrapework` | scrape targets |
| `vmalert`, `rule`, `group` | rule queries |
| vmselect `main.go:264` | slow query (`-search.logSlowQueryDuration`) |
| vmselect `main.go:407` / `main.go:416` | bad user queries |
| `unclean_shutdown` | previous process was killed |

## 3. vmagent: scrape, queue, remote write

| Signal | Query | Healthy / PASS | Deviation means |
|---|---|---|---|
| Backlog | `vmagent_remotewrite_pending_data_bytes ; vm_persistentqueue_bytes_pending ; vmagent_remotewrite_pending_inmemory_blocks ; vmagent_remotewrite_queue_blocked` | about 0 at steady state; falls back to 0 after an outage | growing = the remote (vminsert) is down or slow. Drained means `pending_data_bytes == 0` |
| Outcome | `sum by (pod,url,status_code)(increase(vmagent_remotewrite_requests_total[<w>]))` | only `2XX` | `4XX`/`5XX` = remote rejects |
| Retries and errors | `sum by (pod)(increase(vmagent_remotewrite_retries_count_total[<w>]))` ; `...errors_total` ; `...push_failures_total` | 0 | the remote is refusing or timing out |
| Data loss | `sum by (pod)(increase(vmagent_remotewrite_packets_dropped_total[<w>]))` ; `...samples_dropped_total` ; `sum by (pod)(increase(vm_persistentqueue_bytes_dropped_total[<w>]))` | 0 | `packets_dropped` = rejected blocks dropped (shipped alert `RejectedRemoteWriteDataBlocksAreDropped`). Any queue `bytes_dropped` = data loss (`PersistentQueueIsDroppingData`) |
| Queue budget, queue I/O | `vm_persistentqueue_free_disk_space_bytes ; rate(vm_persistentqueue_bytes_written_total[<w>]) ; rate(vm_persistentqueue_bytes_read_total[<w>]) ; max by (pod)(rate(vm_persistentqueue_write_duration_seconds_total[<w>])) ; max by (pod)(rate(vm_persistentqueue_read_duration_seconds_total[<w>]))` | free budget equals `-remoteWrite.maxDiskUsagePerURL` when empty; duration rate under 0.9 (shipped alerts `PersistentQueueFor{Writes,Reads}IsSaturated`) | budget near 0 = vmagent drops the oldest data next |
| Send saturation, latency | `max by (pod)(rate(vmagent_remotewrite_send_duration_seconds_total[<w>]) / vmagent_remotewrite_queues)` ; `histogram_quantile(0.99, sum by (pod,vmrange)(rate(vmagent_remotewrite_duration_seconds_bucket[<w>])))` | saturation under 0.9 (shipped alert `RemoteWriteConnectionIsSaturated`); p99 in milliseconds | p99 in seconds = vminsert or vmstorage is slow |
| Throughput, block size | `sum by (pod)(rate(vmagent_remotewrite_rows_pushed_after_relabel_total[<w>]))` ; `sum by (pod)(rate(vmagent_remotewrite_bytes_sent_total[<w>]))` ; `sum by (pod)(rate(vmagent_remotewrite_block_size_rows_sum[<w>])) / sum by (pod)(rate(vmagent_remotewrite_block_size_rows_count[<w>]))` | rows/s steady, matches the producers; sum over all vmagents is the left side of the [conservation check](#7-conservation-check) | drop with unchanged producers = write path |
| Targets | `sum by (pod,status)(vm_promscrape_targets) > 0` ; `sum by (pod,scrape_job)(vm_promscrape_scrape_pool_targets)` | `status="down"` absent; targets per shard about total / shard count after a reshard | a pool at 0 targets (shipped alert `ScrapePoolHasNoTargets`) |
| Scrape failures | `sum by (job)(increase(vm_promscrape_scrapes_failed_total[<w>]))` ; `...scrapes_timed_out_total` ; `sum by (pod)(increase(vm_promscrape_dial_errors_total[<w>]))` ; `...max_scrape_size_exceeded_errors_total` ; `...scrapes_skipped_by_sample_limit_total` | `scrapes_failed` increase over 5m = 0 (shipped alert `TooManyScrapeErrors` fires after 15m) | sample-limit skips and size-exceeded = target too big for configured limits |
| Per-job scrape cost | `topk(5, max by (job)(scrape_duration_seconds / scrape_timeout_seconds))` ; `topk(5, sum by (job)(sum_over_time(scrape_series_added[<w>])))` | duration / timeout under 0.8 (interpreted: leaves headroom before timeouts) | sustained high `scrape_series_added` = the target is a churn source |
| Limits and relabel drops | `sum by (job)(increase(vmagent_hourly_series_limit_rows_dropped_total[<w>]))` ; `sum by (job)(increase(vmagent_remotewrite_relabel_metrics_dropped_total[<w>]))` | 0 unless the drop is configured | silent series loss |

`vm_promscrape_conn_read_errors_total` rising while `scrapes_failed` stays 0 is benign (keep-alive resets), not a target failure (interpreted from one observation).

## 4. vminsert and vmstorage: ingest and RPC

| Signal | Query | Healthy / PASS | Deviation means |
|---|---|---|---|
| Ingest by protocol | `sum by (job,type)(rate(vm_rows_inserted_total[<w>]))` (read `job="<vminsert job>"`) | steady around the producers' total | drop with producers unchanged = write path; rise = new targets |
| Written per node | `sum by (pod)(rate(vm_rows_added_to_storage_total[<w>]))` and `sum by (pod)(rate(vm_rows_received_by_storage_total[<w>]))` | nodes within about 10% of each other (interpreted); `received` about equals `added` | `received` much greater than `added` = rows dropped or ignored at storage |
| Reachability | `vm_rpc_vmstorage_is_reachable` ; `vm_rpc_vmstorage_is_read_only` | reachable = 1 and read_only = 0 for every (pod, addr) | read_only = 1: that vmstorage fell under `-storage.minFreeDiskSpaceBytes`; vminsert reroutes away from it |
| Routing balance | `sum by (addr)(rate(vm_rpc_rows_sent_total{rpc_call="metric_rows"}[<w>]))` | roughly equal per addr | a missing addr after scaling = vminsert was not reconfigured |
| RPC saturation | `max by (pod)(rate(vm_rpc_send_duration_seconds_total[<w>]))` ; `vm_rpc_rows_pending ; vm_rpc_buf_pending_bytes` ; `increase(vm_rpc_rows_dropped_on_overload_total[<w>])` ; `increase(vm_rpc_reroutes_total[<w>])` ; `increase(vm_rpc_rows_incompletely_replicated_total[<w>])` | send-duration rate under 0.9 (shipped alert `VminsertVmstorageConnectionIsSaturated`; 1.0 = connection 100% busy); the three `increase` = 0; small pending values are in-flight buffers | pending growing without bound = vmstorage slow |
| Connection errors | `increase(vm_rpc_connection_errors_total[<w>]) ; increase(vm_rpc_dial_errors_total[<w>]) ; sum by (pod)(increase(vm_vminsert_conn_errors_total[<w>])) ; sum by (pod)(increase(vm_vmselect_conn_errors_total[<w>]))` | 0 | non-zero for about 1 minute during a vmstorage rollout is expected; over 15m fires `RPCErrors` |
| Load per vminsert pod | `sum by (pod)(increase(vm_tenant_inserted_rows_total[<w>]))` | some imbalance is normal (long-lived vmagent connections) | a new pod takes load only gradually |
| Ignored or invalid rows | `sum by (job,pod,reason)(increase(vm_rows_ignored_total[<w>]))` ; `sum by (job,pod)(increase(vm_rows_invalid_total[<w>]))` | 0 | `reason` says why (`too_many_labels`, `too_long_label_value`, ...); any rate over 15m fires `RowsRejectedOnIngestion` |
| HTTP errors by path | `sum by (job,path,reason)(increase(vm_http_request_errors_total[<w>])) > 0` | near 0 | on `/insert` paths = clients send bad data; on vmselect usually bad queries (agents' own probes count) |
| Request rate by path | `sum by (job,path)(rate(vm_http_requests_total{job="<vminsert job>"}[<w>])) > 0` | insert req/s about vmagent pods x 1 / flush interval | 0 = writers stopped |
| Pending rows, parts | `sum by (pod)(vm_pending_rows)` ; `sum by (type)(vm_parts)` ; `sum by (type)(vm_active_merges)` | trend only: pending rows steady, parts not growing without bound, merges non-zero only briefly (interpreted) | parts and pending rising together with a rising slow-insert ratio = merge or flush backlog |

## 5. Saturation

Read concurrency from the `*_limit_reached` / `*_limit_timeout` counters. The `*_current` gauges are sampled once per scrape and miss bursts.

| Resource | Query | Healthy / PASS | Deviation means |
|---|---|---|---|
| Insert concurrency | `vm_concurrent_insert_capacity ; increase(vm_concurrent_insert_limit_reached_total[<w>]) ; increase(vm_concurrent_insert_limit_timeout_total[<w>])` | both increases = 0 (shipped alert `ConcurrentInsertsHitTheLimit`: `avg_over_time(vm_concurrent_insert_current[1m]) >= capacity` for 15m) | `limit_timeout` > 0 = clients got errors; backpressure lands in the vmagent queue |
| Select concurrency | `vm_concurrent_select_capacity ; increase(vm_concurrent_select_limit_reached_total[<w>]) ; increase(vm_concurrent_select_limit_timeout_total[<w>])` | `limit_timeout` increase = 0 (shipped alert `TooHighQueryLoad`) | `limit_reached` > 0 = queries queued |
| Slow queries, partial results, latency | `increase(vm_slow_queries_total[<w>])` ; `sum by (job)(increase(vm_partial_results_total[<w>]))` ; `vm_request_duration_seconds{job="<vmselect job>",quantile="0.99"}` ; `histogram_quantile(0.99, sum by (vmrange)(rate(vm_rows_scanned_per_query_bucket[<w>])))` ; `histogram_quantile(0.99, sum by (vmrange)(rate(vm_series_read_per_query_bucket[<w>])))` | slow queries about 0 (threshold `-search.logSlowQueryDuration`); partial results 0; p99 under 1 s for dashboards (interpreted) | with `replicationFactor=1` a partial result means a node's data was missing |
| Disk | `vm_free_disk_space_bytes ; vm_free_disk_space_limit_bytes ; vm_storage_is_read_only ; sum(vm_data_size_bytes) by(pod) / (sum(vm_free_disk_space_bytes) by(pod) + sum(vm_data_size_bytes) by(pod))` | read_only = 0; free well above the limit; used ratio under 0.8 (shipped alert `DiskRunsOutOfSpace`, 30m) | read_only = 1 stops inserts to that node |
| Days to full | `vm_free_disk_space_bytes / ignoring(path) (rate(vm_rows_added_to_storage_total[<w>]) * scalar(sum(vm_data_size_bytes{type!~"indexdb.*"}) / sum(vm_rows{type!~"indexdb.*"})))` | above 259200 s (3 days; shipped alert `DiskRunsOutOfSpaceIn3Days`). Use `<w>` of 1d to match the alert | under 3 days = plan capacity |
| Slow inserts | `sum by (pod)(rate(vm_slow_row_inserts_total[<w>])) / sum by (pod)(rate(vm_rows_added_to_storage_total[<w>]))` | under 0.05 (shipped alert `TooHighSlowInsertsRate`) | caches too small for the active series (memory pressure) or churn |
| Churn | `sum(rate(vm_new_timeseries_created_total[<w>])) by(job) / sum(rate(vm_rows_added_to_storage_total[<w>])) by(job)` | ratio under 0.1 (shipped alert `TooHighChurnRate`); spikes after rollouts and reshards settle within minutes | sustained = labels changing (pod, instance) or a churny target |
| Caches | `max by (job,type)(vm_cache_size_bytes / vm_cache_size_max_bytes) > 0` ; `sum by (job,type)(rate(vm_cache_misses_total[<w>])) / sum by (job,type)(rate(vm_cache_requests_total[<w>])) > 0` | `storage/tsid` utilisation well under 0.9 and miss ratio near 0 | tsid util over 0.9 with slow inserts rising = vmstorage needs memory. Tag-filter cache misses are high in normal operation (ad-hoc queries) |
| Memory | `max by (pod)(min_over_time(process_resident_memory_anon_bytes{job=~"<vm jobs>"}[10m]) / vm_available_memory_bytes{job=~"<vm jobs>"})` and `max by (pod,container)(container_memory_working_set_bytes{namespace="<ns>",container=~"vminsert\|vmselect\|vmstorage"}) / on(pod,container) group_left max by (pod,container)(kube_pod_container_resource_limits{namespace="<ns>",resource="memory",container=~"vminsert\|vmselect\|vmstorage"})` | anon RSS (10 m minimum) / available memory under 0.8, sustained 5 m (the shipped alert `TooHighMemoryUsage`, verified in vmalert); working set / limit under 0.8 (interpreted) | the shipped form uses anonymous RSS and the minimum over 10 m so mmap'd file pages and short spikes do not count. Total RSS / `vm_allowed_memory_bytes` reads much higher on vmstorage (about 0.8 where the shipped form read 0.4) and is not the alert's ratio, so do not judge by it. Also judge OOM risk by working set / limit |
| CPU | `max by (pod)(rate(process_cpu_seconds_total{job=~"<vm jobs>"}[5m]) / process_cpu_cores_available{job=~"<vm jobs>"})` ; `sum by (pod,container)(increase(container_cpu_cfs_throttled_periods_total{namespace=~"<ns>",container=~"vm.*"}[<w>]))` | ratio under 0.9, sustained 5 m (shipped alert `TooHighCPUUsage`); throttled periods about 0 | throttling = limit too low even if the average looks fine. `vm_available_cpu_cores` is read once at start-up (an integer), so after a CPU limit change it stays stale until the pod restarts; prefer `process_cpu_cores_available` |
| Cardinality | `GET .../api/v1/status/tsdb?topN=5` ([section 9](#9-vmui-as-a-read-surface)) | totalSeries stable day over day | a jump after a change = new labels or targets; read the top metric and top label |

## 6. Post-change proofs

After a CPU, memory, replica or version change, prove it from VM's own view, not only from Kubernetes. Order: (a) rollout finished and CR operational (section 2), (b) `up` count and one version per job, (c) the rows below, (d) the [conservation check](#7-conservation-check) with no new non-2XX, retries, ignored or dropped rows, (e) queues back to 0, (f) no new `alertname` beyond the baseline and `vm_log_messages_total` errors flat once the transient-noise window of [section 1](#1-read-the-chains-first) has passed.

| Change | VM-side proof | Query | Expected |
|---|---|---|---|
| CPU limit | cores VM sees | `vm_available_cpu_cores{job=~"<vm jobs>"}` | equals the new limit rounded up; `*_capacity` metrics (concurrency) rescale with it. With no CPU limit set, VM reports the node's CPU count |
| Memory limit | allowed memory | `vm_allowed_memory_bytes` | 0.6 x the new limit (default `-memory.allowedPercent=60`); it changes only after the pod restarted with the new limit |
| vmstorage replicas | one addr per node | `sum by (addr)(rate(vm_rpc_rows_sent_total{rpc_call="metric_rows"}[<w>]))` | a new addr appears (or the removed one disappears) with load |
| vminsert replicas | connections | `vm_vminsert_conns` ; `sum by (pod)(increase(vm_tenant_inserted_rows_total[<w>]))` | conns change in step with the replica count; the new pod takes load gradually |
| vmagent shards | targets per shard | `sum by (pod,scrape_job)(vm_promscrape_scrape_pool_targets)` | about total / shard count per pod |
| Version | one version | `count by (job, short_version)(vm_app_version)` | one `short_version` per job |
| Restart happened | uptime reset | `time() - vm_app_start_timestamp{job="<job>"}` | smaller than the time since the change |
| PVC resize request | spec only | `kube_persistentvolumeclaim_resource_requests_storage_bytes` ; `kube_persistentvolume_capacity_bytes` | request and PV capacity equal the new size; completion is not observable ([section 10](#10-not-observable-read-only)) |

## 7. Conservation check

Rows should be conserved across the three hops. All three sides count HA duplicates, so compare like with like.

```
sum(rate(vmagent_remotewrite_rows_pushed_after_relabel_total[<w>]))
  ~  sum(rate(vm_rows_inserted_total{job="<vminsert job>"}[<w>]))
  ~  sum(rate(vm_rows_added_to_storage_total[<w>]))
```

Agreement within a few percent (interpreted; one observation matched within 0.5%) means no loss on the path. A gap localises it: agents to vminsert = remote-write drops or retries (section 3); vminsert to storage = RPC drops, reroutes, ignored rows (section 4). Always filter `job="<vminsert job>"`: vmstorage also exports `vm_rows_inserted_total` (always 0). Deduplication (`-dedup.minScrapeInterval`) happens at merge and query time, so ingest counters include HA duplicates while query results do not.

## 8. Trusting "no firing alerts"

"No new firing alerts" holds only as far as this ladder holds. Steps 1-4 are the minimum; 5-9 extend it. When a step fails, the verdict is INCONCLUSIVE, not PASS. Check in this order and stop at the first failure.

| Step | Query / endpoint | PASS | Failure means |
|---|---|---|---|
| 1. Watchdog present | `ALERTS{alertname="Watchdog", alertstate="firing"}` | exactly 1 series (its rule is `vector(1)`) | absent: evaluation or vmalert's remote write of `ALERTS` is broken; an empty firing list means nothing |
| 2. Watchdog continuity | `count_over_time(ALERTS{alertname="Watchdog",alertstate="firing"}[<window>])` | at least window / interval - 1; read the interval from `vmalert_iteration_interval_seconds{group="<watchdog group>"}` | shortfall = vmalert was not evaluating or writing for that long; no alert could fire then |
| 3. No vmalert restart | `ALERTS_FOR_STATE{alertname="Watchdog"}` (value = activeAt, unix seconds) | activeAt older than the change start | newer = vmalert restarted in the window and every `for:` timer reset |
| 4. Every group evaluated | `count((time() - tlast_change_over_time(vmalert_iteration_total[<w>])) > 2 * on(group) group_left max by (group)(vmalert_iteration_interval_seconds))` | empty or 0 | a stalled group cannot fire. Do not use `time() - timestamp(vmalert_iteration_total)`: that is scrape age. With several vmalert instances join on `(job, instance, group)` |
| 5. Evaluation health | `sum(increase(vmalert_execution_errors_total[<w>])); max(increase(vmalert_iteration_missed_total[<w>])); vmalert_config_last_reload_successful; sum(vmalert_remotewrite_errors_total)+sum(vmalert_remotewrite_dropped_rows_total)` | 0; 0; 1; flat | missed iterations = groups overrun their interval; remote-write errors = `ALERTS` views go stale |
| 6. Path to Alertmanager | `sum by (status)(increase(alertmanager_alerts_received_total[<w>]))` ; `sum by (addr)(rate(vmalert_alerts_sent_total[<w>]))` ; `sum(vmalert_alerts_send_errors_total)` | received `firing` > 0, sent rate > 0, send errors flat. Watchdog is re-sent every evaluation, so a working path never shows 0 received | these metrics have no `alertname` label; they prove the path, not Watchdog's arrival |
| 7. Nothing hidden | `max by (job, state)(alertmanager_silences)` ; `max by (job, state)(alertmanager_alerts)` ; `max by (job)(alertmanager_inhibition_rules)` | silences active = 0 and pending = 0; alerts `suppressed` = 0 | active silences are often a maintenance silence left behind; verdict INCONCLUSIVE until a human compares matchers to the changed components. `suppressed` merges silenced, inhibited and time-muted. If `inhibition_rules` = 0, suppression can only be silences |
| 8. Not blind | `count(vmalert_alerting_rules_last_evaluation_series_fetched == 0)` ; `count(vmalert_recording_rules_last_evaluation_samples == 0)` | not higher than before the change | a rise after a rename/relabel = rules that can no longer fire. A review list, not an auto-fail: `absent()` rules fetch 0 when healthy |
| 9. Set equality | `count(ALERTS{alertstate="firing"}) - sum(max by (state)(alertmanager_alerts{state=~"active\|suppressed"}))` | 0 in steady state; re-check after 1 minute if nonzero | alerts lost between vmalert and Alertmanager (transient just after a change was not measured) |

Then diff the firing set against a snapshot taken before the change: `count by (alertname, namespace, pod)(ALERTS{alertstate="firing"})`. Take that snapshot first; a set is never expected to be empty because Watchdog (and usually InfoInhibitor) always fire. Only new `alertname`s from the VM groups (`vmcluster`, `vm-health`, `vmagent`, `vmoperator`) are regressions.

**Restart-alert cross-check.** For `TooManyRestarts`, compare `changes(process_start_time_seconds{job="<job>"}[<w>])` with `increase(kube_pod_container_status_restarts_total{namespace="<ns>",pod=~"<pod regex>"}[<w>])`. If `changes` > 2 while the Kubernetes restart increase is 0, the alert is a measurement artifact (the start-time series flips between two values); cause unverified.

**Silences hide alerts from Alertmanager views and notifications only.** `ALERTS` and the vmui alerts page still list silenced alerts, so an empty list means different things on different pages. Silence matchers are visible only in an Alertmanager datasource or UI (Grafana Alerting > Silences), if the profile lists one.

**Delivery is separate.** Proving rule evaluation to Alertmanager ingestion (steps 1-6) does not prove a pager received anything. Delivery needs `alertmanager_integrations` > 0 and `increase(alertmanager_notifications_total{integration="<name>"}[<w>]) > 0` with `alertmanager_notifications_failed_total` flat (shipped alert `AlertmanagerFailedToSendAlerts`). With 0 integrations, state "delivery not observable" in the verdict. Alertmanager keeps an alert active until `endsAt` (about 4 evaluation intervals ahead), so after vmalert dies Watchdog stays active in Alertmanager for up to that long: trust `ALERTS` continuity over Alertmanager state.

## 9. vmui as a read surface

vmui is served by vmselect (`/select/<tenant>/vmui/`) and shares its query path with Grafana. It answers questions about VictoriaMetrics itself and works when Grafana is down. [`scripts/vm-query.js`](../scripts/vm-query.js) wraps the safe endpoints below for a browser-evaluate call; it refuses everything else before sending a request.

Check order from a vmui tab: (1) confirm the tenant in `out.apiBase` and the version in `config.json`; (2) read current alerts; (3) check the query path (`increase(vm_partial_results_total[<w>]) == 0`, select concurrency far from capacity); (4) run the SOP's MetricsQL as range queries over the operation window (`lastNonZeroAt` shows when an error counter last moved, `max` the peak); (5) saturation via `tsdb`, `top_queries`, `active_queries`.

Safe (GET only), relative to `/select/<tenant>/prometheus` unless noted:

| Endpoint | Use | Reading |
|---|---|---|
| `/api/v1/query`, `/api/v1/query_range` | any MetricsQL | `422 ... too many points` = raise the step or narrow the range; `400` = syntax error |
| `/api/v1/series?match[]=...`, `/api/v1/labels`, `/api/v1/label/<name>/values` | discovery | day-granular: after a restart both old and new `instance` appear; use an instant `count(up{job=...})` for what is live |
| `/api/v1/status/tsdb?topN=5` (`focusLabel`, `match[]`, `date`) | cardinality | per UTC day (default today), so `totalSeries` counts every series seen today and is larger than the hourly active count |
| `/api/v1/status/top_queries?topN=5&maxLifetime=30m` | expensive queries | keys `topByCount`, `topByAvgDuration`, `topBySumDuration`, `topByAvgMemoryUsage`; default `maxLifetime` 10m; look for dashboard or alert queries with `avgDurationSeconds` over about 1 s (interpreted) |
| `/api/v1/status/active_queries` | in-flight queries | `[]` when idle; long-running entries during an incident = vmselect saturation. Status is `ok`, not `success` |
| `/vmalert/api/v1/alerts`, `/vmalert/api/v1/rules` (also `/api/v1/alerts`, `/api/v1/rules`, `/api/v1/notifiers`; `vm-query.js` endpoints `alerts` and `rules`) | alert state, per-group `lastEvaluation`, per-rule `health` and `lastError`, notifier `lastError` | exists only when vmselect has `-vmalert.proxyURL` (`config.json` shows `vmalert.enabled`). `/select/<tenant>/vmalert/...` without `/prometheus` returns 400. Includes pending alerts; filter on `state` |
| `<root>/vmui/config.json`, `<root>/vmui/timezone` | version, vmalert availability | the version of VM; `/api/v1/status/buildinfo` is a Prometheus-compat string, not the VM version |
| `/api/v1/query?query=...&trace=1` | where a slow query spends time | per-vmstorage fetch time; vmui "Trace query" toggle |
| `/expand-with-exprs`, `/prettify-query`, `/metric-relabel-debug` | CPU-only helpers | do not touch stored data |

Healthy per-group alert state from the rules endpoint: every `now - lastEvaluation` under 2 x `interval` (interpreted, same rule as step 4 above), every rule `health="ok"`, notifier `lastError` empty. No vmalert metric exports `lastEvaluation`; this endpoint is the direct answer.

**Forbidden** (writes, admin, or heavy): `/api/v1/admin/tsdb/delete_series`; `/internal/*` including `/internal/resetRollupResultCache`; `/api/v1/import`, `/import/csv`, `/import/native`, `/import/prometheus`; any `/insert/<tenant>/...`; `/api/v1/write`; `/-/reload`; `/snapshot/create|delete|delete_all`; `/debug/pprof/*`. Delete and cache-reset endpoints can be unauthenticated when no auth key is configured, so the only protection is not calling them.

**Avoid in the UI**: Raw query and Export (`/api/v1/export`, unbounded raw samples) over wide ranges; "disable cache" (`nocache=1`, extra vmstorage load); `{__name__=~".+"}` over long ranges; changing the Server URL setting (stored in localStorage, redirects all later queries). The vmui tenant picker changes only in-memory state, so a helper deriving its base from `location.pathname` keeps querying the original tenant; set `API_BASE` explicitly for another tenant.

vmselect is usually the only read replica for both vmui and Grafana, so a heavy exploration can starve or OOM the path everyone uses. Watch `container_memory_working_set_bytes` for vmselect against its limit (keep under about 80%, interpreted) while exploring.

## 10. Not observable read-only

| Fact | Closest proxy |
|---|---|
| Exact remote-write HTTP status | `status_code` is bucketed (`2XX`, `4XX`, `5XX`); add `vmagent_remotewrite_packets_dropped_total` and the vmagent log lines in the log store |
| Remote-write destination URL | `url` label is redacted (`1:secret-url`, default `-remoteWrite.showURL=false`); use the `path` label (queue directory) and pod args (human step) |
| Instantaneous insert/select concurrency peaks | `*_limit_reached_total` and `*_limit_timeout_total` counters record every hit |
| Per-vmstorage detail of a partial result | `isPartial` boolean, `out.partial` in the helper, and `increase(vm_partial_results_total[<w>])` |
| vmalert `lastEvaluation` as a metric | the rules endpoint, or `time() - tlast_change_over_time(vmalert_iteration_total[<w>])` against the interval |
| Silence matchers, creator, expiry; which alert is silenced or inhibited | counts only: `alertmanager_silences`, `alertmanager_alerts{state="suppressed"}`; hidden count = `count(ALERTS{alertstate="firing"}) - max by(state)(alertmanager_alerts{state="active"})`; matchers need an Alertmanager datasource |
| That Watchdog specifically reached Alertmanager | Alertmanager metrics carry no `alertname`; use steps 1-6 and 9 of section 8 |
| End-to-end notification delivery | `alertmanager_notifications_total` / `_failed_total` per integration, only when integrations exist |
| PVC resize completion, real PVC usage | request/PV capacity series; `vm_data_size_bytes`; `vm_persistentqueue_free_disk_space_bytes` for the queue budget. `vm_free_disk_space_bytes` reports the filesystem under the data path, which can be the node disk |
| Raw-sample gaps (reshard, upgrade) | MetricsQL `lag()` / `count_over_time()` on one series over a narrow window; see [sop-translation.md](sop-translation.md#victoriametrics-cluster-health) |
| Logs of VM components | metrics only here: `vm_log_messages_total` is the authoritative count; text via [log-pipeline.md](log-pipeline.md) |
| Anything while the only vmselect is down | vmui disappears with it; Grafana's metrics datasource fails the same way. Say INCONCLUSIVE |

## 11. Gotchas

- **Aggregate by `pod` or `job`, never `instance`.** After a restart the pod name stays and the `instance` (pod IP) changes, so range functions over a window spanning the restart return duplicate series.
- **Evidence shares the system under test.** Dashboards and this skill read metrics scraped by a vmagent and stored in the same cluster. During a vminsert/vmstorage outage the evidence is buffered in the scraping vmagent and arrives late. Absence is not zero: check `up` and the time of the last sample ([SKILL.md Freshness](../SKILL.md#freshness)).
- **`vm_request_duration_seconds` is a summary** (`quantile` label, no `_bucket`). `vmagent_remotewrite_duration_seconds` and `vm_rows_*_per_query` use `vmrange` buckets, so `histogram_quantile` must group by `vmrange`.
- **Duplicate-name metrics.** vmstorage also exports `vm_rows_inserted_total` (always 0); vmselect exports `vm_promscrape_*` (all 0). Filter by `job` before summing.
- **Path labels.** `vm_http_requests_total` uses `{}` for the tenant (`/select/{}/prometheus/api/v1/query`), and the `active_queries` path appears without a slash after `{}`. Write path regexes loosely.
- **Unknown paths** return plain-text HTTP 400 `unsupported path requested`, not JSON. A 401 or an HTML login page means the session expired: stop ([SKILL.md](../SKILL.md#read-only-contract)).
- **`NaN` and `+Inf`** become `null` in helper output; VM aligns range starts to the step, so `lastAt` can trail the range end by one step.
- **Replication factor 1** means losing one vmstorage loses half the data, and "N out of N vmstorage nodes unavailable" is a hard query failure that does not increment `vm_partial_results_total`.
- **Queue location.** A vmagent queue on `emptyDir` survives a container restart but not pod deletion; on a PVC it survives both. The queue path label shows which.
- **Agents' own queries move the counters.** Bad probes raise `vm_http_request_errors_total` and can make `RequestErrorsToAPI` or `TooManyLogs` pending. Check `top_queries` for what was run before calling an incident.
