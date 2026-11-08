# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A kind-based Kubernetes monitoring lab, plus experiments on draining the vmagent persistent queue and the Vector disk buffer during scale-down and rolling upgrades. Nothing autoscales: a human scales with `kubectl scale`, like in production. It contains no application code: only Helm values, Kustomize manifests, shell scripts and Grafana dashboard JSON.

User-facing docs (`README.md`, `docs/vmagent-graceful-scaledown.md`) are in Traditional Chinese. Code and manifest comments are in English.

## Commands

```bash
make up                 # scripts/up.sh: kind cluster "monops" + every component; idempotent, ~5 min fresh
make down               # delete the kind cluster
make status             # pods per lab namespace
make grafana            # port-forward localhost:3000, prints admin password

# vmagent scale-down/drain lab (scripts/lab/)
make load N=8           # avalanche replicas (~1000 samples/s each); load only, nothing autoscales
make pin N=3 | N=off    # set shardCount directly (kubectl scale vmagent/lab); off = baseline 2
make outage-start|outage-stop   # pause VMCluster CR + scale vminsert to 0 / restore
make queue              # per pod: targets, on-disk pending, total pending, terminating
make inspect-pvc        # mount unused queue PVCs read-only, print WriterOffset-ReaderOffset + drain log (unused ones exist only with Retain)
make scenario DRAIN=auto|disk|skip   # end-to-end: 3 shards -> outage -> 2 shards -> removed PVCs gone + per-target gaps + drain lines (Retain: inspect them)
OUTAGE_SECONDS=0 HOLD_SECONDS=20 DRAIN=auto scripts/lab/scenario-drain.sh   # healthy-remote variant
OUTAGE_SECONDS=60 HOLD_SECONDS=150 DRAIN=auto scripts/lab/scenario-drain.sh # removed shard drains DURING the outage
DRAIN=skip HOLD_SECONDS=150 scripts/lab/scenario-drain.sh     # negative control; the removed shard's queue is deleted with its PVC, so the gap never heals
make gaps N=3 | N=upgrade            # max interval between raw samples per target during a reshard/upgrade

# Vector lab (scripts/lab/vector/)
make vload N=6 | vpin N=3|off | voutage-start|stop (rotel -> 0) | vqueue | vinspect-pvc | vscenario
```

There is no test suite or linter. Use these checks instead:

- `bash -n scripts/**/*.sh`. Scripts run on macOS `/bin/bash` 3.2, so no `mapfile`, associative arrays or `${x,,}`.
- `sh -n manifests/vmagent-lab/prestop-drain.sh`. That script runs under busybox `sh`/`awk` inside the vmagent Alpine image, so keep it POSIX.
- Vector config: render the chart and run `vector validate --no-environment` inside `timberio/vector:0.61.0-alpine`.
- `kubectl kustomize manifests/<dir>`
- `helm template ... -f helm/values/<file>`
- `make scenario` is the real test of the drain logic.

Every script hard-codes `--context kind-monops` via `k()`/`h()` in `scripts/lib.sh`. Keep it that way: other kind clusters may exist on the host.

## Architecture (cross-file wiring)

**Install order matters** (`scripts/up.sh`):

1. k8s-stack (provides the VM operator CRDs used by VMServiceScrape everywhere).
2. ClickHouse operator → CHI → DDL Job.
3. rotel → Vector → fluent-bit (fluent-bit sends to Vector, so Vector must be up first).
4. vmagent-lab.
5. vector-lab.
6. dashboards.

**Names are coupled across files.** Renaming any of these breaks references elsewhere:

- k8s-stack `fullnameOverride: vmks` → `vminsert-vmks:8480`, `vmselect-vmks:8481`, `vmks-grafana`, `VMCluster/vmks`. These are referenced by:
  - `manifests/vmagent-lab/vmagent.yaml` (remoteWrite)
  - `scripts/lab/outage.sh`
- Vector release `fullnameOverride: vector` (namespace `logging`) → Service `vector:4318`, used by fluent-bit's output. It is also:
  - StatefulSet `vector`, the target of `make vpin` (`kubectl scale`)
  - PVC `data-vector-<n>`, with the buffer at `/vector-data-dir/buffer/v2/rotel/`
  - sink id `rotel`, which is both the buffer directory name and the `component_id` label used in dashboards and scripts
- `ClickHouseInstallation/logs` → Service `clickhouse-logs.clickhouse:8123`. This is referenced by:
  - rotel env
  - the DDL job
  - the Grafana datasource in `helm/values/vm-k8s-stack.yaml`
- `VMAgent/lab` → one StatefulSet per shard, `vmagent-lab-<shard>`, with 2 replicas (pods `vmagent-lab-<shard>-<0|1>`). It is also:
  - PVC `persistent-queue-data-vmagent-lab-<shard>-<replica>`, mounted at `/vmagent_pq/vmagent-remotewrite-data` (= `-remoteWrite.tmpDataPath`)
  - the operator-created ServiceAccount `vmagent-lab`, bound in `rbac.yaml`

**Secrets.** `up.sh` generates them once; re-runs keep them.

- `clickhouse-otel` (namespaces `clickhouse`, `logging`) is the ClickHouse **writer**, user `otel`. It has CREATE/INSERT/SELECT on `otel.*` only. Consumers:
  - CHI via `valueFrom.secretKeyRef`
  - rotel env
  - the DDL job
- `clickhouse-grafana` (namespaces `clickhouse`, `monitoring`) is the **reader**, user `grafana`. It uses the `readonly` profile and SELECT on `otel.*`. It reaches Grafana through `envValueFrom` → `${CLICKHOUSE_GRAFANA_PASSWORD}` in datasource provisioning.
- Both users' `networks` are limited to the kind pod CIDR `10.244.0.0/16` plus localhost (lab scripts run `clickhouse-client` inside the CH pod).
- The reader profile must stay at `readonly=2`, not 1: the Grafana plugin sets `max_execution_time` per query, and `readonly=1` rejects that with code 164.

**Grafana.** Datasources (`VictoriaMetrics` uid, `ClickHouse` uid) come from k8s-stack `defaultDatasources.extra`. Dashboards are ConfigMaps labelled `grafana_dashboard: "1"` and annotated `grafana_folder`; the sidecar searches all namespaces. Lab dashboards are hand-maintained JSON in `manifests/dashboards/`. Vendored upstream dashboards live in `manifests/dashboards/upstream/` (sources in `SOURCES.md`). The HPA one has no data because the lab has no HPA (KEDA was removed).

`scaledown-verify.json` is the read-only verification dashboard used by the `monitoring-operator` skill (`.claude/skills/`).

- Its verdict tables parse log text, so they are coupled to it:
  - V1 parses the `prestop-drain.sh` log line wording: `shard is REMOVED`, `shard SURVIVES`, `DRAINED after`, `TIMEOUT after`, `skip drain`, `total_pending_bytes=`.
  - V3 parses Vector's lifecycle messages.
  - V4 parses the loggen JSON prefix `{"level":"info","app":"loggen","pod":"`.
- Change those strings and the dashboard together.
- The skill's `profiles/monops-lab/scaledown-playbook.md` refers to panel ids, so keep them stable.
- Every lab-specific fact the skill uses lives in `profiles/monops-lab/profile.md`. That includes datasource uids, `job` labels, log columns and freshness thresholds. Update the profile when those change, and keep `SKILL.md`, `scripts/ds-query.js` and `references/sop-translation.md` free of lab names so they stay portable.
- Evals live in `.claude/evals/monitoring-operator/`, outside the skill directory, so a model given the skill cannot read the expected answers.
- Rows are split per pod instance by time gap (V1) or by `Vector has started` (V3), not by `k8s.pod.uid`: fluent-bit caches metadata by pod name, so a re-created pod keeps the old uid.
- V1, panel 14 and panel 28 keep only rows whose `LogAttributes['k8s.pod.name']` equals the `pod=` in `Body`. `make inspect-pvc` reprints arrive with an empty `LogAttributes` (no container name), so a `container != 'inspect'` filter does not remove them.

ClickHouse plugin query `format` values used here:

| value | format |
|---|---|
| 0 | time series |
| 1 | table |
| 2 | logs |

**Logs.** fluent-bit flattens k8s metadata into OTel-style keys (`k8s.namespace.name`, …). These keys become `LogAttributes`, not resource attributes, so `ServiceName` is empty. Query with `LogAttributes['k8s.pod.name']`.

Vector passes OTLP through unchanged (`use_otlp_decoding` + `codec: otlp`). Because of that, the buffer and sink metrics count **one OTLP request as one event**. Only `otlp_in`'s `vector_component_received_events_total` counts log lines, so use it when you need the real ingest rate.

About 0.003% of records arrive with an empty `LogAttributes`; the cause is the fluent-bit tail multiline path. The data is still delivered. A seq-gap check filtered on pod name will report these rows as missing; search by `Body` before concluding data was lost.

## vmagent drain lab: invariants and their reasons

Findings, evidence and trial results are in `docs/vmagent-graceful-scaledown.md`. Before changing `prestop-drain.sh` or `vmagent.yaml`, keep these true:

- The `VMAgent` `/scale` subresource is `spec.shardCount`. Every change rolls **all** shards at once, so preStop runs on survivors too. `DRAIN_MODE=auto` compares `-promscrape.cluster.memberNum` (from `/proc/1/cmdline`) with `vmagents/lab/scale`:
  - **Removed shard**: stop scraping, then wait for total pending to reach 0.
  - **Survivor**: skip. Its PVC is reattached and replayed.
- **Drained** means `vmagent_remotewrite_pending_data_bytes == 0` **and** the retry/error/non-2xx counters have not moved for `DRAIN_QUIET_SECONDS`. A block in retry backoff is not counted by any pending metric, so `DRAIN_QUIET_SECONDS` (15) must stay greater than `-remoteWrite.retryMaxInterval` (10s).
- `preStopSleepSeconds: 0` is required. The operator's default `preStop.sleep` merges with the exec hook, and the API rejects the result.
- The operator mounts `config-out` read-only. It is mounted a second time, writable, at `/drain-config-out` so preStop can write `scrape_configs: []` and POST `/-/reload`. This only works because `config-reloader` has no preStop and exits immediately.
- The in-pod API call uses `SSL_CERT_FILE=<SA ca.crt>` with busybox `wget`, not `--no-check-certificate`. The scale JSON response is pretty-printed, so strip whitespace before running `sed`.
- `persistentVolumeClaimRetentionPolicy` is `Delete` for both fields. The operator removes a shard by deleting its whole StatefulSet, so `whenDeleted` is what fires: the PVCs are marked for deletion with the pods and go away (PVs too) once the pods have exited. That makes the drain the only thing between a scale-down and data loss: a `TIMEOUT` (remote down for longer than `DRAIN_TIMEOUT_SECONDS`) loses the removed shard's queue for good. Set both to `Retain` to keep stranded queues for replay and for `make inspect-pvc`; evals 10 and 12 need that.
- `replicaCount: 2` is what makes rolling no-gap, because the operator updates all shards in parallel with no knob to change that. It is coupled to two other settings; change all three together:
  - VMCluster `dedup.minScrapeInterval: 5s` on vmstorage and vmselect
  - `minReadySeconds: 15`
- Reshard gaps of 6.5–8.5s come from the scrape-phase shift when a target changes owner, not from downtime. HA cannot remove them.

## Vector lab: invariants

- There is no custom drain script. On SIGTERM, Vector stops its sources and each sink drains its disk buffer to empty (disk_v2 reader EOF happens only when the writer is done and size is 0). This is bounded by `VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS` (240).
- `terminationGracePeriodSeconds` (300) must exceed the 15s preStop sleep plus the graceful limit.
- Use the alpine image: the distroless default has no shell for preStop.
- The chart renders `spec.replicas` from the values key `replicas` (2), and `make vpin` changes it with `kubectl scale`, which takes field ownership of `spec.replicas`. Run `make vpin N=off` before a `helm upgrade`; otherwise helm may fail with `conflict occurred` on `spec.replicas` (see the server-side apply note below).
- Offline emptiness check: `buffer.db` stores `writer_next_record` (u64 @0) and `reader_last_record` (u64 @16); `pending = w - r - 1`. Data file size means nothing.
- Change chart-managed fields **only through values files**. Helm 4 uses server-side apply, so a `kubectl set env/edit` makes the next `helm upgrade` fail with `conflict occurred`; recover with `--force-conflicts`.

## Operational gotchas (all hit during development)

- kind renders kubeadm **v1beta3**, so `extraArgs` in `kind/cluster.yaml` must use the map form, not a list.
- Altinity operator ≥0.27.4 rejects `k8s_secret_*` user settings; use `valueFrom.secretKeyRef`.
- `rotel-clickhouse-ddl` creates tables but not the database. The Job's initContainer creates `otel` first.
- In bash under `set -o pipefail`, `cmd | head` or `grep -q` can SIGPIPE the producer and abort the script with rc=141. Use finite producers, or `grep ... >/dev/null`.
- Re-applying `manifests/vmagent-lab` resets `shardCount` to 2. If it had been scaled (`make pin`), that triggers a full-fleet roll.
- Running pods pick up ConfigMap edits to `prestop-drain.sh` only after ~1 min of kubelet sync. Verify with `grep` inside the pod before running a scenario.
- Vector's memory limit is 1Gi: 512Mi was OOMKilled in a crash loop when a pod replayed a large disk-buffer backlog after a rotel outage (loggen lines were lost).
- vminsert's memory limit is 1Gi: 512Mi was OOMKilled once replaying the vmagent backlog after a vminsert outage. At 1Gi a 26-minute outage (87 MB queued across the lab shards) replayed in under a minute with 0 restarts and a peak working set of 627 MiB (61% of the limit).
- Filter `otel.otel_logs` on `TimestampTime` (the `DateTime` in the primary key), never on `Timestamp` alone. The table holds about 57M rows over its 72 h TTL; a `Timestamp` filter scans all of them and fails with code 158 under the skill's 50M-row read cap. Lab dashboards use `$__timeFilter(TimestampTime)`.
- Grafana's memory limit is 2Gi: 512Mi got OOM-killed opening the 27-panel verify dashboard, and 1Gi still restarted under parallel panel queries. Grafana has no persistence, so any restart logs out every browser session and drops users created at runtime.
- Inspect a removed shard's PVC only after its pod is fully gone. `metainfo.json` gets its final offsets at queue close. Chunk file size says nothing about pending data.
