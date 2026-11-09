# Scaling levers (advice; the human decides and acts)

Read this only when the user asks how to scale or resize a stage. It never decides a verdict: first name the
standing stage with [saturation.md](../playbooks/saturation.md), then size it here. HUMAN commands to apply a
change are in saturation.md's HUMAN steps; verify the change afterwards with
[after-change.md](../playbooks/after-change.md).

Sizing rule: to clear backlog `B` in time `T` while inflow `I` continues, the stage needs capacity of at least `I + B/T`.

| Stage | Lever | Sizing |
|---|---|---|
| scrape | more vmagent shards, longer interval, relabel drops | shards >= samples/s / per-shard target; an autoscaler that owns the count takes new min/max/target |
| vmagent send | `remoteWriteSettings.queues` | *interpreted*: queues x (send saturation / 0.5), so each queue is about half busy; past that the remote is the limit |
| vmagent queue | `remoteWriteSettings.maxDiskUsagePerURL` and the PVC | healthy `rate(vmagent_remotewrite_bytes_sent_total)` x longest outage to survive |
| vminsert | replicas (stateless), CPU | concurrency capacity is 2 x cores per pod |
| vmstorage | vertical first: memory for caches (slow inserts over 0.05), CPU (usage over 0.9 or assisted merges), faster disk | a new node receives a share of incoming series once vminsert lists it (re-routed series count as churn), while existing history stays on the old nodes; removing a node hides its history at replicationFactor 1. Neither clears a live backlog |
| aggregator | replicas (an autoscaler may own them), sink batch size | buffer max >= buffer growth rate ([saturation.md](../playbooks/saturation.md) step 4) x longest sink outage |
| exporter | replicas | one pinned connection keeps load on one pod until the aggregator reconnects |
| ClickHouse | memory limit, merge pool, fewer larger inserts, PVC, trim system log tables | memory ratio under 0.8, parts steady |

- **Restarts**: a CPU or memory change made through a workload template (StatefulSet, Deployment, operator resource, Helm values) rolls the pods. In-place resize applies only to a direct pod resize, which the owning controller does not keep; the version gate and the query for it are in [after-change.md step 7](../playbooks/after-change.md#7-in-place-or-recreate-cpu-memory). VictoriaMetrics reads cores and memory at start (`vm_available_cpu_cores`, `vm_allowed_memory_bytes`), so its concurrency and caches follow a resize only after a restart.
