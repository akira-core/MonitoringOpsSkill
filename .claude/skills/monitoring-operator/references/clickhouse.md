# ClickHouse health with a read-only user: exporter metrics first, SQL second, server log lines for the why

Contents: [Reading order](#reading-order) · [What read-only can see](#1-what-a-read-only-sql-user-can-and-cannot-see) · [Reachability and restarts](#2-reachability-and-restart-detection) · [Insert path](#3-insert-path) · [Parts and merges](#4-parts-and-merges) · [Memory-saturation chain](#5-memory-saturation-chain-worked-example) · [Post-change proofs](#6-post-change-proofs) · [Server log lines](#7-reading-clickhouses-own-server-log-lines) · [Light-query etiquette](#8-light-query-etiquette) · [Not observable](#9-not-observable-read-only)

Placeholders: `<w>` = a rate/increase window of at least 4x the exporter scrape interval and at least the interval you are judging (profile: Freshness). `<chi>` = installation label, `<ch_ns>` / `<ch_pod>` = the ClickHouse server's namespace and pod, `<logs>` = the logs table, `<tkey>` = its DateTime column in the primary key, `<pod_col>` = the expression holding the pod name (profile: Logs). Label traps (the exporter's `pod` is the operator pod): [sop-translation.md](sop-translation.md#label-traps-read-these-before-writing-queries). Command-to-signal rows for `system.*`: [sop-translation.md § ClickHouse](sop-translation.md#clickhouse-database-status). Container CPU/memory/PVC signals: [kubernetes-resources.md](kubernetes-resources.md). Shipping path of the logs you read in section 7: [log-pipeline.md](log-pipeline.md). Datasource mechanics: [SKILL.md](../SKILL.md).

## Reading order

Check cheap, always-on metrics first; use SQL only to answer "why" and only with bounded windows.

1. **Is it reachable, did it restart?** `fetch_errors`, `Uptime`, pod restarts ([section 2](#2-reachability-and-restart-detection)).
2. **Is data landing?** Async-insert rate against the sender's rate, failed inserts, delayed inserts ([section 3](#3-insert-path)).
3. **Are parts and merges keeping up?** Active parts trend, `MaxPartCountForPartition`, merge work against insert work ([section 4](#4-parts-and-merges)).
4. **Is memory the root cause?** RSS against the effective server limit, then `MEMORY_LIMIT_EXCEEDED` rate ([section 5](#5-memory-saturation-chain-worked-example)). Memory saturation is the usual hidden cause behind items 2 and 3 on a small server.
5. **Why exactly?** Server log lines grouped by level, logger, message template, task id ([section 7](#7-reading-clickhouses-own-server-log-lines)).

A frozen exporter makes every `chi_*` value stale without turning it to 0: read `fetch_errors` and the Freshness probe before trusting any value below. A `chi_*` series that is absent is not 0 (see [Absent is not zero](#absent-is-not-zero)).

## 1. What a read-only SQL user can and cannot see

Grafana's ClickHouse user usually has `readonly=2` and SELECT on the application database only. Every `system.*` table other than the few below returns **code 497 ACCESS_DENIED**. Each denied probe adds to `SystemErrors_ACCESS_DENIED` and `FailedQuery` and writes an `<Error>` line, so probe a denied table once, then switch to the exporter.

| Works as SQL | Denied (code 497), use the exporter instead |
|---|---|
| `SELECT version(), uptime(), currentUser(), hostName(), timezone(), now()` | `system.parts`, `merges`, `mutations`, `processes`, `query_log`, `text_log`, `errors`, `events`, `metrics`, `asynchronous_metrics`, `disks`, `replicas`, `merge_tree_settings`, `server_settings`, `SHOW PROCESSLIST` |
| `SELECT getSetting('readonly')`, `SELECT getServerSetting('max_server_memory_usage'), getServerSetting('max_server_memory_usage_to_ram_ratio')`, `SHOW GRANTS` | |
| `DESCRIBE TABLE <db>.<t>`, `SHOW CREATE TABLE <db>.<t>` | |
| `system.one`, `system.settings`, `system.columns` and `system.tables` (rows filtered to granted tables) | |

`SELECT name, engine, total_rows, formatReadableSize(total_bytes), parts, active_parts, partition_key, sorting_key FROM system.tables WHERE database='<db>'` gives rows, compressed size and active parts of your own tables.

`readonly=2` allows a per-query `SETTINGS` clause; `readonly=1` rejects it (code 164). Do not append `FORMAT` through the Grafana plugin: it sets the format.

**What each source proves**

| Source | Proves | Does not prove |
|---|---|---|
| `up{job="<operator exporter job>"}` | the exporter answered | ClickHouse is reachable |
| `chi_clickhouse_metric_fetch_errors == 0` (all `fetch_type` series) and `chi_clickhouse_metric_Uptime` increasing | the exporter can query ClickHouse right now | that user queries or inserts succeed |
| SQL `SELECT version(), uptime()` | the SQL path (Grafana user, network, auth) works | exporter health |
| rows arriving in `<logs>` (`SELECT count(), max(<tkey>) …`) | end-to-end ingest | why it is slow or failing |

## 2. Reachability and restart detection

| Signal | Query | Healthy / PASS | Deviation means |
|---|---|---|---|
| Exporter targets | `up{job="<operator exporter job>"}` | both targets (`endpoint=ch-metrics` for `chi_*`, `endpoint=op-metrics` for `clickhouse_operator_*`) equal 1 | exporter down: every `chi_*` value is stale |
| Exporter to server | `chi_clickhouse_metric_fetch_errors` and `max_over_time(chi_clickhouse_metric_fetch_errors[10m]) > 0` | 7 series (`fetch_type=system_metrics, system_parts, system_disks, system_mutations, system_replicas, system_detached_parts, table_sizes`) all 0; the second query returns nothing | non-zero: exporter cannot query ClickHouse (pod down, auth or network rejected); a sustained value after an operator restart is the failure, 1-2 transient `IP_ADDRESS_NOT_ALLOWED` / `AUTHENTICATION_FAILED` counts are not |
| Uptime | `chi_clickhouse_metric_Uptime` (seconds) | increasing, and larger than the time since your last operation | smaller than the time since the operation: the server restarted. Expected after a CPU/memory/PVC change, a finding otherwise |
| Version | `chi_clickhouse_metric_VersionInteger` (major*1e6 + minor*1e3 + patch) | unchanged after non-upgrade work; equals the target after an upgrade | the SQL `version()` gives the full string, so compare the two |
| Restart attribution | `kube_pod_container_status_restarts_total{namespace="<ch_ns>"}` with `kube_pod_container_status_last_terminated_reason{namespace="<ch_ns>"}` | no increase outside planned work | reason `OOMKilled`: memory limit too low. `Unknown`/`Error` on every container at the same instant: node or runtime restart, not memory. Read the reason before blaming memory |
| Server-side clock | SQL `SELECT uptime()` | within a scrape interval of `Uptime` | cross-check when the exporter is suspect |

`Uptime` and the `chi_clickhouse_event_*` / `SystemErrors_*` counters reset on restart. After the exporter's own pod restarts, series split by `instance`: aggregate with `sum without(instance, pod)` or `max without(instance, pod)` for trends that cross it.

## 3. Insert path

ClickHouse-side facts for an OTLP/HTTP sender using `async_insert`: rows are buffered in the async-insert queue, flushed, and the sender's HTTP call returns only after the flush (`WaitForAsyncInsert`). A flush failure therefore reaches the sender as an HTTP error, and the sender's own retry/buffer decides whether data is lost (sender signals: [log-pipeline.md](log-pipeline.md)).

| Signal | Query | Healthy / PASS | Deviation means |
|---|---|---|---|
| User ingest rate | `rate(chi_clickhouse_event_AsyncInsertRows[<w>])`, `rate(chi_clickhouse_event_AsyncInsertBytes[<w>])`, `rate(chi_clickhouse_event_AsyncInsertQuery[<w>])` | stable and equal to the sender's rate; cross-check: rows/s equals SQL `rows per minute / 60` within a few percent | drop to 0 with healthy senders: inserts are not landing. A gap between the two sources: log shipping lags or the exporter is stale (check `fetch_errors`) |
| Total written rows | `rate(chi_clickhouse_event_InsertedRows[<w>])`, `rate(chi_clickhouse_event_InsertedBytes[<w>])` | informational only | includes ClickHouse's own `system.*_log` writes; never use it as the user ingest rate |
| Failed inserts | `sum(increase(chi_clickhouse_event_FailedInsertQuery[<w>]))`, `sum(increase(chi_clickhouse_event_FailedAsyncInsertQuery[<w>]))` | 0 | bursts: the sender got HTTP errors and must retry; confirm the sender did not drop. A pod recreate causes a brief burst by itself |
| Async queue backlog | `chi_clickhouse_metric_PendingAsyncInsert`, `chi_clickhouse_metric_AsynchronousInsertQueueSize`, `chi_clickhouse_metric_AsynchronousInsertQueueBytes` | near 0 between flushes | sustained growth: flushes failing or slow |
| Delayed inserts | `sum(increase(chi_clickhouse_event_DelayedInserts[<w>])) or vector(0)` ; instant gauge `chi_clickhouse_metric_DelayedInserts` | 0 | above 0: a partition crossed `parts_to_delay_insert` ([section 4](#4-parts-and-merges)). The event counter is cumulative since start, so read its `increase` over the window you judge (the Altinity rules do); the gauge alone misses short delays |
| Rejected / TOO_MANY_PARTS | `sum(increase(chi_clickhouse_event_RejectedInserts[<w>])) or vector(0)`, `sum(increase(chi_clickhouse_metric_SystemErrors_TOO_MANY_PARTS[<w>])) or vector(0)` | 0 | above 0 inside the window: inserts are being refused. A cumulative counter compared with `> 0` stays true until the next restart, so always take the `increase`. These series exist only after first firing |
| Insert errors in the log | section 7 queries, filter loggers `AsynchronousInsertQueue` and `DynamicQueryHandler` | none | `AsynchronousInsertQueue: Failed insertion for query 'INSERT INTO <db>.<logs> …'` plus `DynamicQueryHandler … WaitForAsyncInsert (MEMORY_LIMIT_EXCEEDED)` is an insert killed by memory |
| Connections / queries | `chi_clickhouse_metric_Query`, `chi_clickhouse_metric_LongestRunningQuery`, `chi_clickhouse_metric_HTTPConnection`, `chi_clickhouse_metric_TCPConnection`, `chi_clickhouse_metric_HTTPRejectedConnections`, `chi_clickhouse_metric_TCPRejectedConnections` | few queries; longest query seconds-scale (interpreted); rejected 0 | rejected above 0: connection limit reached |
| Failed queries | `rate(chi_clickhouse_event_FailedQuery[<w>])`, `chi_clickhouse_event_FailedSelectQuery` | about 0 apart from the operator's own probes | subtract the failing probes you fired yourself before reporting |

Inserts counted by `InsertQuery` do not appear for async senders; use the `AsyncInsert*` family.

## 4. Parts and merges

Every insert creates a part; background merges combine parts. When merges fall behind, active parts per partition climb, ClickHouse first delays inserts (`parts_to_delay_insert`) and then rejects them with `TOO_MANY_PARTS` (`parts_to_throw_insert`). The two thresholds are unreadable with a read-only user (`system.merge_tree_settings` is denied). ClickHouse 25.x defaults are 1000 and 3000 per partition; confirm for your version in the product docs. The trend is the early warning, not the absolute count.

| Signal | Query | Healthy / PASS | Deviation means |
|---|---|---|---|
| Active vs outdated parts per table | `chi_clickhouse_table_parts{database="<db>"}`, `chi_clickhouse_table_partitions{database="<db>"}`, `topk(5, chi_clickhouse_table_parts{active="1"})` | active parts steady and far below the delay threshold; outdated parts (`active="0"`) are normal and removed after minutes | active parts climbing steadily: merges are not keeping up or are failing |
| Worst partition, server-wide | `chi_clickhouse_metric_MaxPartCountForPartition` | far below `parts_to_delay_insert`, not rising | rising: find the table with `topk(5, chi_clickhouse_table_parts{active="1"})`; it may be a `system.*` table, not yours |
| Merge activity | `chi_clickhouse_metric_Merge`, `rate(chi_clickhouse_event_Merge[<w>])`, `chi_clickhouse_metric_BackgroundMergesAndMutationsPoolTask / chi_clickhouse_metric_BackgroundMergesAndMutationsPoolSize` | pool occupancy well below 1 | near 1: merge backlog |
| Write amplification | `rate(chi_clickhouse_event_MergedRows[<w>]) / rate(chi_clickhouse_event_InsertedRows[<w>])` | a small multiple (under about 10, interpreted: normal merge amplification is a few x) | far higher (tens to hundreds): merges restart and fail repeatedly, burning CPU and memory for nothing ([section 5](#5-memory-saturation-chain-worked-example)) |
| Mutations | `chi_clickhouse_metric_PartMutation` | 0 for append-only log tables | above 0 for long: a mutation is stuck; detail needs `system.mutations` (denied), so use `fetch_errors{fetch_type="system_mutations"}` and `<Error>` lines |
| Who owns the disk | `topk(6, chi_clickhouse_table_parts_bytes{active="1"})`, `sum(chi_clickhouse_table_parts_bytes{database="system"})` | user tables dominate | `system.*` log tables dominating: their TTL or log level needs tuning (a human step) |
| Disk health | `chi_clickhouse_metric_ReadonlyDisks`, `chi_clickhouse_metric_BrokenDisks` | 0 always | above 0: the disk is read-only or broken |
| Data vs volume size (fill proxy) | `chi_clickhouse_metric_DiskDataBytes / on() kube_persistentvolumeclaim_resource_requests_storage_bytes{namespace="<ch_ns>", persistentvolumeclaim="<pvc>"}` | under 0.8 (interpreted) | `DiskTotalBytes` / `DiskFreeBytes` report the node filesystem on volume plugins without enforced capacity; use this ratio instead. After a PVC resize the denominator changes |
| Replication | `chi_clickhouse_metric_ReadonlyReplica`, `chi_clickhouse_metric_ReplicasMaxAbsoluteDelay`, `chi_clickhouse_metric_AttachedReplicatedTable` | replicated installs: `ReadonlyReplica` 0, delay under 300 s (interpreted) | `AttachedReplicatedTable` 0 means a single plain MergeTree: these are 0 by construction and prove nothing |

## 5. Memory-saturation chain (worked example)

The server enforces its memory limit on **RSS**: `max_server_memory_usage_to_ram_ratio` (default 0.9, read it with `getServerSetting`) times the cgroup memory total. Error text names it: `current RSS: X GiB, maximum: Y GiB`. `MemoryTracking` under-states pressure and `CGroupMemoryUsed` over-states it (page cache), so judge by RSS.

**Causal chain** (each step produces the signal in the next row):

1. RSS reaches the effective limit.
2. The largest background merges (wide tables such as `system.metric_log`) cannot allocate and fail with code 241 `MEMORY_LIMIT_EXCEEDED`; the scheduler retries them at once.
3. Each failure writes two `<Error>` lines (executor + task), so `LogError` and `SystemErrors_MEMORY_LIMIT_EXCEEDED` climb.
4. Merges restart from zero: `MergedRows` runs far above `InsertedRows`; parts accumulate.
5. The memory tracker's overcommit mechanism kills whichever query or insert is the best victim, not necessarily the one that over-allocated: async inserts fail (`FailedAsyncInsertQuery`), operator and Grafana SELECTs die (`FailedSelectQuery`), your own diagnostic query can die.
6. The sender sees HTTP 5xx with `DbException(241`, retries, and its buffer grows.
7. If the working set also touches the Kubernetes limit, the container is OOMKilled (restart, `Uptime` resets).

**Order to read the signals**

| Step | Signal | Query | Healthy / PASS | Deviation means |
|---|---|---|---|---|
| 1 | RSS against the effective limit | `chi_clickhouse_metric_MemoryResident / (0.9 * chi_clickhouse_metric_CGroupMemoryTotal)` and `max_over_time(chi_clickhouse_metric_MemoryResident[1h])` | under 0.8 sustained (interpreted); 1.0 = the cap by arithmetic | 0.9 or more with step 2 rising: saturated. Replace `0.9` with the value from `getServerSetting` if it differs |
| 2 | Memory-limit errors | `rate(chi_clickhouse_metric_SystemErrors_MEMORY_LIMIT_EXCEEDED[<w>])` | 0 | any sustained rate: the server hits its ceiling. It is a cumulative counter despite the `metric` prefix: always `rate`/`increase` |
| 3 | Server error-line rate | `rate(chi_clickhouse_event_LogError[<w>])` and `rate(chi_clickhouse_event_LogWarning[<w>])` | about 0 | above 0: group the `<Error>` lines by logger ([section 7](#7-reading-clickhouses-own-server-log-lines)). Cross-check: `rate(LogError)` is about the SQL `<Error>` rows per second |
| 4 | Loggers and template | section 7 queries | none | background loggers (`MergeTreeBackgroundExecutor`, `MergePlainMergeTreeTask`) = merges failing |
| 5 | Which table | task-id resolution in section 7 | no repeating task id | one id repeating is one table's merge failing in a loop |
| 6 | Wasted merge work and parts | the write-amplification and `MaxPartCountForPartition` rows in section 4 | small multiple, flat | high ratio plus rising parts: the loop is real |
| 7 | Inserts hurt | `sum(increase(chi_clickhouse_event_FailedAsyncInsertQuery[<w>]))` plus sender retry signals | 0 | bursts: sender retries; check the sender dropped nothing |
| 8 | Kubernetes limit | `max_over_time(container_memory_working_set_bytes{namespace="<ch_ns>", pod="<ch_pod>", container="clickhouse"}[1h]) / on() kube_pod_container_resource_limits{namespace="<ch_ns>", pod="<ch_pod>", resource="memory"}` | under 0.9 (interpreted) | near 1: OOMKill risk; confirm with `last_terminated_reason`. Memory in `job=kubelet` is the cAdvisor path |
| 9 | Who consumes it | `chi_clickhouse_metric_MemoryTracking`, `max_over_time(chi_clickhouse_metric_MergesMutationsMemoryTracking[1h])` | informational | a high merge/mutation peak points at merges as the consumer |

Report the stage that stands (RSS at cap, merges failing, inserts killed) and the evidence rows. Remediation is a **HUMAN step**: raise `limits.memory`, trim or shorten TTL of `system.*` log tables, lower the server log level (ClickHouse's own Debug logs, shipped back into its own log table, feed the load), reduce merge or query memory.

CPU: `rate(container_cpu_usage_seconds_total{namespace="<ch_ns>", container="clickhouse"}[<w>])` against `requests.cpu`. Throttling series exist only when `limits.cpu` is set; absence of `container_cpu_cfs_throttled_periods_total` means no CPU limit, not a healthy ratio.

## 6. Post-change proofs

After a CPU, memory or PVC change made through the operator's installation resource, collect these rows. A change is **proved** only when applied, reconciled and healthy.

| Proof | Query | PASS | Deviation means |
|---|---|---|---|
| Reconcile ran | `clickhouse_operator_chi_reconciles_started`, `clickhouse_operator_chi_reconciles_completed` | both incremented since the change and `completed == started` | `started > completed` and flat: reconcile in progress or stuck. Counters reset when the operator pod restarts |
| Reconcile clean | `clickhouse_operator_chi_reconciles_aborted`, `clickhouse_operator_host_reconciles_errors` | unchanged and 0 | any increase: the operator could not apply the change |
| Reconcile duration | `histogram_quantile(0.9, sum by (le)(rate(clickhouse_operator_chi_reconciles_timings_bucket[1d])))` | informational | use as the "how long to wait" estimate before declaring a stuck reconcile |
| Limits applied | `kube_pod_container_resource_limits{namespace="<ch_ns>", pod="<ch_pod>"}` and `kube_pod_container_resource_requests{namespace="<ch_ns>", pod="<ch_pod>"}` | equal the intended values | old values: change not rolled out yet |
| Server sees the memory limit | `chi_clickhouse_metric_CGroupMemoryTotal` | equals the new `limits.memory` in bytes | old value: the server has not restarted into the new limit |
| PVC resized | `kube_persistentvolumeclaim_resource_requests_storage_bytes{namespace="<ch_ns>", persistentvolumeclaim="<pvc>"}` | equals the new size | the request changed but a filesystem-level resize is not observable ([section 9](#9-not-observable-read-only)) |
| Restarted | `chi_clickhouse_metric_Uptime` | smaller than the time since the change (a CPU/memory/PVC change recreates the pod) | no reset after a change that needs a restart: not rolled out |
| Ingest recovered | `rate(chi_clickhouse_event_AsyncInsertRows[<w>])`, SQL `SELECT toStartOfMinute(<tkey>) m, count() c FROM <db>.<logs> WHERE <tkey> >= now() - 600 GROUP BY m ORDER BY m` | back to the pre-change level; ignore the partial first and last minute | a dip that persists: ingest still failing |
| Freshness | `SELECT now() n, max(Timestamp) mx, dateDiff('second', max(Timestamp), now64(9)) lag_s, count() rows_5m FROM <db>.<logs> WHERE <tkey> >= now() - 300` | lag under about 30 s (interpreted: one shipper flush plus clock skew) | minutes of lag: backpressure in the shipping path or insert failures |
| No new failures | `increase(chi_clickhouse_event_FailedInsertQuery[<w>])`, `increase(chi_clickhouse_event_FailedAsyncInsertQuery[<w>])`, `rate(chi_clickhouse_metric_SystemErrors_MEMORY_LIMIT_EXCEEDED[<w>])`, `rate(chi_clickhouse_event_LogError[<w>])`, `chi_clickhouse_metric_DelayedInserts` | 0 after the change window; rates at or below the pre-change baseline | the pod recreate itself causes a short failure burst; judge after it settles, and confirm the sender's buffer drained |
| Operator-pod side effect | `increase(chi_clickhouse_metric_SystemErrors_IP_ADDRESS_NOT_ALLOWED[<w>])` | a small one-off count right after an operator restart | sustained: `fetch_errors` turns non-zero too |

Exporter metrics trail the change by up to two scrape intervals: read again before declaring a proof failed.

## 7. Reading ClickHouse's own server log lines

When the server's stderr is shipped into a SQL table, its lines carry the level only in `Body`, and `SeverityText` is usually empty for such shippers. Format: `YYYY.MM.DD HH:MM:SS.micro [ <thread> ] {<query_id or empty>} <Level> <Logger>: <message>`. Stack frames (`26. DB::MergeTask::execute() @ 0x…`) are separate rows with no level. ClickHouse logs **every query it receives**, and again inside `<Error>` lines when the query fails, so `Body LIKE '%needle%'` and a bare `'%Error%'` match your own query. **Anchor the level at the start of `Body`.** The regexes below are shown as sent to ClickHouse; for JS-string escaping see [SKILL.md](../SKILL.md#reading-grafana-with-a-browser).

Level counts for one server pod (window 2 minutes; filter the server's pod with `<pod_col>`):

```sql
SELECT extract(Body, '^\\S+ \\S+ \\[ *\\d+ *\\] \\{[^}]*\\} <([A-Za-z]+)>') lvl, count() c
FROM <db>.<logs>
WHERE <tkey> >= now() - 120 AND <pod_col> = '<ch_pod>'
GROUP BY lvl ORDER BY c DESC SETTINGS max_threads=1
```

An empty `lvl` is a stack-frame continuation row. `Error` should be about 0.

`<Error>` lines by logger (separates server problems from failed client queries):

```sql
SELECT extract(Body, '} <Error> ([A-Za-z_.() 0-9-]+?):') logger, count() c
FROM <db>.<logs>
WHERE <tkey> >= now() - 120 AND match(Body, '^\\S+ \\S+ \\[ *\\d+ *\\] \\{[^}]*\\} <Error>')
GROUP BY logger ORDER BY c DESC LIMIT 10 SETTINGS max_threads=1
```

Message templates with numbers normalised (root-cause summary):

```sql
SELECT substring(replaceRegexpAll(extract(Body, '<Error> (.*)'), '[0-9]+', 'N'),1,200) msg, count() c
FROM <db>.<logs>
WHERE <tkey> >= now() - 120 AND match(Body, '^\\S+ \\S+ \\[ *\\d+ *\\] \\{[^}]*\\} <Error>') AND <pod_col> = '<ch_pod>'
GROUP BY msg ORDER BY c DESC LIMIT 10 SETTINGS max_threads=1
```

**Reading loggers**

| Logger | Meaning | Whose problem |
|---|---|---|
| `MergeTreeBackgroundExecutor`, `MergePlainMergeTreeTask` (`DB::MergePlainMergeTreeTask::executeStep()`, often truncated at `::`) | a background merge failed | server (memory, disk, corrupt part) |
| `AsynchronousInsertQueue` | an async-insert flush failed | server; the sender sees an error |
| `DynamicQueryHandler` | an HTTP query failed (inserts from HTTP senders, Grafana) | the client's query, which may be yours |
| `executeQuery`, `TCPHandler` | a query over the native protocol failed | the client's query, which may be yours |
| `Access(user directories)` at `<Information>` | `Authentication failed: Code: 195 … IP_ADDRESS_NOT_ALLOWED` for a user whose allowed networks lack the caller's address | the operator or a client network/credential issue |

Every failure is logged twice (executor + task, or `executeQuery` + handler): divide by 2 for events. Before reporting a `Code: 497` or `Code: 241` line from `executeQuery`/`TCPHandler`, open the matching `<Debug> executeQuery: (from <ip>, user: <u>)` echo with the same `{query_id}`: if it came from your own user and the Grafana or localhost address, you caused it.

**Task id to table.** A failing merge names `{<table_uuid>::<partition>_<min>_<max>_<level>}`. `system.tables` shows only granted tables, so resolve a `system.*` uuid from other log lines:

```sql
SELECT extract(Body, 'background task \\{([0-9a-f-]+)::') u, count() c FROM <db>.<logs>
WHERE <tkey> >= now() - 120 AND Body LIKE '%MergeTreeBackgroundExecutor: Exception while executing background task%'
  AND match(Body, '^\\S+ \\S+ \\[ *\\d+ *\\] \\{[^}]*\\} <Error>') GROUP BY u
```

then `SELECT extract(Body, '} <[A-Za-z]+> ([a-z_]+\\.[a-z_0-9]+) \\(<uuid>') t, count() FROM <db>.<logs> WHERE <tkey> >= now() - 300 AND Body LIKE '%> system.% (<uuid>%' GROUP BY t` with the uuid from the first result.

Cross-checks that validate the plumbing: `rate(chi_clickhouse_event_LogError[<w>])` about equals SQL `<Error>` rows per second; `rate(AsyncInsertRows)` about equals SQL rows per minute / 60. A divergence means the log shipper lags or the exporter is stale.

## 8. Light-query etiquette

A server near its memory cap kills the cheapest-to-kill allocation, which can be a sender's insert instead of your query. Read metrics first; they cost the database nothing.

- **Bound every SQL query** on the primary-key time column (`<tkey>`, DateTime). A filter on a nanosecond `Timestamp` column that is not in the primary key reads every granule. Check with `EXPLAIN indexes=1 SELECT count() FROM <db>.<logs> WHERE <tkey> > now() - INTERVAL 1 HOUR`.
- **Window**: 1 hour or less for scans that read map columns or `Body`; 2-5 minutes (with `max_threads=1`) when the server is already failing queries with 241; count-only queries that read neither a map column nor `Body` are cheap at 10 minutes. 6 hours or more may fail with 241.
- **Put the selective predicate in `PREWHERE`** so `Body` is filtered before the map column is read; `LIMIT` every query.
- **Long windows**: use `hasToken(Body, '<whole alphanumeric token>')` (token index, case-sensitive; `prestop-drain` needs two tokens) instead of `LIKE '%x%'`, which cannot use the index.
- **Cap your own query** so it fails alone: `SETTINGS max_threads=2, max_memory_usage=268435456` (accepted under `readonly=2`). If the setting is rejected (code 164), drop it and shorten the window.
- **One heavy query at a time.** Do not open a dashboard with many ClickHouse panels while the server is saturated; use `viewPanel` for one panel (see [SKILL.md](../SKILL.md#reading-grafana-with-a-browser)).
- **Count your own failures.** Denied probes and killed queries raise `SystemErrors_ACCESS_DENIED`, `FailedQuery`, `FailedSelectQuery` and add `<Error>` lines. Note the count of failing queries you fired, and subtract it before reporting a rise.
- `sample` is a reserved word in ClickHouse SQL: do not use it as an alias.

### Absent is not zero

`system.events` and `system.errors` list only counters that have fired, so `chi_clickhouse_event_RejectedInserts`, `chi_clickhouse_event_DelayedInserts`, `SystemErrors_TOO_MANY_PARTS`, `SystemErrors_READONLY` and `chi_clickhouse_event_InsertQuery` (async senders) can return no series. Append `or vector(0)` for a "has it ever fired" check and read "no data" as "never fired since start", not as an outage. Check `Uptime` before concluding that the counter never fired in your window: a restart resets it.

## 9. Not observable read-only

| Fact | Closest proxy |
|---|---|
| Fill level of the data volume | `DiskDataBytes` (or `sum(chi_clickhouse_table_parts_bytes)`) divided by the PVC request ([section 4](#4-parts-and-merges)); `kubelet_volume_stats_*` exists only for volume plugins that export it ([sop-translation.md](sop-translation.md)) |
| `parts_to_delay_insert`, `parts_to_throw_insert`, any `system.merge_tree_settings` / `system.server_settings` value | the 25.x defaults above; `DelayedInserts`, `MaxPartCountForPartition` trend; `getServerSetting('<name>')` for the few server settings it can read |
| Parts per partition per table | `chi_clickhouse_table_parts{active="1"}` divided by `chi_clickhouse_table_partitions{active="1"}` as an average, plus server-wide `MaxPartCountForPartition` |
| Text, duration and user of running or failed queries (`system.processes`, `system.query_log`) | `Query`, `LongestRunningQuery`, `FailedQuery` rate; failed query text in `<Error> executeQuery` / `TCPHandler` / `DynamicQueryHandler` lines |
| Merge and mutation detail (progress, memory, which mutation is stuck) | `Merge`, `PartMutation`, `rate(Merge)`, `MergesMutationsMemoryTracking`, `fetch_errors{fetch_type="system_mutations"}`, `<Error> MergeTreeBackgroundExecutor` lines |
| Exact log arrival latency | no insert-time column in the standard schema: `dateDiff('second', max(Timestamp), now64(9))` over 5 minutes (conflates clock skew with pipeline delay), or a marker line you can cause and search for |
| Meaningful replication delay on a single replica | `ReadonlyDisks`, `BrokenDisks`; in replicated installs `ReadonlyReplica`, `ReplicasMaxAbsoluteDelay` |
| Severity as a column | parse the level from `Body` (section 7) |
| Filesystem-level result of a PVC resize | the new request in kube-state-metrics, then data growth without errors |
