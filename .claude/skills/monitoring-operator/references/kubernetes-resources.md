# Kubernetes workload resources: proof ladders for replica, CPU, memory and PVC changes, plus node saturation

Contents: [Reading the signals together](#reading-the-signals-together) · [0 Trust](#0-trust-check) · [1 Accepted](#1-did-the-controller-accept-the-change) · [2 Rolled out](#2-did-it-roll-out) · [3 Reached the kernel](#3-did-it-reach-the-kernel) · [4 Healthy after](#4-is-it-healthy-after) · [Operation ladders](#operation-ladders) · [Node saturation](#node-saturation-use) · [Label traps](#label-traps) · [Not observable](#not-observable-read-only)

Command-to-signal rows (ready, restarts, `kubectl get hpa/pvc`) live in [sop-translation.md](sop-translation.md#kubernetes-kubectl--kube-state-metrics-and-kubelet). This file adds the proof order and the saturation reading.

Sources: kube-state-metrics (KSM, object state), kubelet and cAdvisor (container runtime, all under one scrape `job`, told apart by `metrics_path`), node-exporter (host).

## Reading the signals together

A change is proven in four rungs. Climb in order and stop at the first rung that fails: a higher rung cannot pass while a lower one is broken.

1. **Accepted**: the API server stored the new spec and the controller saw it.
2. **Rolled out**: the controller created or replaced the pods and they are ready.
3. **Reached the kernel**: the cgroup limit the kernel enforces equals the spec.
4. **Healthy after**: over a soak window nothing restarted, was killed, throttled, starved or left unscheduled.

Rules that apply on every rung:

- **An empty result proves nothing until [rung 0](#0-trust-check) passes.** KSM emits "bad" series only while the condition holds, so a dead collector and a healthy cluster both answer with an empty set.
- **State metrics lag reality** by up to one scrape interval of the collector, plus the ingest delay (profile: Freshness). Judge a rung only after a time later than `change time + 2 x scrape interval`, and say which timestamp you used.
- **Compare against the change time the human gave you.** `kube_pod_start_time` and `kube_pod_status_ready_time` newer than that time prove a pod was replaced. A rung that passes on pods that predate the change proves nothing.
- Counter windows (`increase`, `rate`): [SKILL.md § Freshness](../SKILL.md#freshness).
- Thresholds marked *interpreted* are this reference's judgment. Replace them when the SOP or the user states one.

## 0. Trust check

| Signal | Query | PASS | Deviation |
|---|---|---|---|
| Collectors alive | `min by (job)(up{job=~"kube-state-metrics\|kubelet\|node-exporter\|kube-scheduler"})` | every returned job is 1, and every collector you will read is present | A job is 0 or missing: every "empty = healthy" answer below is INCONCLUSIVE for that collector |

Also run the profile's Freshness probe. A frozen backend freezes these series at their last value ([SKILL.md § Freshness](../SKILL.md#freshness)).

## 1. Did the controller accept the change?

Controller bookkeeping first, then the new value in the spec as KSM exports it.

| Signal | Query | PASS | Deviation |
|---|---|---|---|
| Deployment saw the latest spec | `kube_deployment_metadata_generation - kube_deployment_status_observed_generation != 0` | empty | A row: the controller has not processed the newest generation yet (wait, then re-read) |
| StatefulSet saw the latest spec | `kube_statefulset_metadata_generation - kube_statefulset_status_observed_generation != 0` | empty | Same. A generation bump alone does not mean pods were replaced: a replica change also bumps it. Rung 2 decides |
| Replica count in spec | `kube_statefulset_replicas`, `kube_deployment_spec_replicas` | equals the number the human asked for | Old number: the change did not land, or another controller (an autoscaler, an operator) overwrote it |
| Resource requests in spec | `kube_pod_container_resource_requests{namespace="<ns>",pod="<pod>"}` | the new value on every pod of the workload (`resource` = `cpu`/`memory`, `unit` = `core`/`byte`) | Old pods keep the old value until replaced, so a mixed set during a roll is normal; a mixed set after rung 2 passed is not |
| Resource limits in spec | `kube_pod_container_resource_limits{namespace="<ns>",pod="<pod>"}` | the new value on every replica | **No limit is an absent series, not 0.** An absent series after you expected a limit means the limit was removed |
| PVC requested size | `kube_persistentvolumeclaim_resource_requests_storage_bytes` | the new size | Old size: the API rejected the resize, or the human did not apply it |
| Autoscaler owns replicas | `kube_horizontalpodautoscaler_spec_min_replicas ; kube_horizontalpodautoscaler_spec_max_replicas` | the manual target sits inside min..max | Outside the range: the autoscaler will pull the count back |

## 2. Did it roll out?

| Signal | Query | PASS | Deviation |
|---|---|---|---|
| Deployment complete | `kube_deployment_spec_replicas - kube_deployment_status_replicas_available != 0 or kube_deployment_spec_replicas - kube_deployment_status_replicas_updated != 0` | empty, and `kube_deployment_status_condition{condition="Progressing",reason="NewReplicaSetAvailable",status="true"}==1` | A row: pods missing or not yet available. A `Progressing` condition with `status="false"` is a stuck roll (unverified wording, see [Not observable](#not-observable-read-only)) |
| StatefulSet revision settled | `kube_statefulset_status_current_revision unless on(namespace,statefulset,revision) kube_statefulset_status_update_revision` | empty | A row: current revision still differs from the target, the roll is not finished |
| StatefulSet pods ready | `kube_statefulset_replicas - kube_statefulset_status_replicas_updated != 0` and `max by (statefulset)(kube_statefulset_replicas) - max by (statefulset)(kube_statefulset_status_replicas_ready) != 0` | both empty (spec = updated = ready; also compare `kube_statefulset_status_replicas_available`) | Ready lags updated: the new pod is up but failing readiness. Available lags ready by `minReadySeconds` plus one KSM scrape interval, which is normal |
| DaemonSet coverage | `kube_daemonset_status_desired_number_scheduled - kube_daemonset_status_number_ready` | 0 for every DaemonSet (rollouts also compare `updated_number_scheduled` and the generation fields) | Positive: a node has no ready pod |
| Autoscaler converged | `kube_horizontalpodautoscaler_status_desired_replicas ; kube_horizontalpodautoscaler_status_current_replicas` | desired = current once the HPA behavior windows have passed | `desired` = `spec_max_replicas` with `ScalingLimited` true: saturated at the ceiling |
| Autoscaler input | `kube_horizontalpodautoscaler_status_target_metric ; kube_horizontalpodautoscaler_spec_target_metric` | current / target < 1 means room | >= 1 with desired = max is saturation. For an `AverageValue` trigger the current value is the per-pod average |
| Autoscaler health | `kube_horizontalpodautoscaler_status_condition == 1` | `AbleToScale` and `ScalingActive` are true | `ScalingActive` false: the metric query behind the scaler is failing |
| Pods replaced | `kube_pod_start_time ; kube_pod_status_ready_time` (select the pods) | newer than the change time | Older: the pod was never restarted. After a change that needs a restart, the change is not live there |

**How long to wait.** Budget per pod = termination grace + time to ready + `minReadySeconds`; StatefulSets roll one ordinal at a time by default, Deployments by `maxSurge`/`maxUnavailable`. Add one KSM scrape interval before KSM shows the state. A pod with a long preStop or graceful drain (read its grace period from the SOP or the human) can take that full grace period to terminate. While a roll is mid-way the answer is INCONCLUSIVE, with what would settle it.

**No HPA, no series.** Without an HPA (the profile says) every `kube_horizontalpodautoscaler_*` series is absent: report "no autoscaler, replicas set by hand" and read the count from `kube_statefulset_replicas` / `kube_deployment_spec_replicas`.

## 3. Did it reach the kernel?

This is what separates "the YAML says 2 CPU" from "the container is allowed 2 CPU".

| Signal | Query | PASS | Deviation |
|---|---|---|---|
| Memory limit: spec = cgroup | `max by (namespace,pod,container)(kube_pod_container_resource_limits{resource="memory"}) != on(namespace,pod,container) max by (namespace,pod,container)(container_spec_memory_limit_bytes{container!=""})` | empty | A row: that pod still runs the old limit (roll unfinished, or an in-place resize pending) |
| CPU limit: spec = cgroup | `max by (namespace,pod,container)(kube_pod_container_resource_limits{resource="cpu"}) != on(namespace,pod,container) max by (namespace,pod,container)(container_spec_cpu_quota{container!=""} / container_spec_cpu_period{container!=""})` | empty | Same |
| Quota as cores | `container_spec_cpu_quota{container!=""} / container_spec_cpu_period{container!=""}` | equals the new CPU limit | Old value: not applied |
| In-place resizes pending | `kubelet_pod_in_progress_resizes` | 0 shortly after an in-place resize | Stuck above 0: the resize is deferred or infeasible (conditions are visible only through kubectl) |

Both mismatch queries drop containers that have no limit, so first confirm in rung 1 that the limit series exists. Never verify a CPU **request** from `container_spec_cpu_shares`: on cgroup v2 the value round-trips lossily (100m reads back as about 80). Use the KSM request.

## 4. Is it healthy after?

Soak window: 5-10 minutes after the pods are ready (*interpreted*; lengthen it for memory leaks and bursty load). Evaluate every row inside that window.

| Signal | Query | PASS | Deviation |
|---|---|---|---|
| Restarts | `sum by (namespace,pod,container)(increase(kube_pod_container_status_restarts_total[<window>])) > 0` | empty | A row. The counter resets when a StatefulSet pod is re-created under the same name, so empty right after crashes is possible: pair it with `kube_pod_start_time` and the OOM row |
| OOMKilled | `max_over_time(kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}[<window>])` | no series inside the window | A series: the kernel killed the container. `last_terminated_reason` keeps only the latest reason, so a later restart overwrites it; always use `max_over_time` over the whole window and read the time with `kube_pod_container_status_last_terminated_timestamp` |
| Readiness | `kube_pod_status_ready{condition="true"} == 0 unless on(namespace,pod) kube_pod_status_phase{phase="Succeeded"}==1` | empty (completed Job pods are excluded) | A row: running but not serving |
| Pending pods | `kube_pod_status_phase{phase="Pending"} == 1` | empty once settled | Pending more than a few minutes after a scale-up: scheduling or volume binding |
| Not scheduled | `kube_pod_status_scheduled{condition="false"} == 1` | empty | A row: the pod does not fit (CPU/memory request, taints, affinity). Compare node headroom below |
| Stuck waiting | `kube_pod_container_status_waiting == 1` and `last_over_time(kube_pod_container_status_waiting_reason[<window>])` | empty | The `reason` label names it (`CrashLoopBackOff`, `ImagePullBackOff`, `CreateContainerConfigError`, `ContainerCreating`). Exists only while waiting |
| CPU throttle ratio | `sum by (namespace,pod,container) (rate(container_cpu_cfs_throttled_periods_total{container!=""}[<w>])) / sum by (namespace,pod,container) (rate(container_cpu_cfs_periods_total{container!=""}[<w>]))` (per container: a pod sum hides one throttled container) | < 0.25, the threshold of the common `CPUThrottlingHigh` alert (severity *info*, fires after 15 m). Under 0.05 is quiet | **After a change, when the SOP or the user asks whether throttling is acceptable:** >= 0.25 over the window since the change is FAIL (*interpreted*; name the threshold). **In a health check with no such question:** >= 0.25 is information, not a verdict: the kubernetes-mixin runbook calls the alert informative unless the application shows another symptom (latency, a growing queue, errors), so report the ratio with that symptom evidence. A rise right after lowering a limit means the change cost headroom. A high ratio at low average CPU is bursty work meeting a small quota |
| Throttled seconds | `sum by (pod) (rate(container_cpu_cfs_throttled_seconds_total{container="<container>"}[5m]))` | near 0 | Read with the ratio: stall seconds per second |
| CPU pressure (PSI) | `topk(6, rate(container_pressure_cpu_waiting_seconds_total{container!=""}[5m]))` | < 0.05 (*interpreted*) | Runnable threads wait for CPU. **Use this for containers without a CPU limit**, which have no throttle series |
| Memory working set / limit | `sort_desc(max by (namespace,pod,container) (container_memory_working_set_bytes{container!=""}) / on(namespace,pod,container) max by (namespace,pod,container)(kube_pod_container_resource_limits{resource="memory"}))` | < 0.8 sustained (*interpreted*) | Near 1: OOM is next. The kubelet decides OOM and eviction on the working set. Containers with no limit drop out of this join |
| Working set vs request | `topk(5, max by (namespace,pod,container)(container_memory_working_set_bytes{container!=""}) / on(namespace,pod,container) max by (namespace,pod,container)(kube_pod_container_resource_requests{resource="memory"}))` | about 1 or less | Far above 1: the scheduler under-counts this pod and the node can be overcommitted |
| CPU usage vs request | `sum by (namespace,pod,container) (rate(container_cpu_usage_seconds_total{container!=""}[5m])) / on(namespace,pod,container) max by (namespace,pod,container)(kube_pod_container_resource_requests{resource="cpu"})` | <= 1 | Sustained > 1: lives on burst capacity, loses share under node contention. Size requests near p90 usage |
| Memory composition | `container_memory_working_set_bytes{container="<c>"}/2^20 ; container_memory_rss{container="<c>"}/2^20 ; container_memory_cache{container="<c>"}/2^20` | working set mostly cache = reclaimable | Working set mostly RSS = real pressure |

The container's own pipeline signals (queue depth, buffer, ingest rate) belong to the other reference files; read them in the same window.

**Sampling blind spot.** Container metrics are sampled every scrape interval, so a short memory spike never appears: a container can be OOM-killed while no sample came near the limit. Treat working set / limit as a trend and the `OOMKilled` reason as the proof.

## Operation ladders

Each ladder lists the rungs to run, in order, with what is specific to that operation. Rung numbers refer to the sections above.

### Scale replicas up
1. Rung 1: replica count in spec = target.
2. Rung 2: new pods Running and ready; available count = target after `minReadySeconds`. With an autoscaler, desired = current after its scale-up stabilization window and per-step limit (in the HPA `behavior`, not exported: ask for it).
3. Scheduling: no `PodScheduled=false`, no Pending beyond a few minutes, and node headroom (below) under 0.85 (*interpreted*; leaves room for one more scale step).
4. PVC-backed workloads: every new PVC is Bound (`count by (phase)(kube_persistentvolumeclaim_status_phase==1)`). Pending PVC with `WaitForFirstConsumer` means the pod is not scheduled yet.
5. Rung 4 for the new pods, plus the old pods: their CPU and working set should fall or stay flat.

### Scale replicas down
1. Rung 1 and 2: count in spec = target; pod count = target; terminating pods gone (`kube_pod_deletion_timestamp` exists only while a pod is deleting).
2. **Orphan PVCs**: by default a StatefulSet keeps the PVCs of removed ordinals. List them:
   `max by (namespace,persistentvolumeclaim)(kube_persistentvolumeclaim_info) unless on(namespace,persistentvolumeclaim) max by (namespace,persistentvolumeclaim)(kube_pod_spec_volumes_persistentvolumeclaims_info)`.
   A row is expected after a scale-down with a retaining policy. It is not a leak and not safe to delete until the workload's own drain evidence (profile playbook) says it holds no unsent data.
3. Autoscaler: desired = current after its scale-down stabilization window (the HPA default is long, 300 s, unless `behavior` overrides it). Then one step per policy period, so a multi-step reduction takes several periods.
4. **Survivors absorb the load**: rung 4 CPU and working set on the remaining pods, against their limits. A jump toward the limit means the remaining count is too small.
5. Workload-specific safe-removal checks (queues, buffers) are not in this file; see [SKILL.md § Playbooks](../SKILL.md#playbooks).

### Change CPU (request or limit)
1. Rung 1: new `resource="cpu"` value in requests/limits on every replica.
2. Rung 2: the pods were replaced (start time newer than the change), unless the change was an in-place resize; then `kubelet_pod_in_progress_resizes` returns to 0.
3. Rung 3: CPU spec = quota/period.
4. Rung 4, compared before vs after with the same window and starting at least one window after ready: throttle ratio, CPU pressure, usage vs request.
5. A request increase can leave pods unschedulable: check Pending and node headroom.
6. A new CPU limit makes throttle series appear for the first time (they exist only for containers with a limit). Before the change, the comparison baseline is CPU pressure.

### Change memory (request or limit)
1. Rung 1 and 3: spec = new value; memory spec = `container_spec_memory_limit_bytes`.
2. Rung 4 over a long window (10-30 minutes, *interpreted*): `OOMKilled` with `max_over_time`, restarts, start time, working set / new limit trend.
3. Before approving a **decrease**, compare the new limit with the working-set peak over the last day (`max_over_time(container_memory_working_set_bytes{container="<c>"}[1d])`). A limit below the steady working set guarantees an OOM. A working set already above 0.8 of the old limit means the container is a hotspot: say so even if nothing died yet.
4. Runtime-managed memory (JVM heap, database caps) is sized from the container limit at start, so a limit change can alter application behavior after the restart. Read the application's own memory metric next to the container's.

### Resize a PVC
1. Rung 1: `kube_persistentvolumeclaim_resource_requests_storage_bytes` = new size. **Unchanged means the resize was rejected**; report "no change", which is the correct outcome when the StorageClass does not allow expansion.
2. PV caught up: this query returns empty when each PV capacity equals its PVC request:
   `max by (namespace,persistentvolumeclaim,volumename)(kube_persistentvolumeclaim_resource_requests_storage_bytes * on(namespace,persistentvolumeclaim) group_left(volumename) kube_persistentvolumeclaim_info) != on(volumename) label_replace(max by (persistentvolume)(kube_persistentvolume_capacity_bytes),"volumename","$1","persistentvolume","(.*)")`
   A row: the request was raised and the PV has not been expanded (yet, or ever).
3. Phase stays Bound: `kube_persistentvolumeclaim_status_phase{phase!="Bound"} == 1` is empty.
4. Filesystem actually grown: **NOT-OBSERVABLE** through KSM (it does not export PVC `status.capacity` or resize conditions). Say: "request and PV capacity agree at <size>; filesystem growth is not visible here; the human can confirm with `kubectl get pvc <name> -o jsonpath='{.status.capacity}'`", and list it as a HUMAN step. Some drivers finish the filesystem grow only after a pod restart: check `kube_pod_start_time`.
5. Usage against the new size: `kubelet_volume_stats_used_bytes` / `kubelet_volume_stats_capacity_bytes` when the volume plugin exports them. Check first that the series exist; for hostPath-style volumes they do not. The fallback is the application's own data-size metric next to the request, never a node filesystem number (it describes the host, not the volume).
6. Whether the StorageClass allows expansion is not a label on `kube_storageclass_info`: that is a HUMAN step (`kubectl get sc <name> -o jsonpath='{.allowVolumeExpansion}'`).

## Node saturation (USE)

Utilization, saturation, errors per resource. Read saturation (queues, pressure) before utilization: a resource at 40% busy can still have waiting work.

| Resource | Query | OK | Deviation |
|---|---|---|---|
| CPU utilization | `1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))` | < 0.8 sustained (*interpreted*) | Sustained above: no headroom for bursts |
| CPU saturation | `rate(node_pressure_cpu_waiting_seconds_total[5m])` | < 0.1 (*interpreted*) | Tasks wait for CPU even when utilization looks low; the host is contended |
| Memory | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes` | > 0.15 (*interpreted*) | Low: reclaim and OOM risk. Also `rate(node_pressure_memory_waiting_seconds_total[5m])` |
| Disk utilization and queue | `rate(node_disk_io_time_seconds_total{device="<dev>"}[5m]) ; rate(node_disk_io_time_weighted_seconds_total{device="<dev>"}[5m])` | utilization < 0.8 and average queue < 1-2 (*interpreted*) | Busy device with a growing queue: IO bound. Also `rate(node_pressure_io_stalled_seconds_total[5m])` |
| Disk writer | `topk(6, sum by (namespace,pod,container) (rate(container_fs_writes_bytes_total{container!=""}[5m])))` | names the top writer | Attribute node disk load to a workload with this, then check that workload |
| Filesystem free | `node_filesystem_avail_bytes{mountpoint="<mount>",fstype!~"tmpfs\|ramfs"} / node_filesystem_size_bytes{mountpoint="<mount>",fstype!~"tmpfs\|ramfs"}` | > 0.15 (*interpreted*) | Find the mountpoint that holds volume data from `node_filesystem_size_bytes`. Local-path style volumes all share it |
| Network errors, drops | `sum by (instance,device)(rate(node_network_receive_drop_total[5m]) + rate(node_network_transmit_drop_total[5m]) + rate(node_network_receive_errs_total[5m]) + rate(node_network_transmit_errs_total[5m])) > 0` | empty | A series: NIC or CNI problem; pair with `sum(rate(container_network_receive_errors_total[5m])) + sum(rate(container_network_transmit_errors_total[5m]))` |
| Network by pod | `topk(5, sum by (namespace,pod)(rate(container_network_receive_bytes_total{pod!="",interface="eth0"}[5m])))` | follows the load | Pods on the host network report whole-node traffic: set them aside |

**Node headroom** (requested vs allocatable), per node and resource:
`sum by (node,resource) (kube_pod_container_resource_requests{resource=~"cpu|memory"} and on(namespace,pod) (kube_pod_status_phase{phase=~"Running|Pending"}==1)) / on(node,resource) group_left kube_node_status_allocatable{resource=~"cpu|memory"}`
Under 0.85 leaves room for a scale-up (*interpreted*); above 1 means a pending pod cannot be placed.

**Node health**: `kube_node_status_condition == 1 ; kube_node_spec_unschedulable ; kube_node_spec_taint`. PASS: `Ready` true, every `*Pressure` false, no cordon. Always compare with `== 1`. Evict risk before voluntary disruption: `kube_poddisruptionbudget_status_pod_disruptions_allowed` >= 1 (0 blocks the next eviction).

**Shared-kernel nodes.** When node-exporter values are identical across nodes (nested or containerized nodes), the "nodes" are one host: report one host, and attribute load per node only from cAdvisor series (`node` label). node-exporter series have no `node` label; map `instance` to a node with `node_uname_info` (`nodename`).

## Label traps

- **Container filter.** cAdvisor emits up to three series per pod (the container, the pause sandbox, the pod-level cgroup). Always add `container!=""` for per-container sums, or usage is double counted; add `pod!=""` too, because the node root cgroup appears with empty `namespace` and `pod`.
- **One `job`, three paths.** cAdvisor, kubelet and probes share the kubelet `job`; select with `metrics_path` (`/metrics/cadvisor`, `/metrics`, `/metrics/probes`).
- **"No limit" is encoded two ways.** KSM: series absent. cAdvisor `container_spec_memory_limit_bytes`: present with value 0. A ratio built on cAdvisor needs `(limit > 0)`; on KSM, unlimited containers silently disappear from the result.
- **CFS series exist only for containers with a CPU limit.** For the rest, "no throttle data" is not "no throttling": use PSI.
- **Network series** live on the pause sandbox with several interfaces, of which only one carries traffic; filter `interface="eth0"`.
- **KSM object vs scraper labels, one-hot `== 1`**: [sop-translation.md § Label traps](sop-translation.md#label-traps-read-these-before-writing-queries).
- **Pod re-creation is invisible by id.** KSM drops `uid`, so a re-created StatefulSet pod is the same series. Detect it with `kube_pod_start_time`/`kube_pod_status_ready_time`.
- **KSM restart splits series.** `instance` is the KSM pod IP; after a KSM restart every series exists twice for a while. Aggregate with `max by (...)` across the boundary.
- **`kube_pod_status_ready` for completed Jobs** reads 0. Exclude `phase="Succeeded"`.
- **Sparse series.** `kube_pod_container_status_waiting_reason`, `kube_pod_deletion_timestamp` and `scheduler_unschedulable_pods` exist only while the condition holds. Empty is healthy only when rung 0 passed.

## Not observable (read-only)

| Fact | Closest proxy |
|---|---|
| Kubernetes events (`FailedScheduling`, OOM `Killing`, `FailedMount`, `Evicted`) | KSM state in this file; events appear in logs only if an event exporter feeds the log store (profile) |
| `container_oom_events_total` as the OOM detector | Not reliable: the killed cgroup is replaced and the counter restarts at 0. Use `max_over_time` of `last_terminated_reason` plus restart increase; `node_vmstat_oom_kill` is host-wide |
| Applied in-place resize status (`PodResizePending`, container status resources) | KSM exports none: cgroup comparison in rung 3 plus `kubelet_pod_in_progress_resizes` |
| PVC `status.capacity`, `FileSystemResizePending` (KSM does not export them) | PV capacity vs PVC request; HUMAN `kubectl get pvc -o yaml` |
| PVC used bytes and inodes when `kubelet_volume_stats_*` is absent | Application data-size metric next to the PVC request |
| StorageClass `allowVolumeExpansion` | HUMAN `kubectl get sc` |
| Why a pod is unschedulable | `kube_pod_status_scheduled{condition="false"}==1`, sustained Pending, `scheduler_unschedulable_pods` |
| HPA `behavior` windows; an autoscaler's own state when not scraped | `kube_horizontalpodautoscaler_*` for the HPA (absent = no HPA); ask the human for the spec |
| `Progressing=False` / `ProgressDeadlineExceeded` wording, `CrashLoopBackOff` series | Expected behavior of the product; query `kube_deployment_status_condition{condition="Progressing",status="false"} == 1` and `kube_pod_container_status_waiting_reason` but treat an empty result as unverified until rung 0 passes |
