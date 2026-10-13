# Debugging with Inn

Inn is a local OpenTelemetry collector and query service. You use it as a
runtime-evidence loop: send traces, logs, and metrics to Inn, then query the
evidence instead of guessing from source.

Default local server:

- Base URL: `http://127.0.0.1:27687`
- OTLP traces: `POST /v1/traces`
- OTLP logs: `POST /v1/logs`
- OTLP metrics: `POST /v1/metrics`
- Query API: `GET /api/...` (every query path also works without the prefix)
- Header: `Content-Type: application/json` — Inn accepts OTLP/JSON only
- Auth: none; Inn binds loopback by default

If the app is already instrumented for another collector, point its OTLP
endpoint at Inn. Otherwise see `GET /docs/effect` for an Effect app and
`GET /docs/ox` for an Ox (OCaml) app.

## Workflow

### 1. Verify Inn is running

```sh
inn status            # server state as JSON
inn health            # raw /health response
curl -fsS http://127.0.0.1:27687/health
```

If Inn is not running, restart its service: `systemctl --user restart inn`.
Do not start another copy of Inn. `/health` reports `version`,
`startedAt`, and `uptimeSeconds`, so you can tell whether the running build
changed or the server restarted. `/ready` answers 200 while the store accepts
queries and 503 when it does not.

### 2. Find the service

```sh
curl -s 'http://127.0.0.1:27687/services?lookback=all'
curl -s 'http://127.0.0.1:27687/services?lookback=1h&signal=metrics'
```

`GET /services` lists every `service.name` seen in spans, logs, or — with
`signal=metrics` — metrics only. Add `lookback` to narrow it. When the caller
knows which service reproduces the problem, use it in every later query; a
service filter keeps result pages small and makes comparisons meaningful.

### 3. Narrow the window, then page

Every list, search, stats, facet, services, and store-stats query takes
`lookback`: a positive integer followed by `m`, `h`, or `d` (`15m`, `2h`, `1d`),
or `all` for the whole retained history.

- Lists and searches default to `1h`.
- Stats, facets, services, and `/stats` default to `all`, so aggregates stay
  complete unless you narrow them.
- The window filters on the event timestamp (span start, log timestamp, metric
  timestamp), never on ingestion time.

Lists and searches also take `cursor`. Every response adds a `meta` object:

```json
{"logs":[],"meta":{"limit":100,"lookback":"1h","returned":0,"truncated":false}}
```

When another page exists, `meta.nextCursor` appears. Pass it back unchanged:
later pages reuse the window resolved for page one, so paging stays stable
while new data arrives. Results are newest first, and an invalid `lookback`,
limit, or cursor is a `400` that explains the expected format — Inn never
silently ignores a bad window.

Copy the cursor verbatim (it is opaque base64url). `inn logs --lookback 15m
--limit 100`, then `inn logs --lookback 15m --cursor <nextCursor>`.

### 4. Search traces

```sh
# Recent traces, newest first
curl -s 'http://127.0.0.1:27687/traces?service=api&lookback=2h'

# Which operation fails?
curl -s 'http://127.0.0.1:27687/traces/search?service=api&operation=users&status=error&lookback=2h'

# Exact attribute, then a literal substring of an attribute value
curl -s 'http://127.0.0.1:27687/traces/search?service=api&attr.http.method=POST'
curl -s 'http://127.0.0.1:27687/traces/search?service=api&attrContains.debug.label=cache'

# Slow traces only
curl -s 'http://127.0.0.1:27687/traces/search?service=api&minDurationMs=500&lookback=2h'
```

`GET /traces/search` filters:

| Parameter | Meaning |
|---|---|
| `service` | Any service that participated in the trace |
| `operation` | Case-insensitive substring of a span operation name |
| `status` | `ok` or `error`. Trace status is whole-trace: `error` means at least one span failed, `ok` means none failed |
| `attr.<key>` | Exact attribute value; keys may repeat |
| `attrContains.<key>` | Literal, case-insensitive substring of an attribute value |
| `minDurationMs` | Trace duration at least this many milliseconds |
| `lookback`, `limit`, `cursor` | Window, page size, page cursor |

Filters combine with AND, and `%`, `_`, and `\` are literal characters, not
SQL wildcards. These attribute filters also work on `/spans/search`, `/logs`,
`/logs/search`, `/logs/stats`, and the correlated log lists; `attrContains.<key>`
additionally works on `/traces/search`, `/spans/search`, `/traces/stats`,
`/logs/search`, `/logs/stats`, and the trace/span log lists.

Trace summaries carry `isRunning` and `warningCount`, so in-flight and broken
traces are visible from the list before you open them.

### 5. Open the trace tree

```sh
curl -s http://127.0.0.1:27687/traces/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
curl -s 'http://127.0.0.1:27687/traces/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/spans?limit=100'
inn trace aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa          # indented tree
inn trace aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --json   # raw response
```

`GET /traces/{traceId}` returns `summary`, `spans`, `logs`, and `warnings`.
Spans come depth-first from the roots, siblings by start time, and every span
carries:

- `depth` — `0` for a root;
- `rootOperationName` — the root operation of the trace;
- `parentOperationName` — set when the parent is in the trace;
- `isRunning` and a null `durationMs` while the span has no end time;
- `warnings` — for example when the parent id is not in the trace.

A span whose parent id is missing becomes a root at depth `0` and carries a
warning; the trace carries the same warning plus one when it has several roots.
`GET /traces/{traceId}/spans` returns the same order and annotations, paged.
`GET /spans/{spanId}` returns one span in the same form. A trace with spans is
served even when its summary row is missing.

### 6. Read the correlated logs

```sh
curl -s 'http://127.0.0.1:27687/logs?service=api&severity=ERROR&lookback=30m'
curl -s 'http://127.0.0.1:27687/logs/search?service=api&body=timeout&minSeverity=warn&lookback=1h'
curl -s 'http://127.0.0.1:27687/traces/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/logs?lookback=all'
curl -s 'http://127.0.0.1:27687/spans/bbbbbbbbbbbbbbbb/logs?lookback=all'
```

- `severity` compares the severity text exactly, ignoring case.
- `minSeverity` accepts `trace`, `debug`, `info`, `warn`, `error`, or `fatal`
  and compares OTLP severity numbers, falling back to text.
- `body` and `contains` are literal, case-insensitive substrings.
- `GET /logs/search` also takes `traceId` and `spanId`, so you can jump from a
  span to its logs in one call.
- Every log record carries a stable `id`, which is also its page tie-breaker.
- `GET /traces/{traceId}/logs` and `GET /spans/{spanId}/logs` list correlated
  logs directly.

### 7. Aggregate and enumerate

```sh
curl -s 'http://127.0.0.1:27687/traces/stats?groupBy=operation&agg=p95_duration&service=api&lookback=1d'
curl -s 'http://127.0.0.1:27687/traces/stats?groupBy=attr.http.route&agg=error_rate&lookback=1d'
curl -s 'http://127.0.0.1:27687/logs/stats?groupBy=severity&service=api&lookback=1d'
curl -s 'http://127.0.0.1:27687/facets?type=traces&field=attribute_keys&lookback=all'
curl -s 'http://127.0.0.1:27687/facets?type=logs&field=attribute_values&key=debug.session'
curl -s 'http://127.0.0.1:27687/stats'
```

- `GET /traces/stats?groupBy=service|operation|status|attr.<key>&agg=count|avg_duration|p95_duration|error_rate`
- `GET /logs/stats?groupBy=service|severity|scope|attr.<key>&agg=count`
- `GET /facets?type=traces|logs&field=...&key=...` — `attribute_keys` lists known
  attribute keys, `attribute_values&key=<key>` lists one key's values with
  counts.
- `/stats` reports live row counts and the retention section, including the
  last prune report.

Aggregates run in SQL over the whole selected window — they are exact, never a
sample of a result page. p95 uses the exact nearest-rank percentile. Facets and
stats carry `meta.lookback`.

Start from `facets?type=traces&field=attribute_keys` when you do not know which
attribute to filter on, then group by `attr.<that.key>` to see which value
carries the failures.

## Instrument

Tag temporary instrumentation with the shared keys so one query finds all of
it:

| Attribute key | Purpose |
|---|---|
| `debug.session` | Groups one debugging session |
| `debug.hypothesis` | Links a point to one hypothesis |
| `debug.step` | Position in the flow (`entry`, `before-write`, ...) |
| `debug.label` | Human-readable description of the point |

Wrap temporary blocks in `#region inn debug` / `#endregion inn debug` markers
(adapt the comment syntax per language) and remove them after the fix is
verified. Then query:

```sh
curl -s 'http://127.0.0.1:27687/spans/search?service=api&attr.debug.session=abc123'
curl -s 'http://127.0.0.1:27687/spans/search?service=api&attr.debug.hypothesis=cache-miss'
curl -s 'http://127.0.0.1:27687/logs/search?service=api&attrContains.debug.label=value+after'
```

Rules: never fix without runtime evidence, keep instrumentation until the fix
is verified, do not log secrets or PII, and revert code from rejected
hypotheses.

## From MCP

The MCP server (`inn mcp`) exposes the same surfaces as tools:

- `inn_status`, `inn_services`
- `inn_search_traces`, `inn_get_trace`, `inn_get_trace_spans`, `inn_get_trace_logs`
- `inn_search_spans`, `inn_get_span`, `inn_get_span_logs`
- `inn_search_logs`
- `inn_trace_stats`, `inn_log_stats`, `inn_stats`
- `inn_metrics`, `inn_facets`
- `inn_endpoints`, `inn_instructions`, `inn_openapi`
- `inn_docs_index`, `inn_get_doc`

List and search tools take `lookback` and `cursor`; `inn_stats`, `inn_services`,
`inn_trace_stats`, `inn_log_stats`, and `inn_facets` take
`lookback` only. Tool arguments become the same HTTP query parameters the CLI
sends. Read this guide over MCP with `inn_get_doc {\"name\": \"debug\"}`.

## Discover the API

- `GET /docs` lists the guides (name, title, path); `GET /docs/debug`,
  `GET /docs/effect`, and `GET /docs/ox` return them as Markdown. An unknown
  name is a 404 that lists the available names.
- `GET /endpoints` is the machine-readable inventory: every route with its
  parameters, responses, and `/api` alias policy.
- `GET /openapi.json` is the full OpenAPI 3.1 document, generated from the same
  declarations the server uses to parse requests.
- `GET /instructions` is short copy-paste setup text that links here.

CLI equivalents: `inn docs`, `inn docs debug`, `inn endpoints`, `inn openapi`,
`inn instructions`, `inn services`, `inn traces`, `inn search-traces`,
`inn trace`, `inn trace-spans`, `inn trace-logs`, `inn search-spans`,
`inn span`, `inn span-logs`, `inn logs`, `inn search-logs`, `inn trace-stats`,
`inn log-stats`, `inn facets`, `inn metrics`, `inn stats`.

## Errors tell you what to do

- `400 invalid_query` names the offending parameter and, for an unknown one,
  lists the supported parameters for that route.
- `404` on a drilldown means the id is not in the retained data.
- `503` on ingest means the store is busy; retry after one second.
- An empty page is not an error: widen `lookback` (or use `all`) and check that
  the service name matches exactly.
