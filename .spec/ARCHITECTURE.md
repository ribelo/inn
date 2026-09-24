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
- `INN_TRACES_RETENTION_HOURS`: trace TTL in hours (default 48).
- `INN_LOGS_RETENTION_HOURS`: log TTL in hours (default 24).
- `INN_METRICS_RETENTION_HOURS`: metric point TTL in hours (default 48).
- `INN_PRUNE_INTERVAL_SECONDS`: seconds between background prune passes
  (default 300).
- `INN_MAX_DB_SIZE_MB`: caps live data, not file size.

`INN_RETENTION_HOURS` is retired and makes configuration resolution fail with a
message that names the per-signal settings.

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

The server opens the store, applies the schema, and runs retention. CLI query
commands do not open the database or run schema statements as a side effect.

The store is implemented through Eta SQL's typed schema/query builders. The one
documented exception is SQLite pragmas, which have no typed API: `page_count`,
`freelist_count`, `page_size`, `auto_vacuum`, and `incremental_vacuum` run
through one store helper built on `Eta_sql.Pool.Raw`. No other raw SQL is used.

The store owns one integer schema version, stored in `inn_meta`. Opening the
store reads the file before any schema statement runs: a missing or empty
database is created, a database with the expected version is opened as-is, a
database with a different version is deleted (including `-wal` and `-shm`) and
recreated after one warning that names both versions and the path, and a file
that has tables but no Inn metadata table is refused with an error instead of
being deleted. Every schema change bumps the version; a test compares a
fingerprint of the compiled schema statements with a recorded value so a
missing bump fails the suite.

Retention is per signal, measured from ingestion time, and runs in a background
pruner fiber that starts with the server: one pass at startup, then one pass per
`INN_PRUNE_INTERVAL_SECONDS`. Ingest never prunes. Each pass deletes expired
rows in bounded batches (whole traces, keyed on the trace summary's last-update
time), and then, while live bytes — `(page count - freelist count) * page
size` — are over `INN_MAX_DB_SIZE_MB`, the oldest telemetry signal by signal
until live data is under the cap. A pass that deleted rows ends with an
incremental vacuum. New databases are created with `auto_vacuum=INCREMENTAL`.
The store exposes the last prune report through the stats retention section.

## Error Policy

Bad external input fails loudly with structured JSON errors. `inn` does not
silently skip malformed OTLP payloads, does not create cwd-local fallback
databases, and does not query a different store than the configured server.
