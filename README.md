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
- `INN_RETENTION_HOURS`
- `INN_MAX_DB_SIZE_MB`

The caller's current working directory is never used to select the database,
daemon identity, lock path, or query target.

Retention is applied after ingest. `INN_RETENTION_HOURS` removes old telemetry
by signal timestamp. `INN_MAX_DB_SIZE_MB` is a size-pressure target: when the
database file is over the target, Inn deletes oldest trace/log/metric batches so
SQLite can reuse pages for future writes.

## Build

```sh
nix develop .#oxcaml -c dune build
nix develop .#oxcaml -c dune runtest
```

Run `inn-oxcaml-init` once inside the Nix shell to create the OxCaml opam
switch. It pins Eta packages from `git+https://github.com/ribelo/eta.git#master`
by default. For local Eta dogfooding:

```sh
ETA_OPAM_PIN=git+file:///home/ribelo/projects/ribelo/ocaml/Eta#master inn-oxcaml-init
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

Successful ingest responses:

```json
{"accepted":1}
```

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
trace/span/log search, trace/log stats, facets, metrics, endpoint inventory,
AI call search/stats/detail, instructions, and OpenAPI.

## Eta SQL

The store uses Eta SQL typed builders for schema, writes, reads, and
transactions. Raw SQL is not used in the application storage path. Known Eta SQL
API gaps found while building Inn are recorded in
[.spec/ETA_SQL_DOGFOODING.md](.spec/ETA_SQL_DOGFOODING.md).
