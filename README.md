# inn

`inn` is a local OpenTelemetry collector and query service written in OxCaml
on Ox. It keeps the newest traces, logs, and metrics of the local apps in a
fixed amount of disk, and exposes cwd-independent HTTP and CLI query surfaces.
It is a cache for debugging the run you just did, not an archive.

## State

Default state:

```text
${XDG_STATE_HOME:-~/.local/state}/inn
${XDG_STATE_HOME:-~/.local/state}/inn/segments/segment-0.sqlite … segment-7.sqlite
```

Environment overrides:

- `INN_STATE_DIR`
- `INN_HOST`
- `INN_PORT`
- `INN_BASE_URL`
- `INN_MAX_DB_SIZE_MB` (default 1024): the whole store budget

The caller's current working directory is never used to select the store or
the query target.

### A fixed budget, kept by deleting files

The store is a ring of eight SQLite segment files. All writes go to the active
segment. When the active segment holds one eighth of `INN_MAX_DB_SIZE_MB`, the
next segment in the ring is deleted, created empty, and becomes active. So the
oldest eighth of the data goes in one file deletion, the newest data is always
accepted, and the store stays near its budget. There is no pruner, no
time-to-live, and no vacuum: nothing runs in the background that can stop.
`INN_DB_PATH`, `INN_RETENTION_HOURS`, `INN_TRACES_RETENTION_HOURS`,
`INN_LOGS_RETENTION_HOURS`, `INN_METRICS_RETENTION_HOURS`, and
`INN_PRUNE_INTERVAL_SECONDS` are refused at startup with a message, so an old
setting is never silently ignored.

One reader connection attaches all eight segments and queries them through
temporary views with the table names the queries use. A trace whose spans fall
in two segments is combined: its summary adds the parts, and its detail
assembles one tree. In the trace list, a span whose parent is in another
segment counts as a missing parent in `warningCount`; the trace detail is
exact.

### Ingest limits

Inn cuts oversized data when it arrives, so one program cannot fill the store:

- A string attribute value longer than 1 KB is cut to 1 KB; a list or object
  attribute whose JSON is longer becomes that cut JSON text.
- A log body or a span status message longer than 8 KB is cut to 8 KB.
- A record with any cut value carries the attribute `inn.truncated = true`.
- At most 5,000 spans of one trace go into one segment. Later spans of that
  trace are dropped, and the trace summary counts them in `droppedSpanCount`.

Every attribute is stored once, as JSON in its record. The attribute index
that `attr.<key>` and `attrContains.<key>` filters, attribute facets, and
attribute statistics use holds only values up to 256 bytes.

A trace summary is updated from the spans of the trace in the active segment,
never by reading and decoding the whole trace, so the memory of a write depends
on the batch, not on the length of the trace.

### Schema versions

Each segment stores an integer schema version. At startup, a segment whose
version differs from the one Inn expects, or a file in its place that Inn
cannot read, is deleted and created empty with a warning. Telemetry in a
replaced segment is lost, which is acceptable for a debugging cache.

## Build

Use `nix develop`, which loads the shared OxCaml opam switch
(`~/.cache/opam/5.4.0+ox`). Shared Ox packages are installed from committed source
by the Ox checkout's `ox-opam-install`; Inn declares `ox_lint` as a build-only
dependency alongside `ox_caps`.

Run all four gates before committing:

```sh
export INN_ETA_GUIDE_SNIPPET=1
nix develop -c dune build @install @check
nix develop -c dune test
nix develop -c dune build @fmt
nix develop -c scripts/caps-gate
```

The capability gate runs **after a build** with the same compiler and dependency
graph. Its mandatory source tier needs no build artefacts; the typed tier needs
Inn's own fresh `.cmt`/`.cmti` evidence and matching CMI fingerprints. The local
launcher rebuilds `@install @check` before invoking the installed Ox gate beside
`ox_caps`, which resolves executable `bin/ox-lint` in the same prefix. Require
zero findings and zero modules with typed rules undecided for every production source;
an undecided module is not checked typed coverage.

The CLI receives capabilities through arguments from the Door; every production
source is checked without allowances. ^inndoor-m8sw

`INN_ETA_GUIDE_SNIPPET=1` includes the compiled exporter snippet and its test
against an isolated Inn, keeping `docs/guides/ox.md` aligned with the Ox API.
The Alcotest suite uses `EIO_BACKEND=posix` (set by `test/dune`): repeated
io_uring creation can exhaust the per-user locked-memory cap and hide real
failures. The server keeps the default backend.

`scripts/test-local-ox.sh` is a historical alternate source-mirror workflow, not
the current gate workflow above. It predates the current Ox package layout and
the installed lint evidence; updating it is separate work.

## Run

Inn runs only as the `inn` systemd user service (see below). The service runs
`inn server`; start `inn server` by hand only for an isolated instance with
its own `--state-dir` and `--port`. There is no other way to start Inn, so a
stale copy cannot take the port from the service.

```sh
systemctl --user status inn
systemctl --user restart inn
inn status
```

`inn server` logs its listen address, its data directory, and its budget to
stderr at startup, so `journalctl --user -u inn` shows the configuration the
running process actually uses. On SIGTERM (and SIGINT), it stops accepting
connections, closes idle keep-alives, and gives in-flight requests up to five
seconds to finish before cancelling any that remain. It then closes the store
and exits 0, so a restart never leaves a hung process or an unclean WAL behind.
A server that cannot open its store, or whose serving loop fails, exits with a
non-zero status. The service restarts Inn after every exit
(`Restart=always`), including the SIGTERM that earlyoom sends.

`inn status` (`GET /status`) shows the identity of `/health` and the storage
section: the budget, the bytes in use, the segments with data, the start time
of the oldest data, and the count of failed ingest batches since the start with
the last error. It counts no rows, so it stays fast at any size. Inn owns `/ready` (and
`/api/ready`) rather than Ox’s plain-text readiness wrapper: it retains the
JSON identity and store check, and returns `503` when draining.

Default server address:

```text
http://127.0.0.1:27687
```

### systemd user service

The home-manager `shell-stack.nix` module already runs Inn as the `inn`
systemd user service, whose `ExecStart` is
`~/.cache/opam/5.4.0+ox/bin/inn server`. Install that binary and restart the
service in one step after any Inn change:

```sh
./scripts/install-inn-service.sh
```

The script builds Inn exactly as the gates do (`nix develop` over the shared
OxCaml switch) and installs only the `inn` executable into the shared
OxCaml switch at `$OPAMROOT/5.4.0+ox/bin/inn` (`OPAMROOT` defaults to
`~/.cache/opam`). It copies the binary to a temporary file in that same
directory and renames it into place, so the service never observes a half
written executable. It then restarts `inn.service` when the unit exists and
waits for `$INN_BASE_URL/health` (default `http://127.0.0.1:27687`) to answer.
It never runs `opam install`, `opam upgrade`, or `opam pin`, so the Ox
installed in the shared switch is left exactly as it is and pie and grip keep
building against it. Every change that lands on `master` is installed this way
(see `AGENTS.md`), so the service never runs older code than the repository.

The unit restarts Inn after every exit (`Restart=always` in the home-manager
module), except exit status 127, which means the binary is missing.

```sh
systemctl --user status inn
journalctl --user -u inn -n 20
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
GET /healthz
GET /ready
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
GET /metrics?service=<name>&name=<metric>&limit=<n>
GET /facets?type=<traces|logs>&field=<field>&key=<attribute-key>
GET /stats
GET /instructions
GET /docs
GET /docs/<name>
GET /endpoints
GET /openapi.json
```

The `/api/...` prefix is accepted as an alias for every route, including
ingest, docs, health, and discovery.

### Documentation and discovery

`GET /docs` lists the guides with name, title, and path; `GET /docs/{name}`
returns one guide as Markdown. The guides are Markdown files under
`docs/guides`, compiled into the binary at build time, so the service does not
depend on a checkout path at run time:

- `debug` — the agent debugging workflow: find the service, narrow the window,
  search traces and logs, open the trace tree, and use stats and facets.
- `effect` — point an Effect app's `OtlpTracer`, `OtlpLogger`, and
  `OtlpMetrics` layers at Inn with JSON serialization.
- `ox` — point an Ox app's `ox_otel` exporter at Inn.

An unknown name is a `404` whose body lists the available names.

`GET /openapi.json` is an OpenAPI 3.1 document generated from the same endpoint
declarations the router registers and the query parser validates against. Each
operation carries its parameters with type, default, allowed values, and
description, plus its response schemas, and every route also appears under its
`/api` alias. `GET /endpoints` is the same inventory in a compact JSON form
(method, path, group, summary, alias, filters, parameters, responses) with the
alias policy at the top level. An undeclared query parameter, a missing required
one, or a wrongly typed value is a `400` that names the parameter and lists the
supported ones.

`GET /instructions` is copy-paste OTLP setup text that also points at the
guides, `/endpoints`, and `/openapi.json`.

`GET /health` and `GET /healthz` report `version`, `startedAt` (ISO 8601
UTC), and `uptimeSeconds`, plus the pid and the configured state paths. `GET /ready` returns `200` with
`ready:true` while the store answers a query, and `503` with the store error
when it does not (or `503` with `store:"draining"` during shutdown). `inn --version`, the MCP `serverInfo.version`, `/health`,
and `info.version` in `/openapi.json` all report the same build version.

### Search filters and exact results

`operation` and `parentOperation` match a case-insensitive substring; a parent
must belong to the candidate span in the same trace. Log `body`/`contains` are also literal, case-insensitive substrings. This means `%`, `_`, and
backslashes are characters, not SQL wildcards. Repeated `attr.<key>` filters require
exact attribute values, while `attrContains.<key>` requires a literal substring
of the string form of an attribute value. Different filters combine with AND.
These attribute filters work on trace/span searches, log list/search, trace/log
stats, and trace/span correlated log lists.

`minDurationMs` (nonnegative number) applies to trace search/stats and span
search. `minSeverity` accepts
`trace`, `debug`, `info`, `warn`, `error`, or `fatal` on log
lists/search/stats. It compares OTLP severity numbers, falling back to text
when no number is present. Exact `severity` comparisons ignore case.
Trace `status` describes the entire trace: `error` means any span failed,
and `ok` means none failed. Span status remains span-specific.

Searches and aggregates run in SQL over
the complete selected window rather than sampling a result page. p95 duration
uses the exact nearest-rank percentile. No sampling or safety cap remains on
aggregate inputs: these responses are exact, not approximate. Trace service filters match any service
participating in the trace while the summary still displays its root service.
Trace facets describe root service/operation, whole-trace health, and distinct
traces for attribute values. By default `/services` includes span/log
services; add `signal=metrics` to include metrics-only services.

`/endpoints` lists supported `filters` per route and `/openapi.json`
publishes typed query parameters; `x-inn-query-prefixes` describes the
dynamic `attr.<key>` and `attrContains.<key>` keys. Both are rendered from
the endpoint declarations and both carry the response schemas.

### Trace tree

A trace is a tree, and Inn returns it as one. The trace detail
(`GET /traces/<id>`), the trace span list (`GET /traces/<id>/spans`), and the
span detail (`GET /spans/<id>`) share one order and one set of annotations:

- Spans come depth-first from the roots, siblings by start time.
- Every span carries `depth` (roots are 0) and `rootOperationName`; a span
  with a parent in the trace also carries `parentOperationName`.
- A span with no end time (or an end before its start) has `isRunning: true`
  and a null `durationMs`. The trace is running when any of its spans is.
- A span whose parent id is not in the trace is treated as a root at depth 0
  and carries a warning; the trace carries the same warning plus one when it
  has more than one root. Missing parents are never replaced with synthetic
  spans.
- The trace response adds `warnings`, and every trace summary carries
  `isRunning` and `warningCount`, so broken or in-flight traces are visible
  from the list.
- A trace that has spans is served even if its summary row is missing; only a
  trace with no span at all is a `404`.

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
inn search-traces --service api --operation users --status error --attr-contains route=/users --min-duration-ms 5
inn trace aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
inn trace-spans aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
inn trace-logs aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
inn search-spans --service api --operation GET --attr route=/users
inn span bbbbbbbbbbbbbbbb
inn span-logs bbbbbbbbbbbbbbbb
inn logs --service api --severity ERROR --contains timeout
inn search-logs --service api --body timeout --attr-contains route=/users --min-severity warn
inn trace-stats operation count --service api
inn log-stats severity --service api
inn facets traces attribute_keys --service api
inn metrics --service api --name requests.total
inn stats
inn endpoints
inn instructions
inn openapi
inn docs
inn docs debug
```

`inn trace` prints one indented line per span by default — the operation, the
service, the duration, and an error mark — followed by the trace warnings. Add
`--json` for the raw trace response.

Query commands that accept a time window or page through results use
`--lookback` and `--cursor`; the values are passed to the HTTP API unchanged:

```sh
inn logs --lookback 15m --limit 100
inn logs --lookback all --cursor eyJraW5kIjoibG9nIi...
inn traces --lookback 2h
inn trace-stats operation count --lookback all
```

`inn docs` prints the guide index as JSON; `inn docs NAME` prints one guide
as Markdown and exits 1 with the 404 body for an unknown name.

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
inventory, instructions, OpenAPI, and the guides
(`inn_docs_index`, and `inn_get_doc` with a `name` argument).

`inn_status` returns `GET /status` and `inn_stats` returns the row counts
with the same storage section.

List and search tools take `lookback` and `cursor`. `inn_stats`,
`inn_services`, `inn_trace_stats`, `inn_log_stats`, and `inn_facets` take
`lookback` only. The tool arguments become the same HTTP query parameters the CLI sends.

## Ox SQL

The store uses Ox SQL typed builders for schema, writes, reads, and
transactions. Raw SQL is used only where Ox SQL has no typed API, through
`Ox_sql.Pool.Raw`, the escape hatch `Ox_sql.mli` documents: the `page_count`
and `page_size` pragmas, `PRAGMA database_list`, `ATTACH` and `DETACH` with
the path and the schema name bound as values, and one literal script that
creates the reader's temporary views.
Known Ox SQL API gaps found while building Inn are recorded in
[.spec/OX_SQL_DOGFOODING.md](.spec/OX_SQL_DOGFOODING.md).
