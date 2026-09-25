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

The same run compiles the Eta guide's exporter snippet
(`test/eta_guide_snippet.ml`) against that local Eta and fails when
`docs/guides/eta.md` no longer carries it verbatim, so the guide cannot drift
from the API it documents.

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

`inn server` logs its listen address, its database path, and its retention
settings to stderr at startup, so `journalctl --user -u inn` shows the
configuration the running process actually uses. On SIGTERM (and SIGINT),
it stops accepting connections, closes idle keep-alives, and gives in-flight
requests up to five seconds to finish before cancelling any that remain. It
then cancels and awaits the pruner, closes the store, and exits 0, so a restart
never leaves a hung process or an unclean WAL behind. Inn owns `/ready` (and
`/api/ready`) rather than Eta’s plain-text readiness wrapper: it retains the
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

The script builds Inn against the local Eta checkout, exactly as
`./scripts/test-local-eta.sh` does (set `ETA_PATH=/path/to/Eta` when the
checkout is elsewhere), and installs only the `inn` executable into the shared
OxCaml switch at `$OPAMROOT/5.4.0+ox/bin/inn` (`OPAMROOT` defaults to
`~/.cache/opam`). It copies the binary to a temporary file in that same
directory and renames it into place, so the service never observes a half
written executable. It then restarts `inn.service` when the unit exists and
waits for `$INN_BASE_URL/health` (default `http://127.0.0.1:27687`) to answer.
It never runs `opam install`, `opam upgrade`, or `opam pin`, so the Eta
installed in the shared switch is left exactly as it is and pie and grip keep
building against it.

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
GET /ai/calls?model=<model>&provider=<provider>&operation=<name>&finishReason=<text>&text=<text>
GET /ai/calls/<span-id>
GET /ai/stats?groupBy=<provider|model|functionId|sessionId|status|operation|finishReason>&agg=<count|avg_duration|p95_duration|total_input_tokens|total_output_tokens|total_tokens|error_rate>
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
  search traces and logs, open the trace tree, check AI calls, and use stats and
  facets.
- `effect` — point an Effect app's `OtlpTracer`, `OtlpLogger`, and
  `OtlpMetrics` layers at Inn with JSON serialization.
- `eta` — point an Eta app's `eta_otel` exporter at Inn.

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
UTC), and `uptimeSeconds`, plus the pid, the configured state paths, and the
managed daemon `instanceId` when one is set. `GET /ready` returns `200` with
`ready:true` while the store answers a query, and `503` with the store error
when it does not (or `503` with `store:"draining"` during shutdown). `inn --version`, the MCP `serverInfo.version`, `/health`,
and `info.version` in `/openapi.json` all report the same build version.

### Search filters and exact results

`operation` and `parentOperation` match a case-insensitive substring; a parent
must belong to the candidate span in the same trace. Log `body`/`contains` and AI
`text` are also literal, case-insensitive substrings. This means `%`, `_`, and
backslashes are characters, not SQL wildcards. Repeated `attr.<key>` filters require
exact attribute values, while `attrContains.<key>` requires a literal substring
of the string form of an attribute value. Different filters combine with AND.
These attribute filters work on trace/span searches, log list/search, trace/log
stats, and trace/span correlated log lists.

`minDurationMs` (nonnegative number) applies to trace search/stats, span
search, and AI call search/stats. `minSeverity` accepts
`trace`, `debug`, `info`, `warn`, `error`, or `fatal` on log
lists/search/stats. It compares OTLP severity numbers, falling back to text
when no number is present. Exact `severity` comparisons ignore case.
Trace `status` describes the entire trace: `error` means any span failed,
and `ok` means none failed. Span status remains span-specific.

Trace search `text` matches AI prompt/response content in a trace, even if
the matching AI span is not its root. Searches and aggregates run in SQL over
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

### AI calls

Inn classifies AI spans at ingest, and only AI calls are searchable:

- **AI call**: a span from the OpenTelemetry GenAI conventions
  (`gen_ai.operation.name` such as `chat` or `text_completion`, or
  `gen_ai.request.model`, or any other `gen_ai.*`/`ai.*` attribute) or a
  top-level Vercel AI SDK span.
- **Tool execution**: `gen_ai.operation.name=execute_tool` or a Vercel
  `ai.toolCall` span. Counted on its AI call, never listed as a call.
- **Nested provider span**: a Vercel `ai.*.do*` span whose parent is an AI
  call, such as `ai.generateText.doGenerate`. Excluded from the call list.
  Without its parent it is the only record of the call and is listed.

`GET /ai/calls` and `GET /ai/stats` read the AI call table written at ingest,
so they are exact over the window and never scan unrelated spans. Filters are
`service`, `traceId`, `sessionId`, `functionId`, `provider`, `model`,
`operation` (substring), `finishReason` (substring), `status`, `text`
(literal substring of the prompt, response, and tool content, ignoring case),
`minDurationMs`, `lookback`, and `cursor`. `GET /ai/calls/<span-id>` adds the
parsed prompt messages, the full response text, the tool calls (name, span id,
status, duration, arguments, result), the available tools, provider metadata,
timing (time to first chunk, time to finish, output tokens per second), the
correlated logs, and links to the parent trace. Asking for the detail of a tool
execution or a nested provider span is a `404` whose body names the kind and
points at the AI call parent.

An unsupported `groupBy` or `agg` is a `400` that lists the allowed values.

### AI call field provenance

Every AI call field is read from the OpenTelemetry GenAI semantic conventions
first and the Vercel AI SDK keys second. This table is the contract for what
instrumentation must emit.

| Field | GenAI convention | Vercel AI SDK |
|---|---|---|
| operation | `gen_ai.operation.name` | `ai.operationId` |
| provider | `gen_ai.provider.name`, `gen_ai.system` | `ai.model.provider` |
| model | `gen_ai.request.model`, `gen_ai.response.model` | `ai.model.id` |
| input tokens | `gen_ai.usage.input_tokens`, `gen_ai.usage.prompt_tokens` | `ai.usage.inputTokens`, `ai.usage.promptTokens` |
| output tokens | `gen_ai.usage.output_tokens`, `gen_ai.usage.completion_tokens` | `ai.usage.outputTokens`, `ai.usage.completionTokens` |
| total tokens | `gen_ai.usage.total_tokens` | `ai.usage.totalTokens` (otherwise input + output) |
| cached input tokens | `gen_ai.usage.cached_input_tokens`, `gen_ai.usage.cache_read.input_tokens` | `ai.usage.cachedInputTokens` |
| reasoning tokens | `gen_ai.usage.reasoning_tokens` | `ai.usage.reasoningTokens` |
| finish reason | `gen_ai.response.finish_reasons` | `ai.response.finishReason` |
| prompt | `gen_ai.input.messages`, `gen_ai.prompt` | `ai.prompt.messages`, `ai.prompt` |
| response | `gen_ai.output.messages`, `gen_ai.completion` | `ai.response.text`, `ai.response.messages` |
| available tools | `gen_ai.tool.definitions` | `ai.prompt.tools` |
| provider metadata | — | `ai.response.providerMetadata` |
| time to first chunk | `gen_ai.response.time_to_first_chunk` (seconds) | `ai.response.msToFirstChunk` (milliseconds) |
| time to finish | — | `ai.response.msToFinish` |
| output tokens per second | — | `ai.response.avgOutputTokensPerSecond` |
| tool call | `gen_ai.operation.name=execute_tool`, `gen_ai.tool.name`, `gen_ai.tool.call.arguments`, `gen_ai.tool.call.result` | `ai.toolCall`, `ai.toolCall.name`, `ai.toolCall.args`, `ai.toolCall.result`, `ai.response.toolCalls` |
| session id | `gen_ai.session.id` | `ai.telemetry.metadata.sessionId` |
| function id | `gen_ai.function.id` | `ai.telemetry.functionId` |
| user id | `gen_ai.user.id` | `ai.telemetry.metadata.userId` |

Session and function ids also fall back to `session.id`, `ai.session.id`,
`function.id`, and `ai.function.id`; a user id also falls back to
`ai.user.id` and `user.id`. Content values that are JSON strings are parsed
(the prompt as messages, the response as text) and kept raw otherwise.

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
inn search-traces --service api --operation users --status error --attr-contains route=/users --min-duration-ms 5 --text checkout
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
inn ai-calls --model gpt-test --provider openai --finish-reason stop
inn ai-call bbbbbbbbbbbbbbbb
inn ai-stats finishReason count --service api
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
`--json` for the raw trace response. `inn ai-calls` and `inn ai-stats` accept
`--finish-reason` next to the other AI filters.

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
inventory, AI call search/stats/detail, instructions, OpenAPI, and the guides
(`inn_docs_index`, and `inn_get_doc` with a `name` argument).

`inn_stats` returns the store row counts and the retention section, including
the last prune report, so the pruner is observable without reading server
logs.

List and search tools take `lookback` and `cursor`. `inn_stats`,
`inn_services`, `inn_trace_stats`, `inn_log_stats`, `inn_facets`, and
`inn_ai_stats` take `lookback` only. The AI tools take the same
`operation`, `finishReason`, `text`, and `minDurationMs` filters the HTTP API
does, and `inn_ai_stats` groups by every field the API accepts. The tool
arguments become the same HTTP query parameters the CLI sends.

## Eta SQL

The store uses Eta SQL typed builders for schema, writes, reads, and
transactions. Raw SQL is not used in the application storage path. The one
exception is SQLite pragmas, which have no typed API: `page_count`,
`freelist_count`, `page_size`, `auto_vacuum`, and `incremental_vacuum` all run
through one store helper that uses `Eta_sql.Pool.Raw`, the escape hatch
`Eta_sql.mli` documents for pragmas. AI token totals are summed over the
nullable token columns with `Q.Projection.sum_int_nullable`: NULL inputs are
ignored and a group with no reported tokens decodes as `None`, so the columns
keep their `Q.nullable` declaration and no alias is needed (Eta `d64f1e88`).
Known Eta SQL API gaps found while building Inn are recorded in
[.spec/ETA_SQL_DOGFOODING.md](.spec/ETA_SQL_DOGFOODING.md).
