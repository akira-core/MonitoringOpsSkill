# Profile: monops kind lab

Every fact in this file is about this repo's kind cluster `monops` and its Grafana. Field meanings
are in [SKILL.md § Profiles](../../SKILL.md#profiles).

Facts marked *after rebuild* were re-measured on 2026-11-07, about 30 minutes after the lab was
rebuilt on Kubernetes v1.31.14. Facts marked *earlier* come from 2026-11-05/06 on the previous
cluster and were not re-measured.

## Match

Applies when `/api/search` finds dashboard uid `scaledown-verify`, or `/api/frontend/settings` lists
both a datasource `VictoriaMetrics` (type `prometheus`) and `ClickHouse`
(type `grafana-clickhouse-datasource`). The Grafana is usually a port-forward on `127.0.0.1:3000`
(`make grafana`) or `:3300`.

## Platform

- Kubernetes v1.31.14 on three kind nodes (control-plane, `monops-worker`, `monops-worker2`), kind v0.31.0, arm64.
  The node image `kindest/node:v1.31.14` is pinned by digest in `kind/cluster.yaml`, because kind v0.31 defaults to 1.35.
- **In-place pod resize is unavailable.** It is alpha and gated off on 1.31 (the kind config sets no feature gates); it needs 1.33 (beta) or 1.35 (GA).
  A change to a container's requests or limits replaces the pod: the pod uid changes (a Deployment pod also gets a new name) and the restart counter starts again at 0, so
  `kube_pod_container_status_restarts_total` does not show it. `kubelet_pod_in_progress_resizes` has no series (*after rebuild*).
- Grafana container: request 100m CPU / 512Mi memory, limit 2Gi memory (*after rebuild*, from the Deployment spec; it was 1Gi, and 512Mi before that).
- StorageClass `standard` (`rancher.io/local-path`, reclaim `Delete`, `WaitForFirstConsumer`) has no `allowVolumeExpansion`, so a PVC resize is rejected. Sizes are not enforced.

## Datasources

| Name (= uid) | Type | Language | Restrictions |
|---|---|---|---|
| `VictoriaMetrics` | `prometheus` | MetricsQL | none; every lab dashboard uses this one |
| `VictoriaMetrics (DS)` (uid `VictoriaMetricsDS`) | `victoriametrics-metrics-datasource` | MetricsQL | same VMCluster, same data |
| `ClickHouse` | `grafana-clickhouse-datasource` | ClickHouse SQL | user `grafana`, `readonly=2`, SELECT on `otel.*` only; `system.*` returns code 497 |

The ClickHouse database status that `system.*` would give comes from the Altinity exporter metrics
in `VictoriaMetrics` instead ([sop-translation.md § ClickHouse](../../references/sop-translation.md#clickhouse-database-status)).

## Surfaces

| Surface | Script | Reaches | Covers |
|---|---|---|---|
| Grafana tab | `ds-query.js` | datasources `VictoriaMetrics`, `ClickHouse` (table above) | metrics and logs |
| vmui tab | `vm-query.js` | vmselect, Service `vmselect-vmks` port 8481 (headless, no port-forward by default: the human runs `kubectl --context kind-monops -n monitoring port-forward svc/vmselect-vmks 8481`). Base path `/select/0/vmui/`, API `/select/0/prometheus` | metrics only |

- vmui has no logs. Every verdict that needs ClickHouse (scale-down V1, V3, V4; the log-age probe; the error-log playbook) is NOT-OBSERVABLE there, so a vmui-only run caps the overall verdict at INCONCLUSIVE.
- Single tenant: `/select/0/...` is the only one (`/admin/tenants` returns `["0:0"]`, *after rebuild*).
- vmui `config.json`: version `v1.155.0-cluster`, vmalert enabled. vmselect proxies vmalert, so `/select/0/prometheus/api/v1/rules` answers (38 groups, 271 rules).
- **vmselect has no delete auth key.** Its flags are only `cacheDataPath`, `dedup.minScrapeInterval`, `httpListenAddr`, `selectNode`, `storageNode` and `vmalert.proxyURL`, so `/api/v1/admin/tsdb/delete_series` and the cache reset are open to anyone who reaches the port. Never call them. `vm-query.js` refuses them.
- vmui reads the same VMCluster as the `VictoriaMetrics` datasource, so it shares that backend's blind spot (below).

## Dashboards

| uid | Folder | Use |
|---|---|---|
| `scaledown-verify` | Lab | verdict tables V1–V4 for scale-down / drain / rolling upgrade; panels 29 (metrics) and 30 (logs) show data age and turn red when stale. Panel ids: [scaledown-playbook.md](scaledown-playbook.md) |
| `vmagent-autoscale-lab` | Lab | vmagent shards, samples/s, queue |
| `vector-autoscale-lab` | Lab | Vector replicas, buffer, throughput |
| `k8s-logs-clickhouse` | Lab | container logs. Use this one to filter by pod |
| `kubernetes-autoscaling-mixin-hpa-jkwq` | Kubernetes | HPA: desired / current / min / max replicas, metric targets vs usage. No data in this lab (no HPA) |
| `kubernetes-autoscaling-mixin-pdb-jkwq` | Kubernetes | PDB: disruptions allowed, desired vs current healthy, expected pods |
| `otel-logs-explorer` | Logs | OpenTelemetry Logs Explorer (ClickHouse); see the caveats below |
| `142c9cf84a0b18f347333b278a621c8e3a772c5f` | Logs | fluent-bit chart dashboard: input/output rates, retries, errors, filters, CPU, memory |
| `ehXxUsGSk` | VictoriaMetrics | Alert statistics (vmalert groups, rules, pending, firing) |

Panels with data (*after rebuild*, each panel's query run against `VictoriaMetrics` with every variable set to all):

- **HPA, 0 of 7 panels have data in this lab.** The lab has no HorizontalPodAutoscaler and no autoscaler (KEDA was removed), so `kube_horizontalpodautoscaler_*` returns 0 series and every panel is empty. That is the expected reading, not a failure. The dashboard stays vendored for clusters that do have HPAs; do not use it as evidence here.
- **PDB, 6 of 6 panels.** Four PDBs: `chi-logs-logs`, `vector`, `vmagent-lab-0`, `vmagent-lab-1`.
- **Alert statistics, 7 of 7 panels**, with Watchdog and `NodeClockNotSynchronising` firing. The two "FIRING over time" tables need a firing alert; `manifests/dashboards/upstream/SOURCES.md` recorded 5 of 7 at vendoring time.
- **fluent-bit, 13 of 13 panels.** The retry and error panels are flat at 0, which is the healthy reading.
- **OpenTelemetry Logs Explorer: not verified live.** Read from its SQL. It is built for OTel exporters that fill `ServiceName` and `SeverityText`; both were empty on every row (*earlier*), so Log Volume by Level, Services and Level Distribution collapse to one `''` bucket and Top Error Messages stays empty. Log Samples reads `ResourceAttributes['k8s.pod.name']`, which is empty, so the dashboard cannot filter by pod. Its total volume and Log Samples `Body` text still work. Open it with `viewPanel=<id>` only: several of its queries have no `LIMIT`, and opening the whole dashboard runs about six scans at once on a ClickHouse that sits near its memory ceiling. `ds-query.js` refuses these queries unchanged (no `LIMIT`).

Dashboards that arrive from the chart's sync job (folder General, or `ClickHouse` for the Altinity ones), present in `/api/search`:

| uid | Title | Panels worth knowing |
|---|---|---|
| `6581e46e4e5c7ba40a07646395ef7b23` | Kubernetes / Compute Resources / Pod | 1 CPU usage, 2 CPU throttling, 4 memory (WSS) |
| `k8s_views_pods` | Kubernetes / Views / Pods | 30 memory vs requests/limits, 50 CPU vs requests/limits, 56 last terminated reason, 60 OOM events, 61 restarts, 63 pods with container issues |
| `a164a7f0339f99e89cea5cb47e9be617`, `85a562078cdf77779eaa1add43ccec1e`, `a87fb0d919ec0ea5f6543124e16c42a5`, `efa86fd1d0c121a26444b636a3f509a8` | Compute Resources: Workload, Namespace (Pods), Namespace (Workloads), Cluster | |
| `fac67cfbe174d3ef53eb473d73d9212f`, `3e97d1d02672cdd0861f4c97c64f89b2` | Node Exporter / USE Method: Node, Cluster | |
| `oS7Bi_0Wz`, `G7Z9GzMGz`, `LzldHAVnz`, `1H179hunk` | VictoriaMetrics: cluster, vmagent, vmalert, operator | |
| `919b92a8e8041bd567af9edab12c840c` | Kubernetes / Persistent Volumes | always empty: kind exports no `kubelet_volume_stats_*` (0 series, *after rebuild*) |

## Signals

`job` label → component (`curl <pod>:<port>/metrics` maps to the same metric in `VictoriaMetrics`):

| `job` | What |
|---|---|
| `vmagent-lab` | lab vmagent shards (`vmagent_remotewrite_*`, `vm_persistentqueue_*`, `flag{name=…}` = its command-line flags). 4 pods = 2 shards x 2 HA replicas (`shardCount` x 2) |
| `avalanche` | synthetic targets scraped by the lab vmagent (5 s) |
| `vmagent-vmks` | the monitoring vmagent that scrapes the cluster (1 pod, namespace `monitoring`, queue on an `emptyDir`) |
| `logging/vector` | Vector aggregator (`vector_buffer_*`, `vector_component_*`) |
| `fluent-bit` | `fluentbit_output_retries_total`, `fluentbit_output_errors_total`, `fluentbit_output_dropped_records_total` |
| `vminsert-vmks`, `vmselect-vmks`, `vmstorage-vmks` | VictoriaMetrics cluster components |
| `vmalert-vmks`, `vmalertmanager-vmks`, `vmks-victoria-metrics-operator`, `vmks-grafana` | rule evaluation, Alertmanager, operator, Grafana |
| `kube-state-metrics`, `kubelet`, `node-exporter` | Kubernetes state, containers, nodes |
| `apiserver`, `kube-etcd`, `kube-scheduler`, `kube-controller-manager`, `kube-proxy`, `core-dns` | control plane and cluster add-ons |
| `clickhouse-operator-altinity-clickhouse-operator-metrics` | `chi_clickhouse_*` exporter (two targets: ch-metrics :8888, op-metrics :9999) |

`*-reloader-http` jobs (config-reloader sidecars) also exist.

Nothing autoscales in this lab: there is no HPA and no KEDA, so the `kube_horizontalpodautoscaler_*`
series are absent. Absence is the normal state here; do not report it as an error. Replica counts come from
`kube_statefulset_replicas` / `kube_statefulset_status_replicas_ready` (Vector: `statefulset="vector"`)
and from the VMAgent shard count (panel 4 of `scaledown-verify` = `spec.shardCount`, panel 3 = rolling progress, or the `-promscrape.cluster.membersCount`
flag on the vmagent pods). The human scales with `kubectl scale` (`make pin N=<n>` / `make vpin N=<n>`
are thin wrappers that set the count directly; `N=off` returns to the baseline of 2). A scale-down
trigger is therefore a HUMAN step: ask the human for the UTC trigger time and do not infer it from
a controller.

Components and sizes (*after rebuild*):

| Item | Value |
|---|---|
| Namespaces | VM cluster, `vmagent-vmks`, alert stack and Grafana in `monitoring`; lab shards in `vmagent-lab`; Vector, fluent-bit, rotel in `logging`; ClickHouse in `clickhouse`. No autoscaler namespace (KEDA removed) |
| Versions | VictoriaMetrics `v1.155.0` (`-cluster` build for vminsert, vmselect, vmstorage); operator and config-reloader `v0.75.2` |
| Replicas | vminsert 2, vmselect 1, vmstorage 2, rotel 2 (Deployment, no scrape job), Vector 2 by default, changed by hand with `kubectl scale` (no autoscaler); vmagent `shardCount` 2 by default, same |
| PVC requests | vmstorage 5Gi each, ClickHouse 5Gi, `data-vector-<n>` 2Gi, lab queue 2Gi each, vmselect cache 1Gi |
| Vector disk buffer | sink `rotel`, `vector_buffer_max_size_bytes` 1 GiB per pod |
| CPU limits | only 5 containers have one (and so a CFS throttle series; KEDA's 3 containers had limits and are gone): kindnet-cni x3, vmalert, alertmanager |
| Alertmanager | one receiver, 0 integrations, `alertmanager_notifications_total` sums to 0: delivery can never be shown |

## Logs

- Table `otel.otel_logs` in `ClickHouse`. Columns: `Timestamp`, `TimestampTime`, `Body`, `LogAttributes`.
- `TimestampTime` is the `DateTime` in the primary key (`ServiceName, TimestampTime`) and the partition key. A filter on it prunes; `$__timeFilter(Timestamp)`, which every lab dashboard uses, does not (*earlier*). Retention is 72 h (`--ttl 72h` in `manifests/clickhouse/rotel-ddl-job.yaml`).
- `ServiceName` and `SeverityText` are empty on every row (*earlier*), so a level has to be parsed from `Body`. Kubernetes metadata are `LogAttributes` keys:
  - `LogAttributes['k8s.pod.name']`
  - `LogAttributes['k8s.container.name']`
  - `LogAttributes['k8s.namespace.name']`
- `kubectl logs <pod>` →
  `SELECT Timestamp, Body FROM otel.otel_logs WHERE $__timeFilter(Timestamp) AND LogAttributes['k8s.pod.name'] = '<pod>' ORDER BY Timestamp DESC LIMIT 200`
- Collection covers the two worker nodes only. fluent-bit is a DaemonSet without a toleration for the control-plane taint, so it runs on 2 of 3 nodes (*after rebuild*) and control-plane pod logs are not in ClickHouse. Its own logs are excluded from collection (*earlier*).
- Containers `inspect` (pods `pvc-inspect-*`, `vector-pvc-inspect-*`) re-print old log tails with new timestamps. Exclude them from error analysis.
- About 0.003% of rows have an empty `LogAttributes` (a fluent-bit multiline quirk). Before calling a line missing, search `Body` too.
- ClickHouse logs every query it receives, and that log line reaches `otel.otel_logs` too. A `LIKE '%needle%'` search therefore matches your own query. Anchor the pattern at the start of `Body`, or filter on namespace / container.
- Fluent-bit caches pod metadata by pod name, so a re-created pod keeps the old `k8s.pod.uid`.
- ClickHouse is memory-tight (see the health check below). Bound every query by `TimestampTime`, keep windows short and `LIMIT` small. Wide `LogAttributes` scans were killed with code 241 (*earlier*).

## Freshness

| Signal | Delay |
|---|---|
| vmselect | the newest 10–30 s can be missing (`-search.latencyOffset`) |
| kube-state-metrics, node-exporter, apiserver, fluent-bit, lab vmagent self-metrics | scraped every 20 s |
| kubelet (including cAdvisor), Altinity ClickHouse exporter | scraped every 30 s; use rate windows of at least 2 min, and expect a change to show up 30–60 s late |
| Vector metrics | every 10 s |
| avalanche | every 5 s |
| Logs: container stdout → fluent-bit → Vector → rotel → ClickHouse | normally 5–30 s; minutes while rotel is down (buffered in Vector, not lost) |

Probes (run through `ds-query.js`, or `vm-query.js` for the metrics one):

| Backend | Query | Healthy | Frozen |
|---|---|---|---|
| `VictoriaMetrics` (instant) | `time() - max(tlast_over_time(up{job="kube-state-metrics"}[10m]))` | about 10–30 s | > 45 s and climbing |
| `ClickHouse` | `SELECT dateDiff('second', max(Timestamp), now64()) AS age_s FROM otel.otel_logs WHERE $__timeFilter(Timestamp)` | a few seconds | > 60 s |

## Blind spots

The monitoring vmagent writes into the same VMCluster the lab breaks.

- **VictoriaMetrics down** (`make outage-start`): every `VictoriaMetrics` panel freezes at its last value. Measured during a real outage: `up{job="vminsert-vmks"}` still read 2 while the metrics age had climbed to 47 s. Watch `ClickHouse` (logs) instead; the metrics backfill after recovery.
- **rotel or ClickHouse down** (`make voutage-start`): log panels freeze, while metrics stay live.

## Not observable

| Fact | Closest proxy |
|---|---|
| PVC usage (`df`) | none: kind local-path volumes export no `kubelet_volume_stats_*`. App metrics instead: `vm_data_size_bytes`, `chi_clickhouse_metric_DiskDataBytes` against the PVC request, `vector_buffer_size_bytes`, `vm_persistentqueue_bytes_pending`. Capacity metrics (`vm_free_disk_space_bytes`, ClickHouse `DiskTotalBytes`) report the node filesystem, never the PVC |
| PVC file contents (`metainfo.json`, `buffer.db`) | exit evidence + data evidence, see [scaledown-playbook.md](scaledown-playbook.md) |
| `kubectl describe` / events | none: events are not collected |
| In-place resize progress | none: the feature is off on 1.31, see Platform |
| Alert delivery to a receiver | none: Alertmanager has no integration. Compare vmalert's firing set with Alertmanager's active alerts |
| rotel | no scrape job: see the health check row |
| Control-plane pod logs | none: fluent-bit does not run on the control-plane node |
| `system.query_log`, users, grants | none (by design: the reader has no grants there) |

## Session

Grafana has no persistent storage. A restart (for example an OOM kill) logs every browser session
out and drops users created at runtime, such as a test Viewer. Restarts show in
`kube_pod_container_status_restarts_total{pod=~"vmks-grafana-.*"}`, and `up{job="vmks-grafana"}`
shows whether it is back. The memory limit is 2Gi (see Platform).

## Standing health check

When the user asks for a full health check and names no SOP, one OBSERVE row per line. A threshold
marked *interpreted* is the default for this lab. Replace it when the user states a different one.

| Component | Signal | PASS |
|---|---|---|
| Metrics age | Freshness probe for `VictoriaMetrics` | inside the healthy band above |
| Log age | Freshness probe for `ClickHouse` | inside the healthy band above |
| Scrape targets | `up` by `job` for every job in Signals | each job has at least one `up == 1` |
| Lab vmagent queue | `vmagent_remotewrite_pending_data_bytes{job="vmagent-lab"}`, `increase(vmagent_remotewrite_retries_count_total{job="vmagent-lab"}[5m])` | *interpreted*: pending under 10 MB and not climbing; retries flat |
| vminsert, vmselect, vmstorage | `up{job="<job>"}` next to `kube_pod_status_ready{condition="true"}` for that component | `up` equals the ready-pod count (2, 1, 2) |
| vmalert, alertmanager | `up{job="vmalert-vmks"}` and `up{job="vmalertmanager-vmks"}` next to the ready pods; `/select/0/prometheus/api/v1/rules` for rule health | both `up == 1`, no rule with `lastError` (38 groups, 271 rules *after rebuild*). Missing series → NOT-OBSERVABLE. Do not invent a firing alert |
| fluent-bit | `increase(fluentbit_output_dropped_records_total[30m])` | 0 |
| Vector buffer | `vector_buffer_size_bytes{component_id="rotel"}` | *interpreted*: not climbing over 10 m |
| rotel | no scrape job | proxy: log age in the healthy band, and Vector sink errors flat. Name it as a proxy |
| ClickHouse | `chi_clickhouse_metric_ReadonlyReplica`, `chi_clickhouse_metric_fetch_errors` | both 0. `system.*` returns 497; use these exporter series |
| ClickHouse memory | container working set over the memory limit; `rate(chi_clickhouse_metric_SystemErrors_MEMORY_LIMIT_EXCEEDED[5m])` | *interpreted*: working set under 0.9 of the 2Gi limit and no code-241 series. Baseline *after rebuild*: working set 0.80, resident 0.78 of the server cap (90% of 2Gi), no 241 series. On the previous cluster, after hours of uptime, merges failed with code 241 about 1.7 per second and reader queries were killed; that did not show in the first 30 minutes |
| Grafana | `kube_pod_status_ready{condition="true", pod=~"vmks-grafana-.*"}` | ready, and restarts not increasing over 30 m |
| CPU saturation | throttled-period ratio from [sop-translation.md](../../references/sop-translation.md), namespaces `vmagent-lab`, `logging` and `monitoring` | under 0.25 (the `CPUThrottlingHigh` line; information, see [kubernetes-resources.md](../../references/kubernetes-resources.md)). Only the 8 containers listed under Components have a limit, so only they produce a ratio; for the rest use `container_pressure_cpu_waiting_seconds_total`. Baseline *after rebuild*: the kindnet pods sit at 0 to 0.03 and `CPUThrottlingHigh` is not firing. Earlier the same pods read 0.06–0.81 and fired it at rest, so a kindnet reading is not a regression either way. Shorten the range to the window you are judging, and keep it ≥ 4× the kubelet scrape (30 s) |

Baseline firing alerts (*after rebuild*, vmalert): `Watchdog` x1 and `NodeClockNotSynchronising` x3 (one per node-exporter). Earlier the set was 12, adding `CPUThrottlingHigh` x3 (kindnet), `RecordingRulesNoData` x3, `TooManyRestarts` x1, `InfoInhibitor` x1; they may come back, so treat only an alert outside both lists as new.

A row whose backend is frozen is INCONCLUSIVE, not PASS.

## Playbooks

| Playbook | Use when |
|---|---|
| [scaledown-playbook.md](scaledown-playbook.md) | vmagent / Vector graceful scale-down, drain or rolling upgrade (verdict panels V1–V4) |
| [after-change.md](../../playbooks/after-change.md) | a routine operation was just done (scale, requests/limits change, PVC resize, rolling restart or upgrade) and the question is whether it landed and is healthy |
| [ecosystem-health.md](../../playbooks/ecosystem-health.md) | a health check of the whole stack, with no SOP and no named component |
| [error-logs.md](../../playbooks/error-logs.md) | error logs appeared or spiked and the cause is unknown |
| [saturation.md](../../playbooks/saturation.md) | a remote-write queue or disk buffer is growing, or inserts are slow, and the bottleneck stage is unknown |
