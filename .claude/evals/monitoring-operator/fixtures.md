# Eval fixtures for monitoring-operator

The prompts and assertions are in `evals.json`. This file is how to stage the lab and how to grade.

The skill does not ask for an action log. The contract assertion reads `actions.md`, so the eval
harness appends this to every prompt: "Record each browser and Grafana call you make in
`actions.md` in your output folder, one line per call with its HH:MM:SS time."
The three `Behaviour:` assertions on every eval read those timestamps. They are what a run without the skill
is most likely to fail: the answer can be right while the load on Grafana is not.
It stays outside `.claude/skills/monitoring-operator/` so a model that receives the skill does not
receive the expected answers.

`<TRIGGER_UTC>` in a prompt is replaced by the harness before the prompt is sent. Format:
`YYYY-MM-DDTHH:MM:SSZ`, the scenario start. Leave the token in `evals.json`.

Evals 3, 4 and 8 fetch an SOP page. Serve it before the prompt:

```bash
python3 -m http.server 8765 --directory .claude/evals/monitoring-operator/sop
```

`/` is the Vector scale-down SOP (eval 3). `/sop-resources.html` is the CPU-limit SOP (evals 4 and 8).
The pages are the task input. They are not part of the skill.

Grade the contract assertion on its own. A shell that only reads the skill directory does not fail
the verdict. `kubectl`, cluster access, and credentials do.

## After the 2026-11-07 rebuild

The lab was rebuilt on Kubernetes v1.31.14 (kind v0.31.0, node image `kindest/node:v1.31.14` pinned by
digest). The old cluster and its VictoriaMetrics and ClickHouse data are gone.

- **The 2026-11-05 data used by evals 1 and 2 no longer exists.** The 20:31 UTC vmagent scale-down and
  the 20:56 UTC Vector scale-down are not in the retention of the new cluster. As written, both evals
  have nothing to find: any answer is a guess, and a with-skill run would correctly say INCONCLUSIVE.
  Before grading them, re-stage them (table below) or rewrite them against live data.
- `evals.json` hard-codes the dates, the clock times and the shard / replica counts in the prompts of
  evals 1 and 2 (`2026-11-05`, 20:31, 20:56). They are not `<TRIGGER_UTC>` tokens. This file does not
  change them. Edit `evals.json` and its expected verdicts together when you re-stage.
- Kubernetes is v1.31, so in-place pod resize is unavailable (alpha, gated off). Evals 4 and 8 change a
  CPU limit, which replaces the avalanche pods. Start the throttle window after the new pods are Ready.
  The old pods' counters are gone with them.
- The Grafana memory limit is 2Gi (request 512Mi). Evals still obey the skill's request budget.
- New dashboards: Kubernetes folder (HPA `kubernetes-autoscaling-mixin-hpa-jkwq`, PDB
  `kubernetes-autoscaling-mixin-pdb-jkwq`; the HPA dashboard has no data because the lab has no HPA and no
  autoscaler, so an empty HPA panel is expected and is not evidence), Logs folder (`otel-logs-explorer`, fluent-bit
  `142c9cf84a0b18f347333b278a621c8e3a772c5f`), VictoriaMetrics folder (`ehXxUsGSk`, Alert statistics).
  A model with the skill may now cite them. Accept them as evidence only when the numbers match the
  query. The OTel Logs Explorer shows nothing useful per level or per service here, because
  `SeverityText` and `ServiceName` are empty.

Evals 1–3 were regression against the 2026-11-05 retention (evals 1 and 2 need re-staging now, see above). The `scaledown-verify` text panel already
states the verdict rules, and iteration-1 without-skill passed all three. A pass there does not show
that the skill added anything. The iteration-1 summary "94% ± 10%, 3 runs" is three different evals
stored once each (`run_number` 1). The spread is across evals, not repeated runs.

Do not grade a staged eval until its "ready when" line is true. If the lab cannot reach that state,
skip the eval. Do not flip the expected verdict to match a surprise.

| id | Ready when | Stage |
|---|---|---|
| 1 | A 3 to 2 shard scale-down during a vminsert outage has finished and the removed shard 2 has exited. The old 2026-11-05 20:31 UTC data no longer exists | `OUTAGE_SECONDS=60 HOLD_SECONDS=150 DRAIN=auto scripts/lab/scenario-drain.sh`, then record the trigger time and put it in the prompt in place of the 2026-11-05 text |
| 2 | A Vector 3 to 2 scale-down during a rotel outage has finished, vector-2 was killed before its buffer emptied, and later replayed. The old 2026-11-05 20:56 UTC data no longer exists | `make vscenario` stages the 3 to 2 scale-down during a rotel outage. It does not force a kill: that needs the graceful limit (`VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS`, 240 s by default) to be shorter than the drain time. Not tried after the rebuild. Without the kill the case is a clean drain, which is a different eval |
| 3 | SOP server on `127.0.0.1:8765` and Grafana on `127.0.0.1:3300`, Vector already at 2 replicas | the SOP page. Numbers must come from Grafana, not from `docs/grafana-readonly-verification.md` |
| 4 | Avalanche CPU limit is 50m and the throttled-period ratio since the rollout is above 0.25 | set the limit, wait, confirm the ratio, then substitute `<TRIGGER_UTC>` |
| 5 | Grafana is logged in. No extra fault | none. Grade the table, not a frozen healthy/unhealthy |
| 6 | rotel was at 0 ready from `<TRIGGER_UTC>` for about five minutes, then recovered. Vector buffered | `make voutage-start`, hold, `make voutage-stop` |
| 7 | vminsert is at 0 ready, or only just returned, and the lab vmagent queue grew from `<TRIGGER_UTC>` | `make outage-start` under scrape load. Ask while VictoriaMetrics panels are still frozen, or while the age is still climbing |
| 8 | Avalanche CPU limit is 1 core and the throttled-period ratio since the rollout is under 0.05 | set the limit, wait, confirm the ratio. Skip if the ratio stays at or above 0.05 |
| 9 | `make scenario` (default `HOLD_SECONDS=45`, `DRAIN=auto`) has finished and settled 60 s | that command. Expect `max_total_pending_bytes = 0` |
| 10 | `DRAIN=skip` scale-down has finished, the human has scaled back up with `make pin N=3` (nothing autoscales, so shard 2 stays gone until then), shard 2 is back, and V2 reads PASS | `DRAIN=skip HOLD_SECONDS=150 scripts/lab/scenario-drain.sh`, then `make pin N=3`, wait about 80 s for the replay, then `make pin N=off` if you want the baseline back. The script also sets `DRAIN_MODE` back to `auto`, which rolls survivors once more, and it runs `inspect-pvc`. Ask after V2 has healed. Grade the removed shard's SKIPPED rows, not that later roll |
| 11 | A Vector rolling upgrade with no replica change has settled. Every pod restarted, none was removed | pod-template change through the values file, then `helm upgrade`. Record `<TRIGGER_UTC>` at the start of the roll |
| 12 | A real drain has already been judged, then `make inspect-pvc` has reprinted the old drain log into ClickHouse | `make inspect-pvc` after the removed pod is gone. Ask once the new lines are in `otel.otel_logs` |
| 13 | A Vector pod has shut down gracefully and its last scraped `vector_buffer_size_bytes` point is still above 0 | a normal `make vscenario`, read before the series ages out of the window |

Eval 13 cannot stage a pipeline that is still draining: a surviving Vector pod drains at 4 to 5 MiB/s with rotel at one replica, so even a full 1 GiB buffer is empty in about 4 minutes, and raising `make vload` only lengthens it by seconds. Assertion 4 therefore tests the settled branch (the run must wait, re-read after settling, and say so). The INCONCLUSIVE branch (V4 and the overall answer tagged while a buffer is still draining) was seen once, in iteration 3, by reading within a minute of rotel returning; it is not reproducible on demand here. A slower Vector sink (a rate limit in `helm/values/vector.yaml`) would make it stageable.

`DRAIN=skip` left at 2 shards, with nobody having scaled back up (V1 FAIL and V2 still failing), is not its
own eval. Eval 10 is the case that looks healthy after replay. The still-scaled-down case is easier and
does not add a trap.

No autoscaler runs in the lab (KEDA removed). Evals never depend on one: every scale change is a human
`kubectl scale` (or `make pin` / `make vpin`, which set the count directly), and every `<TRIGGER_UTC>` is
the time of that human step.
