# SOP command → Grafana signal (common stacks)

An SOP usually says what a human would run in a shell. Find the row for that command here, then check
the same fact through Grafana. These rows hold for the products named in each section; the profile
supplies this environment's datasource, `job` labels and log table. Metric names were checked
against one lab's profile; confirm them on any other Grafana with discovery on
a Prometheus-type datasource:

- names: `/api/datasources/proxy/uid/<uid>/api/v1/label/__name__/values`
- label sets: `…/api/v1/series?match[]=<selector>`

## Label traps (read these before writing queries)

- **Labels on kube-state-metrics series**:
  - `kube_pod_*` series carry the **subject** pod in `pod`.
  - Non-pod series (`kube_persistentvolumeclaim_*`, `kube_statefulset_*`, `kube_deployment_*`, `kube_horizontalpodautoscaler_*`) carry the **kube-state-metrics** pod in `pod`. Select them by their own label instead: `persistentvolumeclaim`, `statefulset`, `deployment`, `horizontalpodautoscaler`.
- **One-hot state metrics**: `kube_pod_status_phase`, `kube_persistentvolumeclaim_status_phase` and `kube_node_status_condition` emit one series per possible state, and only the current one is 1. Always add `== 1`.
- **`chi_clickhouse_*` (Altinity exporter) labels**:
  - `pod` / `namespace` = the operator pod / namespace.
  - The ClickHouse server is `hostname`; its namespace is `exported_namespace`; its installation is `chi`.

## Kubernetes (kubectl → kube-state-metrics and kubelet)

| SOP command / question | Grafana signal |
|---|---|
| `kubectl get pods -n X` (phase) | `kube_pod_status_phase{namespace="X"} == 1` (label `phase`) |
| … ready | `kube_pod_status_ready{namespace="X", condition="true"} == 1` |
| … restarts | `increase(kube_pod_container_status_restarts_total{namespace="X"}[$__range])` |
| pod Terminating | `kube_pod_deletion_timestamp{namespace="X"}` (exists only while it is deleting) |
| `kubectl get sts Y` desired / ready | `kube_statefulset_replicas{statefulset="Y"}` / `kube_statefulset_status_replicas_ready{statefulset="Y"}` |
| `kubectl get deploy Y` | `kube_deployment_status_replicas_available{deployment="Y"}` |
| `kubectl get hpa` (autoscaler desired replicas) | `kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="Y"}`. Only exists where an HPA exists (some scalers, e.g. KEDA, generate one); a cluster without an autoscaler returns 0 series, which is not an error. The profile says whether the cluster has HPAs |
| `kubectl get pvc` | `kube_persistentvolumeclaim_status_phase{persistentvolumeclaim="Z"} == 1`; size: `kube_persistentvolumeclaim_resource_requests_storage_bytes` |
| `df` on a PVC / PVC usage | `kubelet_volume_stats_used_bytes{persistentvolumeclaim="Z"}` / `kubelet_volume_stats_capacity_bytes`, when the volume plugin exports them (the profile says if not) |
| `kubectl get nodes` | `kube_node_status_condition{condition="Ready", status="true"} == 1` |
| `kubectl logs <pod>` | the log datasource; the profile names the table and the pod-name column |
| `kubectl describe` / events | NOT-OBSERVABLE unless an event exporter feeds the log store (the profile says) |
| `kubectl exec … cat <file>` | **NOT-OBSERVABLE**: name a proxy (the file's effect in metrics or logs) |

## Application metrics (`curl <pod>:<port>/metrics` → same metric)

The scraped series carries the same metric name. Filter by `pod` or `job`; the profile maps `job`
values to components. The resolution is the scrape interval (profile: Freshness).

`rate` and `increase` ranges are at least 4× that scrape interval, and at least as long as the window
being judged. A range longer than the event hides it.

## CPU limit and throttling (kube-state-metrics and cAdvisor)

| SOP question | Grafana signal |
|---|---|
| CPU limit in effect | `kube_pod_container_resource_limits{namespace="X", pod=~"Y", resource="cpu", unit="core"}` |
| CPU throttled | the CPU throttle ratio row of [kubernetes-resources.md § 4](kubernetes-resources.md#4-is-it-healthy-after): per container, `namespace="X"`, window = the period the SOP asks about. Thresholds and how to read them (0.25, 0.05) are there |

## VictoriaMetrics cluster health

| SOP question | Grafana signal |
|---|---|
| components up | `up{job=~".*(vminsert\|vmselect\|vmstorage).*"}` (the profile has the exact `job` values) |
| storage disk | `vm_free_disk_space_bytes`, `vm_free_disk_space_limit_bytes`, `vm_storage_is_read_only` |
| ingestion | `sum(rate(vm_rows_added_to_storage_total[5m]))`, `rate(vm_slow_row_inserts_total[5m])` |
| a series has no holes | MetricsQL only: `max by (pod) (rollup_scrape_interval(<selector>[$__range], "max"))` = largest gap between stored samples. Plain Prometheus has no one-liner: range-query `timestamp(<selector>)` with `points: true`, then take the largest jump between consecutive distinct values. The step is at least range / 1000 (the helper's `maxDataPoints`), so keep the range short enough for that to stay below the scrape interval. |

## ClickHouse database status

Grafana's ClickHouse user is often limited to the application databases. `system.*` then returns code
497 (not enough privileges), and `system.*` SOP queries map to the Altinity operator's exporter
metrics in the Prometheus-type datasource.

| SOP query (clickhouse-client) | Grafana signal |
|---|---|
| `SELECT uptime(), version()` | works as SQL in the ClickHouse datasource; or `chi_clickhouse_metric_Uptime`, `chi_clickhouse_metric_VersionInteger` |
| `system.parts` (active parts, rows, bytes) | `chi_clickhouse_table_parts{database="<db>", table="<table>", active="1"}`, `chi_clickhouse_table_parts_rows`, `chi_clickhouse_table_parts_bytes` |
| `system.merges` / `system.mutations` | `chi_clickhouse_metric_Merge`, `chi_clickhouse_metric_BackgroundMergesAndMutationsPoolTask` |
| `system.replicas` | `chi_clickhouse_metric_ReadonlyReplica`, `chi_clickhouse_metric_ReplicasMaxAbsoluteDelay` |
| `system.disks` | `chi_clickhouse_metric_DiskFreeBytes`, `chi_clickhouse_metric_DiskAvailable_default`, `chi_clickhouse_metric_DiskDataBytes`, `chi_clickhouse_metric_ReadonlyDisks` |
| `system.metrics` connections / queries | `chi_clickhouse_metric_TCPConnection`, `chi_clickhouse_metric_HTTPConnection`, `chi_clickhouse_metric_Query` |
| failed queries / inserts | `sum(increase(chi_clickhouse_event_FailedQuery[<w>]))`, `sum(increase(chi_clickhouse_event_FailedInsertQuery[<w>]))`, `sum(increase(chi_clickhouse_event_FailedAsyncInsertQuery[<w>]))`; these counters are absent until the first failure ([clickhouse.md § Absent is not zero](clickhouse.md#absent-is-not-zero)). `InsertedRows` is a total including system tables, not a failure count |
| exporter could not reach ClickHouse | `chi_clickhouse_metric_fetch_errors` > 0 |
| data arriving in a table | SQL: `SELECT count(), max(<time column>) FROM <db>.<table> WHERE $__timeFilter(<time column>)` |
