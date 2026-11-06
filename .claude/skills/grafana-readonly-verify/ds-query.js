// Read-only query helper for a logged-in Grafana tab.
// Paste the whole function into Playwright `browser_evaluate` (function param) or
// Chrome DevTools MCP `evaluate_script`, after editing RANGE and QUERIES.
// It calls POST /api/ds/query, the same endpoint dashboard panels use, so it works with a
// Viewer session and the cookie already in the tab. It returns compact rows, not raw frames:
//   SQL     -> one object per row, keyed by column name
//   instant -> one object per series {labels: {...}, value, at}
//   range   -> one summary per series {labels: {...}, last, min, max, n, firstAt, lastAt, lastNonZeroAt}
//              (set points: true on the query to also get [[iso, value], ...])
async () => {
  // ---- edit below -------------------------------------------------------------------------
  // Relative ('now-30m') or epoch milliseconds as a string ('1793910150000').
  const RANGE = { from: 'now-30m', to: 'now' };
  const QUERIES = [
    // VictoriaMetrics (MetricsQL). instant: true -> one value per series at RANGE.to.
    { refId: 'A', ds: 'VictoriaMetrics', expr: 'sum by (pod) (vmagent_remotewrite_pending_data_bytes{job="vmagent-lab"})', instant: true },
    // Range query, summarised per series; stepMs = resolution.
    { refId: 'B', ds: 'VictoriaMetrics', expr: 'count(up{job="vmagent-lab"} == 1)', stepMs: 15000 },
    // ClickHouse (read-only user; SELECT on otel.* only). $__timeFilter(col) = RANGE.
    { refId: 'C', ds: 'ClickHouse', sql: 'SELECT count() AS rows, max(Timestamp) AS newest FROM otel.otel_logs WHERE $__timeFilter(Timestamp)' },
  ];
  // ---- edit above -------------------------------------------------------------------------

  const DS_TYPES = { VictoriaMetrics: 'prometheus', ClickHouse: 'grafana-clickhouse-datasource' };
  const isRange = (q) => !q.sql && !q.instant;
  const body = {
    from: RANGE.from,
    to: RANGE.to,
    queries: QUERIES.map((q) => q.sql
      ? { refId: q.refId, datasource: { uid: q.ds, type: DS_TYPES[q.ds] }, editorType: 'sql', format: 1, queryType: 'table', rawSql: q.sql }
      : { refId: q.refId, datasource: { uid: q.ds, type: DS_TYPES[q.ds] }, expr: q.expr,
          instant: !isRange(q), range: isRange(q), format: isRange(q) ? 'time_series' : 'table',
          intervalMs: q.stepMs || 15000, maxDataPoints: 1000 }),
  };
  const res = await fetch('/api/ds/query', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (res.status === 401) return { error: 'session expired: Grafana shows the login page. Ask the human to log in again.' };
  const json = await res.json();
  const iso = (ms) => new Date(ms).toISOString();
  const out = { httpStatus: res.status, queriedAt: iso(Date.now()) };
  for (const q of QUERIES) {
    const r = (json.results || {})[q.refId] || {};
    if (r.error) { out[q.refId] = { error: r.error }; continue; }
    const rows = [];
    for (const f of r.frames || []) {
      const fields = f.schema.fields;
      const cols = f.data.values;
      if (isRange(q)) {
        const t = cols[0] || [];
        const vIdx = fields.findIndex((x) => x.type === 'number');
        const v = cols[vIdx] || [];
        const nums = v.filter((x) => typeof x === 'number');
        let lastNonZero = null;
        v.forEach((x, i) => { if (typeof x === 'number' && x !== 0) lastNonZero = t[i]; });
        rows.push({
          labels: (fields[vIdx] || {}).labels || {},
          last: v[v.length - 1], min: Math.min(...nums), max: Math.max(...nums), n: nums.length,
          firstAt: t.length ? iso(t[0]) : null, lastAt: t.length ? iso(t[t.length - 1]) : null,
          lastNonZeroAt: lastNonZero === null ? null : iso(lastNonZero),
          ...(q.points ? { points: t.map((ts, i) => [iso(ts), v[i]]) } : {}),
        });
        continue;
      }
      const n = cols.length ? cols[0].length : 0;
      for (let i = 0; i < n; i++) {
        if (!q.sql) {
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
        });
        rows.push(row);
      }
    }
    out[q.refId] = rows.length > 200 ? { truncated: rows.length, rows: rows.slice(0, 200) } : rows;
  }
  return out;
}
