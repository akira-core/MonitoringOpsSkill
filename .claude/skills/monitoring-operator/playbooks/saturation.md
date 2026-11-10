# Playbook: saturation (name the bottleneck stage)

## Use when

- A remote-write queue or an aggregator disk buffer is growing and nobody knows why.
- Inserts are slow or rejected, ingest hits a rate limit, or someone asks "is it disk, CPU or memory?"
- Someone wants scaling advice and the stage that needs it is unknown. Name the stage here, then size it with [scaling-levers.md](../references/scaling-levers.md).

Pipeline, source to sink: scrape -> vmagent queue -> vminsert -> vmstorage, and collector -> aggregator buffer -> exporter -> ClickHouse.

## Inputs

- Symptom and the time it began. Without a window: last 30 minutes, said out loud.
- From the profile: `job` labels (`<vmagent job>`, `<vminsert job>`, `<vmstorage job>`, `<aggregator job>`, `<ch exporter job>`), `<sink_id>`, namespaces, scrape intervals.
- From the human: any change time (`T_change`). Pre-change and post-change data are different samples.
- `<w>` = rate window, at least 10 m ([Freshness](../SKILL.md#freshness) sets the floor).

## Surfaces and budget

`ds-query.js` (Grafana) and `vm-query.js` (vmui) both run every metric query below. ClickHouse saturation is judged from `chi_*` exporter metrics, so vmui suffices. Evidence that needs SQL (log arrival, lag) is capped at INCONCLUSIVE when only vmui is available. Budget ([Request budget](../SKILL.md#request-budget)): steps 1-3 cost about 25 queries; steps 4-6 add about 5 per stage still standing. Drill only into those stages.

## Steps

1. **Freshness and circularity.** Probe every backend you will read ([Freshness](../SKILL.md#freshness)). If the saturated path also carries the monitoring data, metrics lag or freeze first: a climbing metrics age is a write-path symptom, not a location. Read the other backend (profile: Blind spots).
   - Done when each backend has an age and a healthy/frozen label.

2. **Sweep the buffers.** One query per buffer; "growing" means the floor of the window rises, because raw `deriv` of an in-flight gauge flips sign on noise.
   - vmagent: `max by (pod)(vmagent_remotewrite_pending_data_bytes{job="<vmagent job>"})`. 0 = flat; above 0, take its slope in step 4.
   - Aggregator: `max by (pod)(min_over_time(vector_buffer_size_bytes{buffer_id="<sink_id>"}[<w>])) - max by (pod)(min_over_time(vector_buffer_size_bytes{buffer_id="<sink_id>"}[<w>] offset <w>))`. Above 0 = floor rising.
   - vminsert to vmstorage: `sum by (pod)(vm_rpc_rows_pending)`; small steady values are in-flight buffers. vmstorage: seconds of ingest awaiting flush, `max by (pod)(vm_pending_rows{type="storage"}) / sum by (pod)(rate(vm_rows_added_to_storage_total[<w>]))` (*interpreted*: a few seconds is normal, over 10 s is a flush backlog).
   - ClickHouse: `max(chi_clickhouse_metric_PendingAsyncInsert)`.
   - Done when every buffer is labelled flat, rising or draining, with the value and window.

3. **Eliminate stage by stage, sink to source.** Run the row's queries; skip a row only when no buffer upstream of that stage moved in step 2, and say so. Failure counters are lazy and carry `or vector(0)`; their 0 counts only under [Absent is not 0](../SKILL.md#4-verdict-and-report) (that stage's `up` is 1, the backend fresh in step 1).

| Stage | Falsifying query | Clean if | Detail |
|---|---|---|---|
| ClickHouse | `sum(increase({__name__=~"chi_clickhouse_event_(DelayedInserts\|RejectedInserts)"}[<w>])) or vector(0)`; `sum(increase({__name__=~"chi_clickhouse_event_Failed(Async)?InsertQuery"}[<w>])) or vector(0)`; `chi_clickhouse_metric_BackgroundMergesAndMutationsPoolTask / chi_clickhouse_metric_BackgroundMergesAndMutationsPoolSize`; `chi_clickhouse_metric_MemoryResident / (0.9 * chi_clickhouse_metric_CGroupMemoryTotal)` | 0; 0; well under 1; under 0.8 | [insert path](../references/clickhouse.md#3-insert-path), [parts](../references/clickhouse.md#4-parts-and-merges), [memory](../references/clickhouse.md#5-memory-saturation-chain-worked-example) |
| Exporter (no metrics) | `histogram_quantile(0.99, sum by (pod,le)(rate(vector_http_client_rtt_seconds_bucket{component_id="<sink_id>"}[<w>])))`; `sum by (pod,error_kind)(rate(vector_http_client_errors_total{component_id="<sink_id>"}[<w>])) or vector(0)` | milliseconds; 0. Else *inferred* exporter or ClickHouse | [log-pipeline.md](../references/log-pipeline.md#5-blind-hops) |
| Aggregator sink | `max by (pod)(vector_utilization{component_id="<sink_id>"})` | well under 1 | [log-pipeline.md](../references/log-pipeline.md#2-stage-signals) S2 |
| vmstorage | `sum by (pod)(rate(vm_slow_row_inserts_total[<w>])) / sum by (pod)(rate(vm_rows_added_to_storage_total[<w>]))`; `sum by (pod)(rate(vm_assisted_merges_total[<w>]))`; `max by (pod)(vm_storage_is_read_only)` | under 0.05; 0 (*interpreted*); 0 | step 5 |
| vminsert RPC | `max by (pod)(rate(vm_rpc_send_duration_seconds_total{job="<vminsert job>"}[<w>]))`; `sum(increase(vm_rpc_rows_dropped_on_overload_total[<w>]))` | under 0.9; 0 | [victoriametrics.md](../references/victoriametrics.md#4-vminsert-and-vmstorage-ingest-and-rpc) |
| vminsert intake | `sum by (pod)(increase(vm_concurrent_insert_limit_timeout_total{job="<vminsert job>"}[<w>]))` | 0 | [victoriametrics.md](../references/victoriametrics.md#5-saturation) |
| vmagent send, queue disk | `max by (pod)(rate(vmagent_remotewrite_send_duration_seconds_total{job="<vmagent job>"}[<w>]) / vmagent_remotewrite_queues{job="<vmagent job>"})`; `max by (pod)(rate(vm_persistentqueue_write_duration_seconds_total{job="<vmagent job>"}[<w>]))`; `sum by (pod)(increase(vm_persistentqueue_bytes_dropped_total{job="<vmagent job>"}[<w>]))` | under 0.9; under 0.9; 0 | [victoriametrics.md](../references/victoriametrics.md#3-vmagent-scrape-queue-remote-write) |
| Scrape | `topk(3, max by (job)(scrape_duration_seconds / scrape_timeout_seconds))`; `sum by (job)(increase(vm_promscrape_scrapes_failed_total{job="<vmagent job>"}[<w>]))` | under 0.8 (*interpreted*); 0 | same section |

   - Done when each row has a result or a stated reason it was skipped.

4. **Rate of change.** Slope of a buffer = inflow - outflow. `deriv(...[<w>])` is valid for vmagent pending bytes; for a noisy buffer use in-minus-out ([log-pipeline.md](../references/log-pipeline.md#2-stage-signals) "Buffer in minus out").
   - vmagent time to data loss (growing): `max by (pod)(vm_persistentqueue_free_disk_space_bytes{job="<vmagent job>"}) / on(pod) (max by (pod)(deriv(vmagent_remotewrite_pending_data_bytes{job="<vmagent job>"}[<w>])) > 0)` seconds. At 0 vmagent drops the oldest data.
   - vmagent drain ETA: `max by (pod)(vmagent_remotewrite_pending_data_bytes{job="<vmagent job>"}) / on(pod) (-max by (pod)(deriv(vmagent_remotewrite_pending_data_bytes{job="<vmagent job>"}[<w>])) > 0)` seconds. Assumes today's slope holds.
   - Empty result = no growth (first) or no drain (second), not an error.
   - Aggregator time to full: headroom `max by (pod)(vector_buffer_max_size_bytes{buffer_id="<sink_id>"} - vector_buffer_size_bytes{buffer_id="<sink_id>"})` divided by the step 2 floor rise per second (rise / `<w>` in s). A full buffer with `when_full=block` pushes back to the collector ([log-pipeline.md](../references/log-pipeline.md#1-how-to-read-the-pipeline)).
   - Load or fault: compare `sum(rate(vmagent_remotewrite_rows_pushed_after_relabel_total{job="<vmagent job>"}[<w>]))` with the same query `offset <w>`. Inflow up with every stage clean = demand outgrew capacity.
   - Done when each growing buffer has a slope and a time to loss or full, and each draining one an ETA.

5. **Storage engines (drill only where step 3 left a stage standing).**
   - vmstorage merge backlog: `sum by (pod,type)(vm_parts)` and `sum by (pod,type)(vm_active_merges)` trend up together with rising slow inserts. `vm_assisted_merges_total` rising = ingest threads are merging themselves (*interpreted*; measured only with `type="indexdb/inmemory"`). `vm_merge_need_free_disk_space` was absent on the version measured: absent is *unknown*, not 0.
   - Disk runway: use the rows-based days-to-full in [victoriametrics.md](../references/victoriametrics.md#5-saturation) (under 3 days = FAIL). `vm_free_disk_space_bytes` describes the filesystem under the data path: trust it, and any `deriv` of it, only when `vm_total_disk_space_bytes` matches the PVC request (dedicated volume). For ClickHouse use the data-vs-volume ratio in [clickhouse.md](../references/clickhouse.md#4-parts-and-merges).
   - vmstorage CPU, memory, cache: `sum by (pod)(rate(process_cpu_seconds_total{job="<vmstorage job>"}[<w>])) / max by (pod)(process_cpu_cores_available{job="<vmstorage job>"})`; cache utilisation and working set in the same victoriametrics.md section.
   - ClickHouse parts and merges: `max(max_over_time(chi_clickhouse_metric_MaxPartCountForPartition[<w>]))` flat. Read write amplification with the [clickhouse.md § 4](../references/clickhouse.md#4-parts-and-merges) row; a high ratio counts only together with rising parts.
   - Done when the stage has a named resource (CPU, memory, disk, merge pool) or "none found".

6. **Node and container.** Node values on shared-kernel nodes are identical per node and cannot isolate a stage ([kubernetes-resources.md](../references/kubernetes-resources.md#node-saturation-use), Shared-kernel nodes).
   - Attribute with `topk(5, sum by (namespace,pod,container)(rate(container_fs_writes_bytes_total{container!=""}[<w>])))`: is the standing stage among the top writers?
   - CPU: throttle ratio for containers with a CPU limit ([kubernetes-resources.md § 4](../references/kubernetes-resources.md#4-is-it-healthy-after)); without a limit, container CPU PSI, then usage vs request ([rung 4](../references/kubernetes-resources.md#4-is-it-healthy-after)) when the PSI series is absent. Node PSI names the host, not the stage.
   - Memory: working set / limit from the same rung 4 table.
   - Done when the standing stage's container has a CPU, memory and disk reading, or a stated reason it has none.

7. **Name the stage.** The bottleneck is the most-downstream stage that shows saturation; queues upstream of it are symptoms. Exception: a queue grows while everything downstream is clean, so the sender is the bottleneck (send saturation near 0.9, or its CPU).
   - Done when the report names one stage, or says the evidence does not pick one.

## Verdict rules

- **FAIL**: a stage is saturated (value past its "clean if") and the buffer above it rises; or any dropped-data counter moved (name data loss first); or read-only is 1; or runway is under 3 days.
- **PASS**: every buffer flat or draining, every step 3 row clean, runway over 3 days. This says "not saturated in `<w>`", not a forecast.
- **INCONCLUSIVE**: a backend is frozen; the window is shorter than 2x `<w>`; a needed series is absent (lazy or version-gated); the exporter is the only candidate left (blind hop, report as *inferred*); only vmui is available and the proof needs SQL; or the evidence does not pick one stage (two non-adjacent stages both saturated, or the deciding backend frozen). In that last case, name both stages and the cheapest query that would separate them.

## HUMAN steps

The human runs these; the operator writes them into the report. Find the owner first, because a direct patch of an owned field is reverted or breaks the next upgrade. Ask for the change time, then verify with [after-change.md](after-change.md) and re-run steps 2-4 after `T_change` plus one `<w>`.

```
kubectl -n <ns> get <kind> <name> -o jsonpath='{.metadata.ownerReferences[*].kind}{"\n"}{.metadata.managedFields[*].manager}{"\n"}'
kubectl get hpa -A; helm -n <ns> list
kubectl -n <ns> get pvc; kubectl get sc -o custom-columns=NAME:.metadata.name,EXPAND:.allowVolumeExpansion
kubectl -n <ns> patch vmagent <name> --type merge --dry-run=server -p '{"spec":{"remoteWriteSettings":{"queues":<n>,"maxDiskUsagePerURL":"<size>"}}}'
kubectl -n <ns> patch vmcluster <name> --type merge --dry-run=server -p '{"spec":{"vmstorage":{"resources":{"limits":{"memory":"<size>"}}}}}'
```

If Helm or GitOps owns the field, edit its values file and upgrade instead; drop `--dry-run=server` only after the diff is right.
