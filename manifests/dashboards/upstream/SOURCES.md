# Vendored upstream dashboards

Copied from the sources below on 2026-11-07, all Apache-2.0. Only the changes listed per file were made.
Panels were checked against the lab's VictoriaMetrics / ClickHouse (panels returning data / panels in the file).

| File | Upstream | Revision | Changes | Data on the lab |
|---|---|---|---|---|
| `vm-alert-statistics.json` | https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.155.0/dashboards/alert-statistics.json (also grafana.com 24553 rev 5) | v1.155.0 (identical on master `bed0f8900ba4`) | datasource variable `ds` pinned to `VictoriaMetrics`; empty `__inputs` dropped | 5 of 7 (the two "FIRING over time" panels are empty while no alert fires) |
| `kubernetes-autoscaling-hpa.json` | https://github.com/adinhodovic/kubernetes-autoscaling-mixin/blob/a94c0795e3/dashboards_out/kubernetes-autoscaling-mixin-hpa.json | commit `a94c0795e3` (2026-08-16) | datasource variable pinned to `VictoriaMetrics`; empty `__inputs` dropped | 0 of 7 while the cluster has no HorizontalPodAutoscaler (the lab no longer installs KEDA, so nothing creates one); fills once an HPA exists |
| `kubernetes-autoscaling-pdb.json` | https://github.com/adinhodovic/kubernetes-autoscaling-mixin/blob/a94c0795e3/dashboards_out/kubernetes-autoscaling-mixin-pdb.json | commit `a94c0795e3` | same as HPA | 6 of 6 |
| `otel-logs-explorer.json` | https://github.com/grafana/clickhouse-datasource/blob/v4.23.4/src/dashboards/otel-logs-explorer.json | plugin v4.23.4 | `__inputs` removed and the `datasource` variable set to the lab's `ClickHouse` datasource, because the sidecar does not resolve `${DS_GRAFANA_CLICKHOUSE_DATASOURCE}` | 5 of 8 (Top Error Messages is empty: fluent-bit sends no `SeverityText`) |

Not vendored on purpose:

- Dashboards the chart already delivers. The VictoriaMetrics, Kubernetes, node-exporter and Altinity dashboards
  come from the `vmks-sync-job` hook and the Altinity chart. Their sources are pinned in `helm/values/vm-k8s-stack.yaml`
  (`defaultDashboards.sources`, and `defaultRules.sources` for the alert rules); see the table below.
- Fluent Bit: the chart ships its own dashboard, enabled in `helm/values/fluent-bit.yaml`.
- Vector Cluster Monitoring (grafana.com 21954): no licence is stated, so it is not committed here.
- KEDA dashboards: the lab does not run KEDA, so there are no `keda_*` series.

## Pinned chart sources (`helm/values/vm-k8s-stack.yaml`)

The chart's sync-job downloads dashboards and alert rules from upstream URLs on every `helm upgrade`. The chart default is `master` / `main`,
so two rebuilds on different days would load different content. The lab pins them. Checked 2026-11-07: all 22 URLs return 200, the render
contains no `master` or `main` reference, and after the upgrade Grafana lists the same 59 dashboards and vmalert the same 38 groups / 271 rules.

| Source | Pinned to |
|---|---|
| VictoriaMetrics dashboards (single-node, vmagent, cluster, vmalert, operator, backupmanager) and alert rules (health, vmagent, vmalert, single-node, cluster) | `v1.155.0`, the version the lab runs |
| VM operator rules | `v0.75.2`, the operator version the lab runs |
| VictoriaLogs, VictoriaTraces dashboards and rules (not loaded as dashboards in this lab) | `v1.53.0`, `v0.13.0` |
| dotdc Kubernetes views, API server, CoreDNS | `v3.0.8` |
| kube-prometheus rules and `grafana-dashboardDefinitions.yaml` | `v0.19.0` |
| rfmoz node-exporter-full | commit `b07d8a90d8fa` (no tags) |
| monitoring-mixins etcd dashboard and rules | commit `25b934e6b000` (no tags) |

To upgrade, change the refs in the values file, check the URLs, run `helm upgrade`, and record the new refs here. The skill's thresholds
were cross-checked against the rules of these refs, so re-check `references/` after a bump.
