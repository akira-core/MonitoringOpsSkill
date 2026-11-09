# Log pipeline: stage signals, conservation, stall localization, error classification

Read a container-log pipeline (collector -> aggregator with disk buffer -> OTLP-to-ClickHouse exporter -> ClickHouse) from metrics and SQL only.

Contents:
1. [How to read the pipeline](#1-how-to-read-the-pipeline)
2. [Stage signals](#2-stage-signals)
3. [Conservation and lag](#3-conservation-and-lag)
4. [Localizing a stall](#4-localizing-a-stall-walk-upstream-from-the-sink)
5. [Blind hops](#5-blind-hops)
6. [Classifying error rows](#6-classifying-error-rows)
7. [Outage shape and settling](#7-outage-shape-and-settling)
8. [After changing a stage](#8-after-changing-a-stage)
9. [Not observable](#9-not-observable)

Placeholders: `<W>` = rate/increase window ([SKILL.md Freshness](../SKILL.md#freshness)). `<source_id>` = aggregator OTLP source, `<sink_id>` = aggregator sink toward the exporter (also the disk-buffer id). `<in>` / `<out>` = collector input / output plugin instance (`name` label, such as `tail.0`, `opentelemetry.0`). `<db>.<log_table>` = log table; `<body>`, `<ts>` (event time, the container write time), `<ts_pk>` (the time column in the primary key, which prunes), `<attrs>` (attribute map, keys `k8s.pod.name`, `k8s.namespace.name`, `k8s.container.name`). Label traps (`pod` on kube-state-metrics series): [sop-translation.md](sop-translation.md#label-traps-read-these-before-writing-queries).

## 1. How to read the pipeline

Data flows `app stdout -> collector (S1) -> aggregator source -> aggregator disk buffer -> sink -> exporter (S3) -> ClickHouse (S4) -> rows`. Backpressure flows the other way: a slow or failing S4 or S3 fills the S2 buffer; a full buffer set to `when_full=block` makes the source answer slowly or non-200; the collector then retries and waits (backpressure_wait, upstream busy == total); at its memory limit the collector pauses reading, and lines wait in the node's log files (lost if rotation outruns them).

Check in this order:
1. **Lag** (section 3), because it says whether anything is wrong at all. Confirm S1 IN > 0 first: a quiet source also grows lag.
2. **Conservation** per neighbour pair, in the same unit.
3. **Depth** of the one buffer (S2): flat near 0 = the downstream keeps up; rising = downstream is slower than the intake; at the max = backpressure has started.
4. **Errors / retries / drops** at the stage the first broken pair points to.

Rules that prevent wrong verdicts:
- **Units differ inside the aggregator** when OTLP is passed through unchanged. The source `received_events` counts log lines. `sent_events`, buffer and sink counters count OTLP requests (each holds many lines). Compare collector `proc_records` with source `received`, and source `sent` with sink `sent`. Never compare lines with requests.
- **Filter every buffer query by `buffer_id="<sink_id>"`.** An internal metrics-exporter sink has its own memory buffer reporting the same `vector_buffer_*` names at a high rate.
- **Counters reset on restart**: use `rate`/`increase`, never raw values.
- **Lazy series**: `vector_http_client_errors_total`, non-200 `vector_http_server_responses_sent_total`, `fluentbit_output_backpressure_wait_seconds_*` and the aggregator's `component_errors` / `discarded_events` counters exist only after their first occurrence and vanish on restart. "No series" is not "zero errors": wrap with `or vector(0)`, and read `increase` over a window that spans the incident.
- A stage whose problem is a stall shows **flat counters**, not error counters. Look for rates at 0 beside a growing buffer.

## 2. Stage signals

Row = signal | query | healthy | what a deviation means. Thresholds marked *interpreted* are judgment; the others follow the cited reason.

### S1 Collector (fluent-bit style DaemonSet)

| Signal | Query | Healthy | Deviation |
|---|---|---|---|
| IN, lines read | `sum by (pod)(rate(fluentbit_input_records_total{job="<collector_job>",name="<in>"}[<W>]))` | steady for a steady workload; this is the reference rate for every later stage | one pod at 0 while its node runs workloads: tail stuck or pod down |
| OUT, lines delivered | `sum by (pod)(rate(fluentbit_output_proc_records_total{name="<out>"}[<W>]))` | equals IN within a few percent (*interpreted*) | OUT < IN for minutes: chunks accumulate in memory; read retries and storage rows |
| Retries, errors, drops | `sum by (pod)(increase(fluentbit_output_retries_total[<W>]))`; same for `_retries_failed_total`, `_errors_total`, `_dropped_records_total`, `_retried_records_total` | `retries_failed`, `errors`, `dropped` = 0 (a dropped record is a lost line by definition). A few retries during an aggregator rollout or scale event are expected | steady retry rate: the aggregator rejects or is unreachable. `dropped` > 0: data loss, report as such |
| Ingestion backpressure | `max by (pod)(fluentbit_input_ingestion_paused)`; `max by (pod)(fluentbit_input_storage_overlimit)`; `max by (pod)(fluentbit_input_storage_memory_bytes)`; `min by (pod)(fluentbit_output_chunk_available_capacity_percent)` | paused 0, overlimit 0, memory_bytes below the input's memory-buffer limit, capacity 100 | paused or overlimit = 1: tail stopped reading, lines pile up in node log files. Capacity < 100: output chunks queue |
| Output workers | `fluentbit_output_upstream_total_connections`; `fluentbit_output_upstream_busy_connections` | busy < total | busy == total for a sustained period: every worker waits on the aggregator |
| Output latency | `histogram_quantile(0.99, sum by (pod,le)(rate(fluentbit_output_latency_seconds_bucket[<W>])))` (histogram labels are `input` / `output`, not `name`) | about the flush interval (default 1 s) | many seconds: slow acks or retries |
| Backpressure wait | `sum by (pod)(increase(fluentbit_output_backpressure_wait_seconds_count[<W>]))` (lazy series; wrap with `or vector(0)`) | absent or 0 | any increase: the output waited on downstream backpressure |
| Chunk storage type | `fluentbit_storage_fs_chunks; fluentbit_storage_mem_chunks` | `fs_chunks` 0 means memory-only buffering: a collector restart loses in-flight chunks | not a fault; it sets what a restart can lose |

### S2 Aggregator (Vector style, disk buffer)

| Signal | Query | Healthy | Deviation |
|---|---|---|---|
| IN, lines accepted | `sum by (pod)(rate(vector_component_received_events_total{component_id="<source_id>"}[<W>]))` | sum equals S1 OUT; an uneven per-pod split is normal (collector keep-alive recycles connections) | lower than S1 OUT: the collector is not delivering; see section 4 step 3 |
| Accept or reject | `sum by (pod,status)(rate(vector_http_server_responses_sent_total{component_id="<source_id>",path="/v1/logs"}[<W>]))` | status 200 only | any non-200: the source rejects, for example a full buffer with `when_full=block` |
| Requests through the pipeline | `sum by (pod,component_id)(rate(vector_component_sent_events_total{component_id=~"<source_id>\|<sink_id>"}[<W>])); sum by (pod,component_id)(rate(vector_component_received_events_total{component_id="<sink_id>"}[<W>]))` | sink sent equals sink received | sink sent below received: buffer growing. Sink sent at 0 with received > 0: sink stalled |
| Buffer depth | `max by (pod)(vector_buffer_size_events{buffer_id="<sink_id>"}); max by (pod)(vector_buffer_size_bytes{buffer_id="<sink_id>"}); vector_buffer_size_bytes{buffer_id="<sink_id>"} / vector_buffer_max_size_bytes{buffer_id="<sink_id>"}` | fluctuating near 0 (a few requests in flight) | monotonic rise: downstream not consuming. Ratio near 1: with `when_full=block`, backpressure reaches the collector |
| Buffer in minus out | `sum by (pod)(rate(vector_buffer_received_events_total{buffer_id="<sink_id>"}[<W>])) - sum by (pod)(rate(vector_buffer_sent_events_total{buffer_id="<sink_id>"}[<W>]))` | about 0 | positive: growing. Negative: draining a backlog (expected after recovery) |
| Buffer write latency | `histogram_quantile(0.99, sum by (pod,le)(rate(vector_buffer_send_duration_seconds_bucket{component_id="<sink_id>"}[<W>])))` | milliseconds | seconds: buffer full and blocking, or a slow volume |
| Sink errors | `sum by (pod,error_kind)(rate(vector_http_client_errors_total{component_id="<sink_id>"}[<W>])) or vector(0)` | absent or 0 | any rate: exporter unreachable or timing out (`error_kind` says connect refused vs timeout). The disk buffer absorbs it until its max |
| Sink responses and RTT | `sum by (pod,status)(rate(vector_http_client_responses_total{component_id="<sink_id>"}[<W>])); histogram_quantile(0.99, sum by (pod,le)(rate(vector_http_client_rtt_seconds_bucket[<W>])))` | status 200 only; RTT in milliseconds | rising RTT: exporter or ClickHouse slow. Responses at 0 with a growing buffer: stall. One request carries several batched events, so the request rate is below the event rate |
| Sink utilization | `max by (pod)(vector_utilization{component_id="<sink_id>"}); max by (pod)(max_over_time(vector_utilization{component_id="<sink_id>"}[<W>]))` | well below 1 | sustained near 1: the sink is the bottleneck, scale the aggregator out. Near 1 during a replay is expected |
| Internal queues | `max by (pod,component_id,output)(vector_source_buffer_utilization_level)`; compare with `vector_source_buffer_max_size_events` | well below the max | near max: the pipeline cannot keep up with the source |
| Memory headroom | `sum by (pod)(container_memory_working_set_bytes{namespace="<ns>",pod=~"<aggregator>-.*",container!=""}) / sum by (pod)(kube_pod_container_resource_limits{namespace="<ns>",pod=~"<aggregator>-.*",resource="memory"})` | below 0.8 (*interpreted*) | a backlog replay pushes memory toward the limit, so an OOM kill is most likely while draining. More: [kubernetes-resources.md](kubernetes-resources.md) |
| Readiness | `kube_statefulset_status_replicas_ready{namespace="<ns>",statefulset="<aggregator>"}`; `increase(kube_pod_container_status_restarts_total{namespace="<ns>"}[<W>])` | ready == desired; restarts 0 outside planned changes | restarts after a change: check `last_terminated_reason` |

### S3 Exporter and S4 ClickHouse (sink)

Treat the exporter (S3) as blind unless `up{job=~".*<exporter>.*"}` returns a series: [section 5](#5-blind-hops). S4 rows:

| Signal | Query | Healthy | Deviation |
|---|---|---|---|
| Live arrival rate | `sum(deriv(chi_clickhouse_table_parts_rows{database="<db>",table="<log_table>",active="1"}[<W>]))` | approximately equals S1 OUT; merges do not change active rows | 0: nothing inserted. Above S1 OUT: a backlog is draining. A negative step: a TTL partition drop |
| Rows per minute by event time | `SELECT toStartOfMinute(<ts>) m, count() c, round(c/60,1) per_s FROM <db>.<log_table> WHERE <ts_pk> > now() - INTERVAL 12 MINUTE GROUP BY m ORDER BY m` | equals S1 OUT for complete minutes; ignore the last minute | **backfills after an outage**, so it looks gap-free afterwards. Use only for steady state; use the arrival rate for history |
| Insert failures | `sum(increase(chi_clickhouse_event_FailedInsertQuery[<W>])); rate(chi_clickhouse_metric_SystemErrors_MEMORY_LIMIT_EXCEEDED[<W>]); max(chi_clickhouse_metric_DelayedInserts); max(chi_clickhouse_metric_MaxPartCountForPartition); sum by (active)(chi_clickhouse_table_parts{database="<db>",table="<log_table>"})` | `FailedInsertQuery` about 0, memory-exceeded flat, `DelayedInserts` 0, part count well below the delay-insert limit | failures with code 241 (memory limit) reject exporter inserts; cause chain and memory trend: [clickhouse.md](clickhouse.md). `active="0"` parts are outdated: never add them to active parts |
| Server error log rate | `rate(chi_clickhouse_event_LogError[<W>])` | near 0 | the cheap trigger for the SQL signature queries in section 6 |

`chi_clickhouse_event_InsertedRows` counts every table (including system log tables): it is not the ingest rate of the log table.

## 3. Conservation and lag

**Conservation across stages** (same window, same unit; tolerance a few percent, *interpreted*):

| Pair | Compare | A gap means |
|---|---|---|
| S1 IN vs S1 OUT | the two collector rows | the collector holds lines (retries, backpressure) |
| S1 OUT vs S2 IN | `sum(rate(fluentbit_output_proc_records_total{name="<out>"}[<W>]))` vs source `received` (lines) | lines lost or rejected between collector and aggregator: check non-200 and collector retries |
| S2 source `sent` vs S2 sink `sent` | requests | the buffer holds the difference: read depth |
| S1 OUT vs S4 arrival | `sum(rate(fluentbit_output_proc_records_total{name="<out>"}[<W>]))` vs `sum(deriv(chi_clickhouse_table_parts_rows{database="<db>",table="<log_table>",active="1"}[<W>]))` | lines are held in the aggregator buffer or the exporter, or insert fails |
| Exact completeness | a workload that logs a monotonic `seq` (query below) | `missing` > 0 after settling is real loss |

Exact completeness, for a producer that writes JSON with `seq` (end the window 1 minute before now so in-flight rows do not count):
```sql
SELECT <attrs>['k8s.pod.name'] pod, min(s) lo, max(s) hi, count() n, uniqExact(s) u, (hi-lo+1) - u AS missing
FROM (SELECT <attrs>, JSONExtractUInt(<body>,'seq') s FROM <db>.<log_table>
      WHERE <ts_pk> BETWEEN now() - INTERVAL 15 MINUTE AND now() - INTERVAL 1 MINUTE
        AND <attrs>['k8s.namespace.name']='<ns>' AND startsWith(<body>,'<producer_line_prefix>'))
GROUP BY pod
```
A small fraction of rows can arrive with an **empty attribute map** (collector multi-line path), so a pod filter reports them as missing. Search each missing seq by `position(<body>,'<pod>')>0` with `length(mapKeys(<attrs>))=0` before calling it lost. No stage meters a whole-path loss count, so these checks are the evidence.

**Lag** = now minus the newest event time:
```sql
SELECT now() AS now, max(<ts>) AS max_ts, dateDiff('second', max(<ts>), now()) AS lag_s, count() AS rows_10m
FROM <db>.<log_table> WHERE <ts_pk> > now() - INTERVAL 10 MINUTE
```
Healthy is the profile's log-age band (its Freshness probe; without a profile, 30 s or less, *interpreted*: collector flush interval plus batching). More than 60 s and growing means a stall. `<ts>` is the container write time, not the insert time, so lag is the end-to-end age and replayed rows keep their old times. A heavy scan can inflate lag by competing with inserts; keep this query bounded.

## 4. Localizing a stall (walk upstream from the sink)

1. **S4:** lag is growing, or the arrival rate fell. Go to step 2.
2. **Is the S2 buffer growing with sink `sent` at 0?**
   - **No**: the aggregator still ships. The fault sits between exporter and ClickHouse, or rows are merely delayed. Read exporter "Exporting failed" lines (section 5), `FailedInsertQuery`, and memory-exceeded errors.
   - **Yes, with `error_kind` showing connection refused**: the exporter is down or unreachable. Read its `kube_deployment_status_replicas_available`.
   - **Yes, with no client errors**: the exporter or ClickHouse is slow. Read sink RTT and `vector_utilization` near 1.
3. **S2 source `received` < S1 OUT:** the collector is not delivering. Read collector retries, errors, dropped, `busy == total`, non-200 responses, and aggregator `up` / ready. A full buffer with `when_full=block` shows up here as collector retries and backpressure wait.
4. **S1 IN itself fell:** read `ingestion_paused`, `storage_overlimit`, DaemonSet readiness, or check whether the workloads simply log less (per-namespace volume: `SELECT <attrs>['k8s.namespace.name'] ns, count() c, round(c/600,1) per_s FROM <db>.<log_table> WHERE <ts_pk> > now() - INTERVAL 10 MINUTE GROUP BY ns ORDER BY c DESC`).

Name the first stage whose neighbour pair is broken. When two stages remain possible, say the evidence does not pick one.

## 5. Blind hops

The exporter has no `/metrics`. Infer its state from five independent signals, then state it as *inferred*:

| Evidence | Query | Reads as |
|---|---|---|
| Upstream sink | section 2 rows "Requests through the pipeline", "Sink errors", "Buffer depth" | sent at 0, client errors, growing depth = exporter not accepting |
| Downstream arrival | S4 arrival rate vs S1 OUT | arrival below input while the sink still ships 200s = exporter accepted but cannot insert |
| Availability | `kube_deployment_status_replicas_available{namespace="<ns>",deployment="<exporter>"} / kube_deployment_spec_replicas{namespace="<ns>",deployment="<exporter>"}; kube_pod_status_ready{namespace="<ns>",pod=~"<exporter>-.*",condition="true"}` | available 0 = down. Readiness may be a bare TCP check, so Ready=1 does not prove inserts succeed |
| Traffic per pod | `sum by (pod)(rate(container_network_receive_bytes_total{namespace="<ns>",pod=~"<exporter>-.*"}[<W>]))` (and `_transmit_`) | total tracks the sink bytes. One pod near 0 = connection pinning (the aggregator's HTTP client keeps one connection to a ClusterIP), so one pod is a single point of saturation |
| Its own log lines | below | retry vs drop |

```sql
SELECT <attrs>['k8s.pod.name'] pod, countIf(<body> LIKE '%Exporting failed%') export_failed, countIf(<body> LIKE '%DbException(241%') ch241, count() total
FROM <db>.<log_table> WHERE <ts_pk> > now() - INTERVAL 1 HOUR AND <attrs>['k8s.pod.name'] LIKE '<exporter>-%' GROUP BY pod
```
```sql
SELECT multiIf(position(<body>,'dropping data')>0,'DROPPED',position(<body>,'will retry')>0,'retry','other') k, extract(<body>,'DbException\\((\\d+)') code,
       count(), min(<ts>), max(<ts>)
FROM <db>.<log_table> PREWHERE <ts_pk> >= now() - INTERVAL 1 HOUR AND hasToken(<body>,'Exporting')
WHERE <attrs>['k8s.container.name']='<exporter_container>' GROUP BY k, code ORDER BY 3 DESC SETTINGS max_threads=1
```
Healthy: `DROPPED` = 0 always (data loss) and retries near 0. Widen the window only within the limits of [clickhouse.md § 8](clickhouse.md#8-light-query-etiquette). Phrases are those of the exporter family seen here: confirm the wording on yours. Such an exporter logs retries at INFO and only a drop at ERROR.

Traps:
- **Green upstream does not clear the exporter.** An exporter that acks before inserting returns 200 to the aggregator while its own inserts fail. Aggregator metrics stay green; only the exporter log lines, `FailedInsertQuery` and the arrival rate show it.
- **The lines describing a stall are stuck behind it.** Aggregator WARN and exporter lines travel the same path, so they are not queryable until recovery (then they appear with their original `<ts>`). During a stall rely on metrics.
- **Collector logs are often excluded from collection** (to avoid a feedback loop): its problems appear only in `fluentbit_*` metrics. `fluentbit_logger_logs_total{message_type="error"}` counts its own error lines.

## 6. Classifying error rows

Order of work: metrics for WHEN and WHO (cheap), then SQL for WHY.

| Cheap trigger | Query | Healthy |
|---|---|---|
| ClickHouse server errors | `rate(chi_clickhouse_event_LogError[<W>])   and   rate(chi_clickhouse_event_LogWarning[<W>])` | near 0 |
| VictoriaMetrics components | `sum by (job, level) (increase(vm_log_messages_total{level=~"error\|warn\|fatal\|panic"}[<W>])) > 0` | 0 error/fatal; warn explained |
| Collector (its logs are not in the table) | `sum by (pod, message_type) (increase(fluentbit_logger_logs_total[<W>]))` | error 0, warn 0 |
| Crash loops | `sum by (namespace,pod,container) (increase(kube_pod_container_status_restarts_total[<W>])) > 0   ;   kube_pod_container_status_last_terminated_reason == 1` | restarts 0 outside planned operations; `OOMKilled` or `Error` names the container whose logs to pull |

Survey which columns carry severity before choosing a method:
```sql
SELECT count() rows, countIf(SeverityText!='') sev_txt, countIf(SeverityNumber>0) sev_num, countIf(ServiceName!='') svc, countIf(empty(ResourceAttributes)=0) res_attr, countIf(empty(LogAttributes)) empty_logattr FROM <db>.<log_table> WHERE <ts_pk> > now() - INTERVAL 1 HOUR
```
When `sev_txt` and `sev_num` are 0 on all rows (collector leaves severity empty and the aggregator passes OTLP unchanged), parse the level from `<body>`. If they are ever non-empty, the pipeline changed: use `SeverityText` instead.

`<LEVEL_EXPR>` (formats: ClickHouse header, JSON, klog, tab-separated Go loggers, Rust tracing, logfmt, collector `[ts] [level]`; the third branch sends any ClickHouse header line to `other`, so echoed queries cannot match later branches). Paste unchanged into the Grafana SQL editor; inside a JS string, double the backslashes again ([SKILL.md](../SKILL.md#reading-grafana-with-a-browser)):
```sql
multiIf(
  match(<body>, '^\\d{4}\\.\\d{2}\\.\\d{2} [0-9:.]+ \\[ *\\d+ *\\] \\{[^}]*\\} <(Error|Fatal|Critical)>'), 'error',
  match(<body>, '^\\d{4}\\.\\d{2}\\.\\d{2} [0-9:.]+ \\[ *\\d+ *\\] \\{[^}]*\\} <Warning>'), 'warn',
  match(<body>, '^\\d{4}\\.\\d{2}\\.\\d{2} [0-9:.]+ \\[ *\\d+ *\\] \\{'), 'other',
  match(<body>, '^\\{.*"level":\\s*"(?i:error|fatal|panic|dpanic|critical)"'), 'error',
  match(<body>, '^\\{.*"level":\\s*"(?i:warn|warning)"'), 'warn',
  match(<body>, '^[EF]\\d{4} \\d{2}:\\d{2}:\\d{2}\\.\\d+ '), 'error',
  match(<body>, '^W\\d{4} \\d{2}:\\d{2}:\\d{2}\\.\\d+ '), 'warn',
  match(<body>, '^\\S+\\t(?i:error|fatal|panic|dpanic)\\t'), 'error',
  match(<body>, '^\\S+\\t(?i:warn|warning)\\t'), 'warn',
  match(<body>, '^\\d{4}-\\d{2}-\\d{2}T\\S+Z\\s+ERROR\\s'), 'error',
  match(<body>, '^\\d{4}-\\d{2}-\\d{2}T\\S+Z\\s+WARN\\s'), 'warn',
  match(<body>, '(?:^|\\s)level="?(?i:error|eror|fatal|panic|crit|critical)\\b'), 'error',
  match(<body>, '(?:^|\\s)level="?(?i:warn|warning)\\b'), 'warn',
  match(<body>, '^\\[[^\\]]+\\]\\s*\\[\\s*(?i:error|fatal)\\s*\\]'), 'error',
  match(<body>, '^\\[[^\\]]+\\]\\s*\\[\\s*(?i:warn|warning)\\s*\\]'), 'warn',
  'other')
```
The JSON branch tolerates a space after the colon (some sidecars emit `"level": "INFO"`). The collector `[ts] [error]` branch was verified only on literal strings.

`<FP_EXPR>` collapses repeats of one cause into one row (strips the per-format header, masks uuid, hex, IP:port, query strings, pod-hash names, numbers). Without the header strip, one cause splits into several rows:
```sql
left(trim(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(
  replaceRegexpOne(<body>, '^(\\d{4}\\.\\d{2}\\.\\d{2} [0-9:.]+ \\[ *\\d+ *\\] \\{[^}]*\\} |\\d{4}-\\d{2}-\\d{2}[T ][0-9:.]+Z?\\s+|[IWEF]\\d{4} [0-9:.]+\\s+\\d+ |time="[^"]*" |logger=\\S+ t=\\S+ )', ''),
  '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<uuid>'),
  '0x[0-9a-fA-F]+|\\b[0-9a-f]{16,}\\b', '<hex>'),
  '\\d{1,3}(\\.\\d{1,3}){3}(:\\d+)?', '<ip>'),
  '\\?[^\\s;"]+', '?<qs>'),
  '\\b[a-z0-9]+(-[a-z0-9]+)*-[a-z0-9]{5,10}-[a-z0-9]{5}\\b', '<pod>'),
  '\\d+(\\.\\d+)?', 'N'),
  '\\s+', ' ')), 140)
```

| Question | Query | Reading |
|---|---|---|
| Top signatures now | `SELECT <LEVEL_EXPR> AS level, <attrs>['k8s.namespace.name'] AS ns, <attrs>['k8s.container.name'] AS ctr, <FP_EXPR> AS fingerprint, count() AS c, uniqExact(<attrs>['k8s.pod.name']) AS pods, min(<ts>) AS first_seen, max(<ts>) AS last_seen, substring(any(<body>),1,200) AS example FROM <db>.<log_table> PREWHERE <ts_pk> >= now() - INTERVAL 1 HOUR AND level = 'error' GROUP BY level, ns, ctr, fingerprint ORDER BY c DESC LIMIT 10` | compare with the previous hour or the pre-change window, not with zero. `first_seen` / `last_seen` give the onset and whether it still fires |
| Errors per minute (time series, format 0) | `SELECT toStartOfMinute(<ts>) AS t, concat(<attrs>['k8s.namespace.name'], '/', <attrs>['k8s.container.name']) AS series, count() AS errors FROM <db>.<log_table> PREWHERE <ts_pk> >= now() - INTERVAL 30 MINUTE AND <LEVEL_EXPR> = 'error' GROUP BY t, series ORDER BY t, series` | flat = baseline; a step at the change time is the regression |
| New signatures after a change | `WITH toDateTime('<change_time>') AS change_time SELECT <attrs>['k8s.namespace.name'] AS ns, <attrs>['k8s.container.name'] AS ctr, <FP_EXPR> AS fingerprint, min(<ts>) AS first_seen, max(<ts>) AS last_seen, count() AS c, countIf(<ts> < change_time) AS before_change FROM <db>.<log_table> PREWHERE <ts_pk> >= change_time - INTERVAL 1 HOUR AND <ts_pk> < change_time + INTERVAL 30 MINUTE AND <LEVEL_EXPR> IN ('error','warn') GROUP BY ns, ctr, fingerprint HAVING before_change = 0 ORDER BY first_seen LIMIT 30` | restart transients (unclean shutdown, cannot dial, auth failure during startup, broken pipe on scrape) are fine when `last_seen` stops within minutes of settling. New and still firing = the regression. Baseline length is a parameter; lengthen it for rare periodic errors |
| Failures logged at a low level | `SELECT <attrs>['k8s.container.name'] ctr, <FP_EXPR> fp, count() c FROM <db>.<log_table> PREWHERE <ts_pk> >= now() - INTERVAL 1 HOUR AND NOT match(<body>, '^\\d{4}\\.\\d{2}\\.\\d{2} [0-9:.]+ \\[') AND NOT match(<body>, '^\\d+\\. ') AND match(<body>, '(?i)\\b(fail(ed\|ure\|s)?\|errors?\|exception\|refused\|timed? ?out\|timeout\|unavailable\|denied\|panic\|oom\|killed\|broken pipe\|reset by peer)\\b') AND <LEVEL_EXPR> = 'other' GROUP BY ctr, fp ORDER BY c DESC LIMIT 15 SETTINGS max_threads=2` | catches INFO-level retries (such as exporter retry lines) that `<LEVEL_EXPR>` calls `other`. Excluding the ClickHouse header lines is mandatory, or `<Debug> executeQuery` echoes dominate |

Context for one signature: query the same pod's lines in the 5 minutes around `first_seen`, filtered by `<attrs>['k8s.pod.name']` and bounded on `<ts_pk>`. Filter by pod name, not `k8s.pod.uid` (the collector caches metadata by pod name, so a re-created pod keeps the old uid). A restarted container keeps its pod name, so pre-crash and startup lines are contiguous. Multi-line stack traces (Go, Rust, ClickHouse frames) arrive as separate rows.

Reading rules:
- **Own queries make errors.** ClickHouse logs every query it receives (`<Debug> executeQuery: (from <ip>, user: <u>) <sql>`) and, when its log is collected, that line lands in the table. A `LIKE '%needle%'` search matches your own query: anchor at the start of `<body>` or exclude the ClickHouse container. Your own denied `system.*` reads (code 497) and memory kills (241) also appear as top signatures: read the `executeQuery` echo with the same `{query_id}` before blaming the system.
- **Each ClickHouse failure is logged twice** (executor + task, or executeQuery + TCP/HTTP handler) and every stack frame is its own level-less row: halve counts to get events.
- Exclude replay or inspection containers that re-print old log tails: their Body time and pod name differ from the row.
- A container that should log but is absent from the inventory (quiet components log only on events, so judge over a window long enough for them to log; `SELECT <attrs>['k8s.namespace.name'] ns, <attrs>['k8s.container.name'] ctr, count() c FROM <db>.<log_table> WHERE <ts_pk> > now() - INTERVAL 1 HOUR GROUP BY ns, ctr ORDER BY c DESC LIMIT 80`) is a collection gap, not health: no errors for it proves nothing.
- Query cost: bound `<ts_pk>` first, put the level predicate in `PREWHERE`, use `hasToken(<body>,'<alphanumeric token>')` instead of `LIKE '%x%'` for windows over 1 h, always `LIMIT`. Rules and the server-memory chain: [clickhouse.md](clickhouse.md).

## 7. Outage shape and settling

Generic shape of a downstream outage (exporter or ClickHouse unavailable for minutes, then restored):

| Time | S1 collector | S2 aggregator | S3 / S4 |
|---|---|---|---|
| During | IN = OUT, retries flat (the buffer absorbs it) | sink `sent` 0, client errors, depth and bytes rise toward the buffer max | exporter available drops (or inserts fail); S4 arrival rate 0; lag grows |
| Recovery | unchanged | `sent` jumps above `received`, depth falls, sink utilization near 1, memory near its limit | arrival rate above S1 OUT (catch-up); lag falls |
| After | unchanged | depth near 0, `buffer in minus out` about 0 | arrival equals S1 OUT; lag a few seconds; SQL rows-per-minute by `<ts>` looks gap-free |

If the buffer reaches its max under `when_full=block`, the collector row changes too: retries and backpressure wait rise, and lines may wait in node log files.

Settle before judging. Declare the pipeline recovered only when all hold, over a window that starts after the last one became true:
- S2 buffer depth near 0 and `buffer in minus out` about 0.
- Lag back to a few seconds.
- S4 arrival rate back to S1 OUT (above it means still draining).
- Aggregator memory below 0.8 of its limit again.
- Exact completeness `missing` = 0 (or every missing seq found by Body search).

Until then the verdict is INCONCLUSIVE, with the missing condition named. An aggregator shutdown that exceeds its graceful limit leaves data on its volume: see section 8.

## 8. After changing a stage

- Scaling the aggregator: `kube_statefulset_status_replicas_ready` equals the desired replicas (`kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="<hpa>"}` when an HPA owns the count; otherwise the number the human set); every pod has `up == 1` and non-zero source `received`; the collector OUT - IN gap is about 0 with no new `retries_failed` or `dropped`; lag and arrival return to normal; completeness `missing` = 0.
- A removed aggregator pod: its shutdown lines show `remaining_components="<sink_id>"` with a falling `time_remaining` and then "Vector has stopped". Reaching a low `time_remaining` without that line suggests the graceful limit was hit. Query: `SELECT <attrs>['k8s.pod.name'] pod, substring(replaceRegexpAll(<body>,'^\\S+\\s+',''),1,160) msg, count() c, min(<ts>) first FROM <db>.<log_table> WHERE <ts_pk> BETWEEN '<from>' AND '<to>' AND <attrs>['k8s.namespace.name']='<ns>' GROUP BY pod,msg ORDER BY first LIMIT 40`. Lines such as "Retrying after error" are sink retries.
- Memory, CPU or volume change: working set against `kube_pod_container_resource_limits` (headroom for replay), restarts and `last_terminated_reason`; for a volume resize, `vector_buffer_size_bytes` against `vector_buffer_max_size_bytes` (set in the aggregator config, independent of the volume size), and `kube_persistentvolumeclaim_resource_requests_storage_bytes`.

## 9. Not observable

| Fact | Closest proxy |
|---|---|
| Exporter throughput, queue, retries, insert success (no scrape target) | section 5 |
| Insert time per row (no insert-time column; `<ts>` is the container write time) | live: S4 arrival rate and `now() - max(<ts>)` |
| Collector's own error lines (excluded from collection) | `fluentbit_output_*`, `fluentbit_logger_logs_total` |
| Volume usage of the aggregator's buffer volume (`kubelet_volume_stats_*` missing for some volume plugins) | `vector_buffer_size_bytes` against `vector_buffer_max_size_bytes` |
| Buffer left on the volume of a removed aggregator pod (its series stop with the pod) | last `max_over_time(vector_buffer_size_events{buffer_id="<sink_id>",pod="<pod>"}[<W>])` before it vanished, its shutdown log lines, and the completeness check |
| Aggregator error and discard counters (absent until the first error) | `vector_http_client_errors_total`, non-200 source responses, buffer growth, its WARN/ERROR rows through `<LEVEL_EXPR>` |
| Whole-path loss count | `fluentbit_output_dropped_records_total`, the exporter's `DROPPED` rows, and the `seq` completeness check |
| ClickHouse `system.*` (parts, query_log, errors) when the reader lacks grants (code 497) | `chi_clickhouse_*` metrics and ClickHouse's own log rows |
| Control-plane or unscheduled-node pod logs (the collector DaemonSet may not run there) | `kube_pod_container_status_restarts_total`, `last_terminated_reason`, and client-side errors in collected logs |
| The application's own timestamp | `<ts>` is the runtime's line time; parse the timestamp inside `<body>` if exact app time matters |
