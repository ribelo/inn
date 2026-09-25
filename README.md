# inn

`inn` is a local OpenTelemetry collector and query service written in OxCaml
on Eta. It stores traces, logs, and metrics in one user-level SQLite database
and exposes cwd-independent HTTP and CLI query surfaces.

## State

Default state:

```text
${XDG_STATE_HOME:-~/.local/state}/inn
${XDG_STATE_HOME:-~/.local/state}/inn/telemetry.sqlite
```

Environment overrides:

- `INN_STATE_DIR`
- `INN_DB_PATH`
- `INN_HOST`
- `INN_PORT`
- `INN_BASE_URL`
- `INN_TRACES_RETENTION_HOURS` (default 48)
- `INN_LOGS_RETENTION_HOURS` (default 24)
- `INN_METRICS_RETENTION_HOURS` (default 48)
- `INN_PRUNE_INTERVAL_SECONDS` (default 300)
- `INN_MAX_DB_SIZE_MB` (default 1024)

The caller's current working directory is never used to select the database,
daemon identity, lock path, or query target.

Each signal has its own time-to-live, measured from the time Inn received the
data, not from the client's timestamp. A background pruner runs once at server
startup and then every `INN_PRUNE_INTERVAL_SECONDS`, independent of ingest, and
deletes expired rows in bounded batches. Ingest never runs pruning, so ingest
latency stays stable.

`INN_MAX_DB_SIZE_MB` caps live data, not file size: when the pages in use exceed
the cap, the pruner deletes the oldest telemetry, signal by signal, only until
live data is under the cap, and then returns free pages to the filesystem with
an incremental vacuum. The old single `INN_RETENTION_HOURS` setting is
rejected at startup with a message naming the per-signal settings.

Inn stores an integer schema version in the database. At startup, a database
whose version differs from the one Inn expects, or a file that is not an Inn
database at all, is never silently reused: a mismatched Inn database is deleted
and recreated with a warning, and a foreign file is left untouched and reported
as an error. Telemetry in a replaced database is lost, which is acceptable for
a short-lived debugging cache.

## Build

With the existing shared OxCaml opam switch (`~/.cache/opam/5.4.0+ox`) and a
local Eta checkout next to Inn, run the local-source build and full test suite:

```sh
./scripts/test-local-eta.sh
```

Set `ETA_PATH=/path/to/Eta` before the command if the checkout is elsewhere.
The script enters Eta's Nix shell for native SQLite/OpenSSL dependencies, uses
only the OCaml packages already installed in the shared switch, and builds a
source-file-symlink mirror of Eta under ignored `_dev/`. It installs the
needed Eta libraries under `_dev/eta-install`, then builds and tests Inn
with that local installation first in `OCAMLPATH`. It neither pins nor
installs packages into the shared switch and does not edit Eta. Missing OCaml
dependencies must be addressed outside this workflow, not installed into the
shared switch.

The Alcotest suite runs with `EIO_BACKEND=posix` (set by `test/dune`). Each
short-lived Eio runtime otherwise creates an io_uring ring, and ring creation
fails with `ENOMEM` under a small per-user locked-memory cap, which hides real
failures. The posix backend is the same Eio API without io_uring; the server
itself keeps the default backend.

To check Inn against the previously installed Eta in the shared switch instead:

```sh
export OPAMROOT="$HOME/.cache/opam"
eval "$(opam env --switch 5.4.0+ox --set-switch)"
dune build && dune runtest
```

## Run

```sh
inn server
```

Managed background daemon:

```sh
inn daemon
inn status
inn stop
inn restart
```

Default server address:

```text
http://127.0.0.1:27687
```

## Ingest API

OTLP/HTTP JSON endpoints:

```text
POST /v1/traces
POST /v1/logs
POST /v1/metrics
```

Send OTLP JSON with `Content-Type: application/json`. An empty export succeeds with
HTTP 200 and `{}`. A batch with individually rejected spans returns HTTP 200
with `{"partialSuccess":{"rejectedSpans":1,"errorMessage":"..."}}`;
logs and metrics use `rejectedLogRecords` and `rejectedDataPoints`. Bad JSON
returns 400 with an OTLP `code` and `message`; unsupported content types
return 415, oversized bodies 413, and store failures 503 with `Retry-After: 1`.
Protobuf, gzip, and gRPC are not supported.

Span and log responses include fractional millisecond timestamps and exact
`...UnixNano` strings. Span durations retain sub-millisecond precision. Span
`kind` is lowercase (or null); `status` is `unset`, `ok`, or `error`.
`status=ok` includes unset spans. Attributes retain their JSON value types,
while `attr.<key>=<value>` filters compare the string form of values. Spans
include links and logs without a timestamp use the observed timestamp or
ingestion time.

## Query API

```text
GET /health
GET /services
GET /traces?service=<name>&limit=<n>
GET /traces/search?service=<name>&operation=<name>&status=<ok|error>&attr.<key>=<value>
GET /traces/stats?groupBy=<field>&agg=<count|avg_duration|p95_duration|error_rate>
GET /traces/<trace-id>
GET /traces/<trace-id>/spans
GET /traces/<trace-id>/logs
GET /spans/search?service=<name>&operation=<name>&parentOperation=<name>&attr.<key>=<value>
GET /spans/<span-id>
GET /spans/<span-id>/logs
GET /logs?service=<name>&severity=<text>&contains=<text>&limit=<n>
GET /logs/search?service=<name>&body=<text>&attr.<key>=<value>
GET /logs/stats?groupBy=<field>
GET /ai/calls?model=<model>&provider=<provider>&sessionId=<id>&text=<text>
GET /ai/calls/<span-id>
GET /ai/stats?groupBy=<field>&agg=<count|avg_duration|p95_duration|total_input_tokens|total_output_tokens>
GET /metrics?service=<name>&name=<metric>&limit=<n>
GET /facets?type=<traces|logs>&field=<field>&key=<attribute-key>
GET /stats
GET /instructions
GET /endpoints
GET /openapi.json
```

The `/api/...` prefix is accepted as an alias for query endpoints.

### Windows and cursors

Every list, search, stats, facet, services, and store-stats query takes a
relative `lookback` window: a positive integer followed by `m`, `h`, or `d`
(`15m`, `2h`, `1d`), or the literal `all` for the whole retained history.
The window is resolved once per request against the server clock and applies
to the event timestamp of each signal (span start, log timestamp, metric
timestamp), not to ingestion time.

- Lists and searches default to `1h`. Stats, facets, services, and store
  stats default to `all`, so aggregates stay complete unless narrowed.
- Every list and search also takes `cursor`: the opaque `nextCursor` value
  from the previous response. Later pages reuse the window resolved for page
  one, so paging stays stable while new data arrives.
- List and search responses keep their named collection key and add a sibling
  `meta` object:

  ```json
  {"logs":[...],"meta":{"limit":100,"lookback":"1h","returned":100,"truncated":true,"nextCursor":"eyJ..."}}
  ```

  `nextCursor` appears only when another page exists. Stats and facets add
  `meta` with `lookback` and `limit`; services add `lookback` and `returned`;
  store stats (`/stats`) add `lookback`.
- Ordering is newest first with a unique tie-breaker (trace id, span row id,
  log id, or metric row id), so pages never repeat or skip a row.
- Log records carry a stable `id`, which is also their tie-breaker.
- An invalid lookback, a malformed cursor, a cursor issued for another
  endpoint kind, or a limit outside 1..10000 is a `400` that explains the
  expected format; Inn never ignores a bad window or cursor.

## CLI

The CLI queries the running server. It does not silently open a cwd-local
database.

```sh
inn status
inn health
inn services
inn traces --service api
inn search-traces --service api --operation GET --status error --attr route=/users
inn trace aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
inn trace-spans aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
inn trace-logs aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
inn search-spans --service api --operation GET --attr route=/users
inn span bbbbbbbbbbbbbbbb
inn span-logs bbbbbbbbbbbbbbbb
inn logs --service api --severity ERROR --contains timeout
inn search-logs --service api --body timeout --attr route=/users
inn trace-stats operation count --service api
inn log-stats severity --service api
inn facets traces attribute_keys --service api
inn ai-calls --model gpt-test --provider openai
inn ai-call bbbbbbbbbbbbbbbb
inn ai-stats model count --service api
inn metrics --service api --name requests.total
inn stats
inn endpoints
inn instructions
inn openapi
```

Query commands that accept a time window or page through results use
`--lookback` and `--cursor`; the values are passed to the HTTP API unchanged:

```sh
inn logs --lookback 15m --limit 100
inn logs --lookback all --cursor eyJraW5kIjoibG9nIi...
inn traces --lookback 2h
inn trace-stats operation count --lookback all
```

Use `--base-url` to query a non-default server:

```sh
inn services --base-url http://127.0.0.1:39187
```

## MCP

Inn exposes a stdio MCP server:

```sh
inn mcp
```

The MCP tools proxy to the configured Inn HTTP API and include status, services,
trace/span/log search, trace/log stats, store stats, facets, metrics, endpoint
inventory, AI call search/stats/detail, instructions, and OpenAPI.

`inn_stats` returns the store row counts and the retention section, including
the last prune report, so the pruner is observable without reading server
logs.

List and search tools take `lookback` and `cursor`. `inn_stats`,
`inn_services`, `inn_trace_stats`, `inn_log_stats`, `inn_facets`, and
`inn_ai_stats` take `lookback` only. The tool arguments become the same HTTP
query parameters the CLI sends.

## Eta SQL

The store uses Eta SQL typed builders for schema, writes, reads, and
transactions. Raw SQL is not used in the application storage path. The one
exception is SQLite pragmas, which have no typed API: `page_count`,
`freelist_count`, `page_size`, `auto_vacuum`, and `incremental_vacuum` all run
through one store helper that uses `Eta_sql.Pool.Raw`, the escape hatch
`Eta_sql.mli` documents for pragmas. Known Eta SQL API gaps found while building
Inn are recorded in [.spec/ETA_SQL_DOGFOODING.md](.spec/ETA_SQL_DOGFOODING.md).
