// Read-only query helper for a logged-in Grafana tab, with a built-in request budget.
// Paste the whole function into Playwright `browser_evaluate` (function param) or
// Chrome DevTools MCP `evaluate_script`, after editing RANGE and QUERIES.
// It calls POST /api/ds/query, the endpoint dashboard panels use, so it works with a Viewer
// session and the cookie already in the tab.
//
// `ds` is a datasource name or uid; the helper resolves uid and type from /api/frontend/settings.
// Each query carries exactly one of:
//   expr  datasource type `prometheus` or `victoriametrics-metrics-datasource` (VictoriaMetrics
//         behind either type speaks MetricsQL).
//         instant: true -> one value per series at RANGE.to; otherwise a range query, step stepMs.
//   sql   datasource type `grafana-clickhouse-datasource`. $__timeFilter(col) = RANGE.
//   raw   any datasource type: one `targets[]` entry copied verbatim from the dashboard JSON
//         (/api/dashboards/uid/<uid>), so the plugin receives its own query model. Replace
//         template variables ($namespace) with literal values first.
// Output is compact rows, not raw frames:
//   expr instant -> {labels, value, at} per series
//   expr range   -> {labels, last, min, max, n, firstAt, lastAt, lastNonZeroAt} per series
//                   (points: true adds [[iso, value], ...])
//   sql / raw    -> one object per row keyed by field name, time fields as ISO strings
//                   (summary: true on a raw query summarises each series like expr range)
//   out.hints[refId]   why an empty answer may not mean "zero" (read the Freshness rules first)
//   out.notices[refId] warnings Grafana attached to the answer (partial results, truncation)
//   out.timing[refId]  milliseconds the query took
//   out.stopped        set when the batch ended early; read `reason` and `retryAfterMs`
//
// REQUEST BUDGET. Grafana is often deployed with a small memory limit, and parallel queries can
// OOM-kill it, so the helper protects it instead of relying on the caller:
//   - one query per request, strictly one after another, with a pause between them (measured
//     from the end of the previous request, also across pastes in the same tab)
//   - the pause doubles (up to 8x) after a slow answer and halves after two fast ones in a row
//   - at most LIMITS.perMinute queries per rolling minute, counted across pastes in this tab
//   - range, SQL and raw queries are refused when RANGE is longer than LIMITS.maxRangeHours
//   - every ClickHouse SELECT/WITH gets the server-side caps it does not set itself (CH_CAPS: 10 s, 50M rows /
//     5 GB read, 10k result rows), added to a trailing SETTINGS clause or as a new one. A query over a cap fails
//     with the server's error (for example code 396), it is not cut short silently; narrow the window or LIMIT
//     (set ALLOW_LONG_RANGE only after telling the human why)
//   - SQL must start with SELECT/WITH/SHOW/DESCRIBE/EXPLAIN, be a single statement, carry a time
//     bound and a LIMIT (or an aggregate)
//   - HTTP 429/5xx or a network error ends the batch: wait retryAfterMs, retry once, then stop
//     and tell the human
//   - a task budget: the first paste of a task sets PLAN (the plan line for the user) and BUDGET (total
//     data queries for the task). That first paste only registers them and returns `declared`: tell the user,
//     then paste again. Without them the helper refuses. It counts queries across pastes in this tab only
//     (a vmui tab on another origin keeps its own count with vm-query.js),
//     reports them in out.budget, and refuses once BUDGET is spent: list what is left and stop, or ask the user
async () => {
  // ---- edit below -------------------------------------------------------------------------
  // Relative ('now-30m') or epoch milliseconds as a string ('1793910150000').
  const RANGE = { from: 'now-30m', to: 'now' };
  const ALLOW_LONG_RANGE = false;
  // First paste of a task: the plan line you already sent the user, and the total data queries you allow yourself
  // (about 60; about 100 for a full health check). Later pastes may leave them empty.
  const PLAN = '';
  const BUDGET = 0;
  const QUERIES = [
    { refId: 'A', ds: 'PROMETHEUS_DS', expr: 'count by (job) (up == 1)', instant: true },
    { refId: 'B', ds: 'PROMETHEUS_DS', expr: 'sum(up == 0) or vector(0)', stepMs: 30000 },
    { refId: 'C', ds: 'CLICKHOUSE_DS', sql: 'SELECT now() AS server_time, version() AS version' },
    // { refId: 'D', ds: 'ANY_DS', raw: { /* a targets[] entry from the dashboard JSON */ } },
  ];
  // ---- edit above -------------------------------------------------------------------------

  const LIMITS = {
    gapMs: { default: 500, 'grafana-clickhouse-datasource': 1500 }, // pause between two queries
    perMinute: 20,        // queries per rolling minute, all pastes in this tab together
    maxQueries: 6,        // queries per paste
    maxRangeHours: 24,
    slowMs: 8000,         // an answer slower than this slows the next queries down
    retryAfterMs: 30000,  // what to tell the caller to wait after a backend failure
  };
  // Server-side caps added to every ClickHouse SELECT/WITH that has no SETTINGS clause of its own, so a
  // badly written query fails fast instead of loading the reader. A query that exceeds one gets an error, not a cut-off result.
  const CH_CAPS = { max_execution_time: 10, max_rows_to_read: 50000000, max_bytes_to_read: 5000000000, max_result_rows: 10000 };
  // Add the caps the query does not set itself: extend a trailing SETTINGS clause, or append one.
  const withCaps = (sql) => {
    const tail = /\bsettings\b[^()]*$/i.exec(sql);
    const missing = Object.entries(CH_CAPS).filter(([k]) => !(tail && new RegExp(`\\b${k}\\b`, 'i').test(tail[0])));
    if (!missing.length) return { sql, added: [] };
    const list = missing.map(([k, v]) => `${k} = ${v}`).join(', ');
    return { sql: tail ? `${sql}, ${list}` : `${sql} SETTINGS ${list}`, added: missing.map(([k]) => k) };
  };

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const iso = (ms) => new Date(ms).toISOString();
  const state = (globalThis.__monitoringOperatorBudget = globalThis.__monitoringOperatorBudget || { calls: [], slow: 1, fastRun: 0, last: 0 });
  const out = { queriedAt: iso(Date.now()), hints: {}, notices: {}, timing: {} };
  // task budget, kept across pastes in this tab
  if (typeof state.used !== 'number') state.used = 0;
  if (PLAN && !state.plan) {
    // first declaration of a task: register it and run nothing, so the user hears the plan before any data query
    state.plan = PLAN; if (BUDGET > 0) state.budget = BUDGET;
    return { declared: { plan: state.plan, budget: state.budget || null, used: state.used || 0 }, next: 'Plan registered, no query sent. If your message with this paste did not already show the user the plan and budget as text, write them now as text (a tool input is not a message), then paste again to run the queries.' };
  }
  if (PLAN) state.plan = PLAN;
  if (BUDGET > 0) {
    if (state.budget && state.budget !== BUDGET) out.notices.budget = `task budget changed from ${state.budget} to ${BUDGET}; say why in the report`;
    state.budget = BUDGET;
  }
  if (!state.budget || !state.plan) return { error: 'declare the task first: send the user your plan and budget ("Plan: <path>. Budget: about N data queries."), then set PLAN and BUDGET in this paste and run it again' };
  const budgetView = () => ({ plan: state.plan, declared: state.budget, used: state.used, left: Math.max(0, state.budget - state.used) });

  const parseTime = (t) => {
    const s = String(t).trim();
    if (s === 'now') return Date.now();
    const rel = s.match(/^now-(\d+)([smhdw])$/);
    if (rel) return Date.now() - Number(rel[1]) * { s: 1e3, m: 6e4, h: 36e5, d: 864e5, w: 6048e5 }[rel[2]];
    return /^\d+$/.test(s) ? Number(s) : Date.parse(s);
  };

  const sqlProblem = (raw) => {
    const s = String(raw).replace(/--.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '').trim().replace(/;\s*$/, '');
    if (!/^(select|with|show|describe|desc|explain)\b/i.test(s)) return 'only SELECT, WITH, SHOW, DESCRIBE or EXPLAIN is allowed';
    if (s.includes(';')) return 'one statement only';
    if (/\b(insert\s+into|alter\s+table|drop\s+(table|database)|truncate|kill\s+query|optimize\s+table|grant\s|revoke\s|rename\s+table|attach\s|detach\s)/i.test(s)) return 'statement changes state';
    if (/\bfrom\b/i.test(s)) {
      if (!/\$__timeFilter\(|\$__timeFrom|\bnow\(\)|\binterval\b/i.test(s)) return 'add a time bound on the primary-key time column, for example WHERE $__timeFilter(<primary-key time column>)';
      if (!/\blimit\b/i.test(s) && !/\b(count|max|min|sum|avg|uniq\w*|quantile\w*|any)\s*\(/i.test(s)) return 'add a LIMIT';
    }
    return null;
  };

  const settingsRes = await fetch('/api/frontend/settings');
  if (settingsRes.status === 401) return { error: 'session expired: Grafana shows the login page. Ask the human to log in again.' };
  // Built-in pseudo datasources (-- Mixed --, -- Dashboard --, -- Grafana --) have type 'datasource'.
  const realDs = Object.values((await settingsRes.json()).datasources || {}).filter((d) => d.uid && d.type !== 'datasource');
  const dsByKey = Object.fromEntries(realDs.flatMap((d) => [[d.name, d], [d.uid, d]]));
  const PROM_TYPES = ['prometheus', 'victoriametrics-metrics-datasource'];

  const isRange = (q) => q.expr !== undefined && !q.instant;
  const fromMs = parseTime(RANGE.from);
  const toMs = parseTime(RANGE.to);
  const rangeHours = (toMs - fromMs) / 36e5;

  if (QUERIES.length > LIMITS.maxQueries) {
    return { error: `too many queries in one paste (${QUERIES.length} > ${LIMITS.maxQueries}). Split them across pastes and pause between pastes.` };
  }

  // Build every request first, so a bad query is reported without spending budget.
  const jobs = [];
  for (const q of QUERIES) {
    const d = dsByKey[q.ds];
    if (!d) { out[q.refId] = { error: `unknown datasource '${q.ds}'. Known: ${realDs.map((x) => `${x.name} [uid ${x.uid}, ${x.type}]`).join(', ')}` }; continue; }
    const datasource = { uid: d.uid, type: d.type };
    const base = { refId: q.refId, datasource, intervalMs: q.stepMs || 15000, maxDataPoints: 1000 };
    let target = null;
    if (q.raw) target = { ...base, ...q.raw, refId: q.refId, datasource };
    else if (q.expr !== undefined && PROM_TYPES.includes(d.type)) {
      target = { ...base, expr: q.expr, instant: !isRange(q), range: isRange(q), format: isRange(q) ? 'time_series' : 'table' };
    } else if (q.sql !== undefined && d.type === 'grafana-clickhouse-datasource') {
      target = { ...base, editorType: 'sql', format: 1, queryType: 'table', rawSql: q.sql };
    } else {
      out[q.refId] = { error: `datasource '${d.name}' has type ${d.type}: expr needs ${PROM_TYPES.join(' or ')}, sql needs grafana-clickhouse-datasource. Pass raw: a targets[] entry from the dashboard JSON.` };
      continue;
    }
    let sql = target.rawSql;
    if (sql !== undefined) {
      const problem = sqlProblem(sql);
      if (problem) { out[q.refId] = { error: `refused SQL: ${problem}` }; continue; }
      const bare = String(sql).replace(/--.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '').trim().replace(/;\s*$/, '');
      if (/^(select|with)\b/i.test(bare)) {
        const capped = withCaps(bare);
        if (capped.added.length) { target.rawSql = sql = capped.sql; out.notices[q.refId] = 'server-side caps added: ' + capped.added.join(', '); }
      }
    }
    const spansRange = isRange(q) || sql !== undefined || !!q.raw;
    if (spansRange && !(q.raw && q.raw.instant) && rangeHours > LIMITS.maxRangeHours && !ALLOW_LONG_RANGE) {
      out[q.refId] = { error: `refused: range is ${rangeHours.toFixed(1)} h, limit ${LIMITS.maxRangeHours} h. Narrow RANGE, or set ALLOW_LONG_RANGE after telling the human why.` };
      continue;
    }
    jobs.push({ q, d, target });
  }

  const summarise = (fields, cols, q) => {
    const t = cols[fields.findIndex((x) => x.type === 'time')] || [];
    const vIdx = fields.findIndex((x) => x.type === 'number');
    const v = cols[vIdx] || [];
    const nums = v.filter((x) => typeof x === 'number');
    let lastNonZero = null;
    v.forEach((x, i) => { if (typeof x === 'number' && x !== 0) lastNonZero = t[i]; });
    return {
      labels: (fields[vIdx] || {}).labels || {},
      last: v[v.length - 1], min: Math.min(...nums), max: Math.max(...nums), n: nums.length,
      firstAt: t.length ? iso(t[0]) : null, lastAt: t.length ? iso(t[t.length - 1]) : null,
      lastNonZeroAt: lastNonZero === null ? null : iso(lastNonZero),
      ...(q.points ? { points: t.map((ts, i) => [iso(ts), v[i]]) } : {}),
    };
  };

  const stop = (reason, status) => {
    out.stopped = { reason, status: status || null, retryAfterMs: LIMITS.retryAfterMs };
    for (const j of jobs) if (out[j.q.refId] === undefined) out[j.q.refId] = { error: `not run: ${reason}` };
  };

  for (const { q, d, target } of jobs) {
    // rolling per-minute budget, shared by every paste in this tab
    const now = Date.now();
    state.calls = state.calls.filter((t) => now - t < 60000);
    if (state.calls.length >= LIMITS.perMinute) {
      out.stopped = { reason: `request budget: ${LIMITS.perMinute} queries in the last minute`, status: null, retryAfterMs: 60000 - (now - state.calls[0]) };
      for (const j of jobs) if (out[j.q.refId] === undefined) out[j.q.refId] = { error: 'not run: request budget' };
      break;
    }
    if (state.used >= state.budget) {
      out.stopped = { reason: `task budget spent: ${state.used} of ${state.budget} data queries. List each remaining check with its query count and stop, or ask the user for more`, status: null, retryAfterMs: null };
      for (const j of jobs) if (out[j.q.refId] === undefined) out[j.q.refId] = { error: 'not run: task budget spent' };
      break;
    }
    // pause measured from the end of the previous request, also when that one came from an earlier paste
    const wait = (LIMITS.gapMs[d.type] || LIMITS.gapMs.default) * state.slow - (Date.now() - (state.last || 0));
    if (wait > 0) await sleep(wait);
    state.calls.push(Date.now());
    state.used += 1;

    let res;
    const t0 = Date.now();
    try {
      res = await fetch('/api/ds/query', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: String(fromMs), to: String(toMs), queries: [target] }),
      });
    } catch (e) { stop(`network error: ${e.message}. Grafana may be restarting.`); break; }
    const ms = Date.now() - t0;
    state.last = Date.now();
    out.timing[q.refId] = ms;
    // slow answer: double the pause at once; relax only after two fast answers in a row
    if (ms > LIMITS.slowMs) { state.slow = Math.min(state.slow * 2, 8); state.fastRun = 0; }
    else if (++state.fastRun >= 2) { state.slow = Math.max(1, state.slow / 2); state.fastRun = 0; }

    if (res.status === 401) return { error: 'session expired: Grafana shows the login page. Ask the human to log in again.' };
    if (res.status === 429 || res.status >= 500) { stop(`Grafana answered HTTP ${res.status}`, res.status); break; }
    let json;
    try { json = await res.json(); } catch (e) { stop(`unreadable answer (HTTP ${res.status})`, res.status); break; }
    out.httpStatus = res.status;

    const r = (json.results || {})[q.refId] || {};
    if (r.error) {
      out[q.refId] = { error: r.error };
      // row/memory caps: almost always a time bound on a column outside the primary key, or a window too wide
      if (/\bcode:? ?(158|241|396)\b|TOO_MANY_ROWS|MEMORY_LIMIT_EXCEEDED/i.test(String(r.error))) out.hints[q.refId] = 'Hit a server cap. Bound the primary-key time column (see the profile Logs field), narrow the window or tighten LIMIT, then rerun once. Do not raise the cap.';
      continue;
    }
    const notices = (r.frames || []).flatMap((f) => (f.schema.meta && f.schema.meta.notices) || []);
    if (notices.length) out.notices[q.refId] = notices.map((n) => `${n.severity || 'info'}: ${n.text}`);

    const rows = [];
    for (const f of r.frames || []) {
      const fields = f.schema.fields;
      const cols = f.data.values;
      if (isRange(q) || (q.raw && q.summary)) { rows.push(summarise(fields, cols, q)); continue; }
      const n = cols.length ? cols[0].length : 0;
      for (let i = 0; i < n; i++) {
        if (q.expr !== undefined) {
          // Prometheus instant frame: [Time, Value{labels}]
          const vIdx = fields.findIndex((x) => x.type === 'number');
          const tIdx = fields.findIndex((x) => x.type === 'time');
          rows.push({
            labels: (fields[vIdx] || {}).labels || {},
            value: (cols[vIdx] || [])[i],
            at: tIdx >= 0 ? iso(cols[tIdx][i]) : null,
          });
          continue;
        }
        const row = {};
        fields.forEach((fld, j) => {
          const val = cols[j][i];
          row[fld.name] = fld.type === 'time' && typeof val === 'number' ? iso(val) : val;
          if (fld.labels && Object.keys(fld.labels).length) row._labels = { ...row._labels, ...fld.labels };
        });
        rows.push(row);
      }
    }
    if (!rows.length) {
      out.hints[q.refId] = 'No rows. An empty answer is not zero: the name or label may be wrong (check with a labels/series query), the window may hold no samples, or the backend may be frozen (run the Freshness probe). A failed query is an error above, not an empty answer.';
    }
    out[q.refId] = rows.length > 200 ? { truncated: rows.length, rows: rows.slice(0, 200) } : rows;
  }
  out.budget = budgetView();
  return out;
}
