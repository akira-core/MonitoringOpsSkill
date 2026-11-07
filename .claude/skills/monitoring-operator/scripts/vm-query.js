// Read-only query helper for a vmui tab (VictoriaMetrics UI, single-node or cluster vmselect).
// Paste the whole function into Playwright `browser_evaluate` (function param) or
// Chrome DevTools MCP `evaluate_script`, after editing RANGE and QUERIES.
// It calls the same GET Prometheus-API endpoints vmui itself uses, relative to the tab's origin,
// so any vmauth session or basic-auth the tab already holds is reused. It never sends a body.
//
// API base comes from location.pathname, the way vmui derives its own server URL:
//   /select/<accountID>/vmui/...            -> /select/<accountID>/prometheus   (cluster vmselect)
//   /<prefix>/select/<accountID>/vmui/...   -> /<prefix>/select/<accountID>/prometheus (behind vmauth)
//   /vmui/...                               -> ''                               (single-node)
//   /<prefix>/vmui/... or /prometheus/vmui/ -> /<prefix> or /prometheus
// Set API_BASE to override (another tenant: '/select/1:0/prometheus'). The vmui tenant picker does
// NOT change location.pathname, so a tenant chosen in the UI is not followed: set API_BASE.
//
// Each query carries exactly one of:
//   expr      MetricsQL. instant: true -> one value per series at RANGE.to; otherwise a range query,
//             step stepMs (default 15000).
//   endpoint  one of the read-only metadata/status endpoints below; RANGE bounds start/end where
//             the endpoint accepts them.
//     'series'          match: ['up{job="x"}', ...]                       -> [{label: value}, ...]
//     'labels'          match?: [...]                                     -> ['job', ...]
//     'label_values'    label: 'job', match?: [...]                       -> ['<job name>', ...]
//     'tsdb'            topN?: 10, date?: 'YYYY-MM-DD', focusLabel?, match?: [...]
//                                                       -> cardinality object (Cardinality explorer)
//     'top_queries'     topN?: 10, maxLifetime?: '30m'  -> {topByCount, topByAvgDuration, ...}
//     'active_queries'                                  -> [{query, start, end, step, duration}, ...]
//     'alerts'          vmalert proxy (only if vmselect has -vmalert.proxyURL)
//                                                       -> [{state, name, severity, activeAt, value, labels}]
// Any other endpoint or path is refused before a request is made: admin/delete_series, import,
// write, snapshot, /-/reload and /internal/* are unreachable from this helper by design.
// Output is compact rows, not raw JSON:
//   expr instant -> {labels, value, at} per series
//   expr range   -> {labels, last, min, max, n, firstAt, lastAt, lastNonZeroAt} per series
//                   (points: true adds [[iso, value], ...])
//   endpoint     -> as listed above
// REQUEST BUDGET. vmselect here has a small memory limit, so the helper paces itself instead of
// relying on the caller:
//   - requests go strictly one after another, with a pause measured from the end of the previous
//     request (300 ms; 1000 ms before series/labels/label values/tsdb), also across pastes
//   - the pause doubles (up to 8x) after a slow answer and halves after two fast ones in a row
//   - at most 30 requests per rolling minute, counted across pastes in this tab; at most 6 queries per paste
//   - range queries and series/labels lookups are refused when RANGE is longer than 24 h
//     (set ALLOW_LONG_RANGE only after telling the human why)
//   - HTTP 429/5xx or a network error ends the batch: out.stopped = {reason, status, retryAfterMs};
//     wait that long, retry once, then stop and tell the human
//   out.hints[refId] explains why an empty answer is not zero; out.timing[refId] is the request time in ms.
// Lists over 200 entries become {truncated: total, rows: first 200}. NaN/Inf values print as null.
// Range steps may be aligned by VM, so lastAt can trail RANGE.to by up to one step.
// out.partial lists refIds whose answer had isPartial=true (a vmstorage node did not respond):
// treat those numbers as incomplete, not as a drop.
async () => {
  // ---- edit below -------------------------------------------------------------------------
  // Relative ('now-30m') or epoch milliseconds as a string ('1793910150000').
  const RANGE = { from: 'now-30m', to: 'now' };
  const ALLOW_LONG_RANGE = false; // set only after telling the human why a range over 24 h is needed
  const API_BASE = null; // null = derive from location.pathname; or e.g. '/select/0/prometheus'
  const QUERIES = [
    { refId: 'A', expr: 'count by (job) (up == 1)', instant: true },
    { refId: 'B', expr: 'sum(up == 0) or vector(0)', stepMs: 30000 },
    { refId: 'C', endpoint: 'tsdb', topN: 5 },
    // { refId: 'D', endpoint: 'series', match: ['up{job="<vmselect job>"}'] },
    // { refId: 'E', endpoint: 'label_values', label: 'job' },
    // { refId: 'F', endpoint: 'top_queries', topN: 5, maxLifetime: '30m' },
    // { refId: 'G', endpoint: 'alerts' },
  ];
  // ---- edit above -------------------------------------------------------------------------

  const deriveBase = (p) => {
    const cluster = p.match(/^(.*\/select\/[^/]+)\/(?:prometheus\/)?(?:vmui|graph)(?:\/|$)/);
    if (cluster) return `${cluster[1]}/prometheus`;
    const single = p.match(/^(.*?)\/(?:vmui|graph)(?:\/|$)/);
    if (single) return single[1];
    return null;
  };
  const base = API_BASE !== null && API_BASE !== undefined ? String(API_BASE).replace(/\/+$/, '') : deriveBase(location.pathname);
  if (base === null) return { error: `cannot derive the API base from location.pathname '${location.pathname}': open vmui (…/vmui/) or set API_BASE.` };
  // Path segments only, so a vmauth prefix such as /importer/ is not refused by substring.
  if (/(^|\/)(insert|admin|internal|-|api|snapshot|import|write|reload|delete_series)(\/|$)/i.test(base)) {
    return { error: `refused API_BASE '${base}': it points at a write/admin path. Use a .../prometheus read base.` };
  }

  // REQUEST BUDGET (see the header). vmselect has a small memory limit, so the helper paces itself.
  const LIMITS = {
    gapMs: 300,           // pause between two cheap requests
    heavyGapMs: 1000,     // pause before series / labels / label values / tsdb, which scan the index
    perMinute: 30,        // requests per rolling minute, all pastes in this tab together
    maxQueries: 6,        // queries per paste
    maxRangeHours: 24,
    slowMs: 8000,         // an answer slower than this slows the next requests down
    retryAfterMs: 30000,  // what to tell the caller to wait after a backend failure
  };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const state = (globalThis.__monitoringOperatorBudget = globalThis.__monitoringOperatorBudget || { calls: [], slow: 1, fastRun: 0, last: 0 });
  const NO_ROWS_HINT = 'No rows. An empty answer is not zero: the name or label may be wrong (check with a labels/label_values query), the window may hold no samples, or the backend may be frozen (run the Freshness probe). A failed query is an error above, not an empty answer.';
  if (QUERIES.length > LIMITS.maxQueries) {
    return { error: `too many queries in one paste (${QUERIES.length} > ${LIMITS.maxQueries}). Split them across pastes and pause between pastes.` };
  }

  const iso = (ms) => new Date(ms).toISOString();
  const UNIT_MS ={ s: 1e3, m: 6e4, h: 3.6e6, d: 8.64e7, w: 6.048e8 };
  const toMs = (v) => {
    const s = String(v).trim();
    if (/^\d{10,}$/.test(s)) return Number(s);
    const m = s.match(/^now(?:-(\d+)([smhdw]))?$/);
    if (m) return Date.now() - (m[1] ? Number(m[1]) * UNIT_MS[m[2]] : 0);
    throw new Error(`bad RANGE value '${s}': use 'now', 'now-<n><s|m|h|d|w>' or epoch ms`);
  };
  let fromMs, toMsV;
  try { fromMs = toMs(RANGE.from); toMsV = toMs(RANGE.to); } catch (e) { return { error: e.message }; }
  if (fromMs >= toMsV) return { error: `RANGE.from (${iso(fromMs)}) must be before RANGE.to (${iso(toMsV)})` };
  const start = (fromMs / 1000).toFixed(3);
  const end = (toMsV / 1000).toFixed(3);
  const rangeHours = (toMsV - fromMs) / 3.6e6;
  const checkRange = () => {
    if (rangeHours > LIMITS.maxRangeHours && !ALLOW_LONG_RANGE) {
      throw new Error(`refused: range is ${rangeHours.toFixed(1)} h, limit ${LIMITS.maxRangeHours} h. Narrow RANGE, or set ALLOW_LONG_RANGE after telling the human why.`);
    }
  };

  // Allowlist: endpoint -> [path, params]. Nothing else can be requested.
  const LABEL_RE = /^[A-Za-z_][A-Za-z0-9_.:]*$/;
  const matchParams = (q) => (q.match || []).map((m) => ['match[]', m]);
  const ENDPOINTS = {
    series: (q) => {
      if (!q.match || !q.match.length) throw new Error("series needs match: ['selector', ...]");
      return ['/api/v1/series', [...matchParams(q), ['start', start], ['end', end]]];
    },
    labels: (q) => ['/api/v1/labels', [...matchParams(q), ['start', start], ['end', end]]],
    label_values: (q) => {
      if (!LABEL_RE.test(q.label || '')) throw new Error(`label_values needs label: a label name, got '${q.label}'`);
      return [`/api/v1/label/${encodeURIComponent(q.label)}/values`, [...matchParams(q), ['start', start], ['end', end]]];
    },
    tsdb: (q) => ['/api/v1/status/tsdb', [['topN', q.topN || 10], ...(q.date ? [['date', q.date]] : []),
      ...(q.focusLabel ? [['focusLabel', q.focusLabel]] : []), ...matchParams(q)]],
    top_queries: (q) => ['/api/v1/status/top_queries', [['topN', q.topN || 10], ...(q.maxLifetime ? [['maxLifetime', q.maxLifetime]] : [])]],
    active_queries: () => ['/api/v1/status/active_queries', []],
    alerts: () => ['/vmalert/api/v1/alerts', []],
  };
  const SAFE_PATH = /^\/(api\/v1\/(query|query_range|series|labels|label\/[A-Za-z0-9_.:%]+\/values|status\/(tsdb|top_queries|active_queries))|vmalert\/api\/v1\/alerts)$/;

  const get = async (path, params) => {
    if (!SAFE_PATH.test(path)) throw new Error(`refused path '${path}': not a read-only endpoint`);
    const qs = new URLSearchParams(params.map(([k, v]) => [k, String(v)])).toString();
    // rolling per-minute budget, shared by every paste in this tab
    const now = Date.now();
    state.calls = state.calls.filter((t) => now - t < 60000);
    if (state.calls.length >= LIMITS.perMinute) {
      throw Object.assign(new Error(`request budget: ${LIMITS.perMinute} requests in the last minute`), { stop: true, retryAfterMs: 60000 - (now - state.calls[0]) });
    }
    // pause measured from the end of the previous request, also across pastes
    const heavy = /status\/tsdb|\/series$|\/labels$|\/label\//.test(path);
    const wait = (heavy ? LIMITS.heavyGapMs : LIMITS.gapMs) * state.slow - (Date.now() - state.last);
    if (wait > 0) await sleep(wait);
    state.calls.push(Date.now());
    const t0 = Date.now();
    let res;
    try {
      res = await fetch(`${base}${path}${qs ? `?${qs}` : ''}`, { method: 'GET', credentials: 'same-origin' });
    } catch (e) {
      throw Object.assign(new Error(`network error: ${e.message}. The backend may be restarting.`), { stop: true, retryAfterMs: LIMITS.retryAfterMs });
    }
    const text = await res.text();
    const ms = Date.now() - t0;
    state.last = Date.now();
    state.lastMs = ms;
    // slow answer: double the pause at once; relax only after two fast answers in a row
    if (ms > LIMITS.slowMs) { state.slow = Math.min(state.slow * 2, 8); state.fastRun = 0; }
    else if (++state.fastRun >= 2) { state.slow = Math.max(1, state.slow / 2); state.fastRun = 0; }
    if (res.status === 429 || res.status >= 500) {
      const body = text.replace(/\s+/g, ' ').slice(0, 200).trim();
      throw Object.assign(new Error(`HTTP ${res.status}: ${body || 'the backend is overloaded or failing'}`), { stop: true, httpStatus: res.status, retryAfterMs: LIMITS.retryAfterMs });
    }
    let json = null;
    try { json = JSON.parse(text); } catch { /* not JSON: HTML login page, plain-text VM error */ }
    if (res.status === 401 || res.status === 403) throw Object.assign(new Error(`HTTP ${res.status}: not authorised (vmauth session expired?). Ask the human to log in again.`), { httpStatus: res.status });
    if (!res.ok || !json || (json.status && !['success', 'ok'].includes(json.status))) {
      const msg = json && json.error ? `${json.errorType ? `${json.errorType}: ` : ''}${json.error}` : text.slice(0, 300).trim() || res.statusText;
      throw Object.assign(new Error(msg), { httpStatus: res.status });
    }
    return json;
  };

  const num = (v) => (v === null || v === undefined ? null : Number(v));
  const cap = (rows) => (rows.length > 200 ? { truncated: rows.length, rows: rows.slice(0, 200) } : rows);
  const summarise = (s, q) => {
    const pts = (s.values || []).map(([t, v]) => [t * 1000, num(v)]);
    const nums = pts.map((p) => p[1]).filter((x) => typeof x === 'number' && !Number.isNaN(x));
    let lastNonZero = null;
    pts.forEach(([t, v]) => { if (typeof v === 'number' && !Number.isNaN(v) && v !== 0) lastNonZero = t; });
    return {
      labels: s.metric || {},
      last: pts.length ? pts[pts.length - 1][1] : undefined,
      min: Math.min(...nums), max: Math.max(...nums), n: nums.length,
      firstAt: pts.length ? iso(pts[0][0]) : null, lastAt: pts.length ? iso(pts[pts.length - 1][0]) : null,
      lastNonZeroAt: lastNonZero === null ? null : iso(lastNonZero),
      ...(q.points ? { points: pts.map(([t, v]) => [iso(t), v]) } : {}),
    };
  };

  const out = { queriedAt: iso(Date.now()), apiBase: base, hints: {}, timing: {} };
  const partial = [];
  for (let i = 0; i < QUERIES.length; i++) {
    const q = QUERIES[i];
    state.lastMs = null;
    try {
      if (q.path !== undefined) throw new Error(`refused: raw 'path' is not allowed; use expr or endpoint (${Object.keys(ENDPOINTS).join(', ')})`);
      if ((q.expr !== undefined) === (q.endpoint !== undefined)) throw new Error('each query needs exactly one of expr or endpoint');
      if (q.expr !== undefined) {
        const instant = !!q.instant;
        if (!instant) checkRange();
        const json = instant
          ? await get('/api/v1/query', [['query', q.expr], ['time', end]])
          : await get('/api/v1/query_range', [['query', q.expr], ['start', start], ['end', end], ['step', `${(q.stepMs || 15000) / 1000}s`]]);
        if (json.isPartial) partial.push(q.refId);
        const { resultType, result } = json.data || {};
        if (resultType === 'scalar' || resultType === 'string') {
          out[q.refId] = [{ labels: {}, value: num(result[1]), at: iso(result[0] * 1000) }];
        } else if (resultType === 'matrix') {
          out[q.refId] = cap(result.map((s) => summarise(s, q)));
        } else {
          out[q.refId] = cap((result || []).map((s) => ({ labels: s.metric || {}, value: num(s.value[1]), at: iso(s.value[0] * 1000) })));
        }
        if (Array.isArray(result) && result.length === 0) out.hints[q.refId] = NO_ROWS_HINT;
        out.timing[q.refId] = state.lastMs;
        continue;
      }
      const build = ENDPOINTS[q.endpoint];
      if (!build) throw new Error(`refused endpoint '${q.endpoint}': allowed ${Object.keys(ENDPOINTS).join(', ')}`);
      const [path, params] = build(q); // validates the arguments first, so their error wins over the range error
      if (['series', 'labels', 'label_values'].includes(q.endpoint)) checkRange();
      const json = await get(path, params);
      out.timing[q.refId] = state.lastMs;
      if (json.isPartial) partial.push(q.refId);
      if (q.endpoint === 'top_queries') {
        const pick = (list) => (list || []).map((x) => ({ ...x, query: String(x.query).length > 300 ? `${String(x.query).slice(0, 300)}…` : x.query }));
        out[q.refId] = {
          maxLifetime: json.maxLifetime,
          topByCount: pick(json.topByCount), topByAvgDuration: pick(json.topByAvgDuration),
          topBySumDuration: pick(json.topBySumDuration), topByAvgMemoryUsage: pick(json.topByAvgMemoryUsage),
        };
      } else if (q.endpoint === 'alerts') {
        out[q.refId] = cap(((json.data || {}).alerts || []).map((a) => ({
          state: a.state, name: a.name, severity: (a.labels || {}).severity, activeAt: a.activeAt, value: a.value, labels: a.labels,
        })));
      } else if (q.endpoint === 'tsdb') {
        out[q.refId] = json.data;
      } else {
        out[q.refId] = Array.isArray(json.data) ? cap(json.data) : json.data;
        if (Array.isArray(json.data) && json.data.length === 0) out.hints[q.refId] = NO_ROWS_HINT;
      }
    } catch (e) {
      out[q.refId] = { error: e.message, ...(e.httpStatus ? { httpStatus: e.httpStatus } : {}) };
      if (state.lastMs !== null && state.lastMs !== undefined) out.timing[q.refId] = state.lastMs;
      if (e.stop) {
        // backend busy, failing or over budget: end the batch instead of piling on
        out.stopped = { reason: e.message, status: e.httpStatus || null, retryAfterMs: e.retryAfterMs };
        for (const rest of QUERIES.slice(i + 1)) out[rest.refId] = { error: `not run: ${e.message}` };
        break;
      }
    }
  }
  if (partial.length) out.partial = partial;
  return out;
}
