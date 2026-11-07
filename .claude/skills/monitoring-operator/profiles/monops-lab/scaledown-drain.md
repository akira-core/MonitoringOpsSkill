# Playbook: graceful scale-down, drain and rolling upgrade (this lab)

**Goal.** Prove, through Grafana alone, two things about a scale-down:

1. The removed vmagent shard or Vector pod left an **empty** queue PVC.
2. No data was lost.

The PVC files themselves (`metainfo.json`, `buffer.db`) are NOT-OBSERVABLE. Two proxies stand in for
them, and **both** must pass:

- **Exit evidence**: the component's own final log lines say it drained before exiting.
- **Data evidence**: the data it was holding reached storage (no gap / no missing seq).

Dashboard: `/d/scaledown-verify` (folder Lab). Its text panel repeats these rules. Panel ids:

| id | panel | read as |
|---|---|---|
| 3 | Pods per shardCount (rolling progress) | stat, one value per `shardCount=N` |
| 6 / 7 / 8 | vmagent terminating pods / total pending bytes / vminsert up | stat |
| 9 | Per-pod queue now (vmagent) | table: pod, terminating, memberNum, shardCount_flag, pending |
| 28 | Drain progress now (preStop log, last 2 min) | table from ClickHouse; **stays live while VictoriaMetrics is down** |
| 12 | **V1** vmagent preStop drain verdict | table, one row per pod instance |
| 13 | **V2** vmagent max gap between stored samples per avalanche target | table |
| 14 | preStop drain log lines | logs (evidence) |
| 16–20 | Vector desired / ready / terminating / buffer bytes / rotel ready | stat |
| 22 | Per-pod buffer now (Vector) | table |
| 25 | **V3** Vector shutdown verdict | table, one row per pod instance |
| 26 | **V4** loggen end-to-end completeness | table |
| 27 | Vector lifecycle lines | logs (evidence) |

Read tables with `viewPanel=<id>` and `browser_find` (regex `PASS|FAIL|WAIT|SURVIVOR` plus pod names).
Watch live values with `ds-query.js` and the queries behind panels 9 and 22.

## HUMAN triggers

You observe; the human triggers. Ask for the UTC time of each trigger. Set the window to
`from = trigger − 60 s`, `to = now`.

| Intent | Command the human runs |
|---|---|
| vmagent scale-down during a remote-storage outage (positive) | `OUTAGE_SECONDS=60 HOLD_SECONDS=150 DRAIN=auto scripts/lab/scenario-drain.sh` |
| vmagent negative control (drain disabled) | same command with `DRAIN=skip KEEP_PINNED=1`, then `make pin N=off` after verification |
| Vector scale-down during a rotel outage (positive) | `make vscenario` |
| Vector negative control (outage outlasts the 240 s graceful limit) | `HOLD_SECONDS=300 scripts/lab/vector/scenario.sh`, then `make vpin N=3` (replay) and `make vpin N=off` |
| natural KEDA scale-down | `make load N=2` / `make vload N=2` after a scale-up |
| rolling upgrade | any pod-template change (vmagent: edit `manifests/vmagent-lab/vmagent.yaml`; Vector: values file + `helm upgrade`) |

`make scenario` (`HOLD_SECONDS=45`) can delete the removed shard only **after** the outage is over:
the operator rolls the survivors first. The drain then has nothing to do. V1 still says PASS, but
`max_total_pending_bytes = 0` gives this away. Report that as **PASS (drain not exercised)**.

## Phases

### A. Baseline (before the trigger)

| Check | Expected |
|---|---|
| Panel 3 | one `shardCount` value |
| 6, 18 (terminating) | 0 |
| 7 (total pending) | 0 B |
| 19 (buffer bytes) | about 0 |
| 8 (vminsert up), 20 (rotel ready) | ≥ 1 |

If the baseline is not clean, the system is already moving. Say so and wait, or mark the run INCONCLUSIVE.

### B. During (poll every 15–30 s; keep a timestamped log of what you saw)

**vmagent**

1. Panel 3 shows two `shardCount` values while pods roll. Survivors restart too: the operator rolls **every** shard on a shardCount change, and the survivors' preStop logs `SURVIVES` and `skip drain`.
2. The pods of the removed shard (`memberNum >= new shardCount`) show `TERMINATING`.
3. **The remote-storage outage blinds every VictoriaMetrics panel.** Panels 3–10 freeze at their pre-outage values: pods still `running`, pending `0 B`, vminsert `up`. Do not read them as "healthy" or as "0".
4. During the outage, watch **panel 28** (ClickHouse). Each draining pod logs every 2 s:
   - `total_pending_bytes` stays above 0 while storage is down, and `retry_error_counter` climbs.
   - After storage is back, pending falls to 0, `quiet` counts up to `15/15s`, and the pod exits. It then drops off the table, which only shows the last 2 min.

**Vector**

1. The removed `vector-N` shows `TERMINATING` in panel 22.
2. **Its buffer columns go blank at SIGTERM.** The `prometheus_exporter` sink stops with the rest of the topology, so a draining Vector pod exports no metrics at all. Only the surviving pods' buffers stay visible; they grow while rotel is down (20 = 0).
3. Its lifecycle lines in panel 27 (`Shutting down… remaining_components="rotel" time_remaining=…`) show the countdown. While rotel itself is down, those lines are buffered on the other Vector pods and arrive only after rotel is back.
4. So during a rotel outage the draining pod is visible only as `TERMINATING`. Judge it after recovery with V3 and V4.

### C. Settled (gate before reading verdicts)

All of these must hold:

- Terminating = 0 (6 and 18).
- Total pending = 0 (7).
- Buffer bytes = 0 (19).
- vminsert and rotel are up.
- Then wait **60 s more**. Verdict log lines travel container → fluent-bit → Vector → rotel → ClickHouse.

Read the final verdict without `refresh` in the URL.

### D. Verdict

**vmagent: PASS** when both hold:

- **V1**: every `REMOVED` row is `PASS` (result `DRAINED`). `SURVIVOR` rows are expected and neutral.
- **V2**: every target ≤ 15 s.

**V1 is the deciding check; V2 can heal.** When the removed ordinal comes back (KEDA scale-up, `make pin N=off`), its Retain'd PVC is reattached and replayed, and the V2 gap fills in. Observed: after `DRAIN=skip`, 1.88 MB was stranded per PVC. KEDA resumed and scaled back to 3 shards, and about 80 s later V2 read PASS on every target. So:

- V2 PASS never proves the drain worked.
- V2 FAIL is only visible while the removed shard stays away.
- Read V2 promptly after settling, and note whether shard `N` has reappeared (panel 9).

Also report `max_total_pending_bytes` of the REMOVED rows:

- `> 0`: the drain was exercised.
- `= 0`: PASS (drain not exercised).

**Vector: PASS** when both hold:

- **V3**: every row of the removed pod(s) is `PASS` (`Vector has stopped.`, `forced_kills = 0`).
- **V4**: `missing = 0` for every loggen pod. `duplicates > 0` is fine (at-least-once retries).

V4 heals the same way V2 does, once `vector-N` returns and replays its PVC. That makes **V3 the deciding check**.

**Rolling upgrade, no scale change**:

- vmagent: V1 has only `SURVIVOR` rows, V2 ≤ 15 s, and panel 3 ends with one value.
- Vector: one V3 `PASS` row per pod, and V4 `missing = 0`.

## Failure signatures

| What went wrong | What Grafana shows |
|---|---|
| vmagent drain disabled (`DRAIN=skip`) | V1: `result=SKIPPED`, `role=unknown` → FAIL on every row. V2: the targets the removed shard owned show a gap → FAIL. Measured: 75.6 s and 76.8 s on 2 of 4 targets, the others 5–6 s; 1.81 MB stranded per PVC. |
| vmagent drain timed out | V1: `result=TIMEOUT`, `last_total_pending_bytes > 0` → FAIL |
| Vector hit `VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS` | V3: `forced_kills ≥ 1` → FAIL. V4: `missing > 0` until the same ordinal starts again and replays its PVC (Retain). Measured: vector-2 forced after 4.00 min, 42 records stranded, `missing = 3780` on one loggen pod. After `make vpin N=3`, `missing` returned to 0. |
| Unplanned container restart | an extra V3 row for a pod nobody scaled. Measured: vector-1 failed its liveness probe while replaying a 60 MiB backlog. It was graceful (8 ms), but it is still worth reporting. |
| Lines still in flight | V4 `missing > 0` while any Vector buffer > 0. This is not a failure yet: settle first. |

## Gotchas specific to these checks

- **Pod names are reused** by every roll. Fluent-bit caches pod metadata by name, so `k8s.pod.uid` can be stale. V1 splits sessions by a > 30 s gap between lines; V3 splits at `Vector has started`.
- **The PVC inspector re-prints old drain logs.** `scripts/lab/inspect-pvc.sh` (container `inspect`) prints the drain log saved on the PVC, and those lines reach ClickHouse with a new `Timestamp`. The dashboard excludes that container; add `LogAttributes['k8s.container.name'] != 'inspect'` to your own queries too.
- **KEDA desired shards** (panel 4) is blank or stale while KEDA is paused (`make pin`). Resuming KEDA can trigger one more roll. Trust panel 3 for the real shardCount.
- **Vector exits** within milliseconds of an empty buffer, so its last scraped buffer value (10 s scrape) can still be above 0. Judge with V3 and V4, never with that last point.
- **Delayed verdict lines**: during a rotel outage, verdict log lines (V1 and V3 alike) reach ClickHouse only after rotel is back.
