# Inn Architecture

## Invariant

`inn` has exactly one default user-level state location. The caller's current
working directory is never part of daemon identity, database selection, query
selection, lock placement, or registry placement.

## Runtime Shape

`inn server` owns the SQLite database and exposes both ingest and query APIs.
`inn daemon` runs the same server in the background as a managed user-level
process.

Default bind address:

```text
127.0.0.1:27687
```

Default state:

```text
${XDG_STATE_HOME:-~/.local/state}/inn
${XDG_STATE_HOME:-~/.local/state}/inn/telemetry.sqlite
```

Environment:

- `INN_STATE_DIR`: overrides the state directory.
- `INN_DB_PATH`: overrides the database path.
- `INN_HOST`: overrides the host.
- `INN_PORT`: overrides the port.
- `INN_BASE_URL`: overrides CLI/query base URL.
- `INN_RETENTION_HOURS`: controls time-based retention.
- `INN_MAX_DB_SIZE_MB`: controls size-based retention.

Managed daemon runtime files live in the state directory:

- `server.pid`
- `server.json`
- `server.log`

Daemon identity is verified through `/health`, which reports the server pid and
managed daemon instance id. `inn status`, `inn stop`, and `inn restart` use the
state directory and health handshake, never the caller's current directory.

## Signals

`inn` stores traces, logs, and metrics as first-class signals.

Trace and log ingestion follows OTLP/HTTP JSON:

- `POST /v1/traces`
- `POST /v1/logs`
- `POST /v1/metrics`

Metrics are stored generically as metric points with resource attributes,
scope, name, kind, timestamps, value, and point attributes. The initial query
surface focuses on service/name/time filters instead of pretending that all
OpenTelemetry metric temporality and aggregation choices have one universal
view.

## Query Surface

The CLI queries the running server by default. Direct SQLite reads are explicit
under admin/debug commands only.

Core HTTP query endpoints:

- `GET /health`
- `GET /services`
- `GET /traces`
- `GET /traces/search`
- `GET /traces/stats`
- `GET /traces/<trace-id>`
- `GET /traces/<trace-id>/spans`
- `GET /traces/<trace-id>/logs`
- `GET /spans/search`
- `GET /spans/<span-id>`
- `GET /spans/<span-id>/logs`
- `GET /logs`
- `GET /logs/search`
- `GET /logs/stats`
- `GET /ai/calls`
- `GET /ai/calls/<span-id>`
- `GET /ai/stats`
- `GET /metrics`
- `GET /facets`
- `GET /stats`
- `GET /instructions`
- `GET /endpoints`
- `GET /openapi.json`

The `/api/...` aliases exist for query/discovery endpoints.

Core CLI commands:

- `inn server`
- `inn daemon`
- `inn status` / `inn health` / `inn stop` / `inn restart`
- `inn services`
- `inn traces`
- `inn search-traces`
- `inn trace-stats`
- `inn trace <trace-id>`
- `inn trace-spans <trace-id>`
- `inn trace-logs <trace-id>`
- `inn span <span-id>`
- `inn span-logs <span-id>`
- `inn search-spans`
- `inn logs`
- `inn search-logs`
- `inn log-stats`
- `inn ai-calls`
- `inn ai-call <span-id>`
- `inn ai-stats`
- `inn metrics`
- `inn facets`
- `inn stats`
- `inn endpoints`
- `inn instructions`
- `inn openapi`
- `inn mcp`

The MCP server is a stdio JSON-RPC/MCP surface. It advertises read-only tools
for status, services, trace/span/log search and drilldown, stats, facets,
AI call search/detail/stats, metrics, instructions, endpoints, and OpenAPI. Tool calls proxy to the
configured HTTP API.

## Store

SQLite is the durable store. The schema keeps append-friendly signal tables
plus attribute side tables for indexed filtering:

- `spans`
- `span_attributes`
- `logs`
- `log_attributes`
- `trace_summaries`
- `metric_points`
- `metric_attributes`
- `inn_meta`

The server applies migrations and retention. CLI query commands do not run
migrations as a side effect.

The store is implemented through Eta SQL's typed schema/query builders. Raw SQL
is reserved for future cases where a missing Eta SQL capability has been
documented first.

Retention has two triggers:

- time retention deletes rows older than `INN_RETENTION_HOURS`;
- size-pressure retention deletes oldest trace/log/metric batches when the
  database file is over `INN_MAX_DB_SIZE_MB`, letting SQLite reuse freed pages.

## Error Policy

Bad external input fails loudly with structured JSON errors. `inn` does not
silently skip malformed OTLP payloads, does not create cwd-local fallback
databases, and does not query a different store than the configured server.
