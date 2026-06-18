# Inn Self-Audit

Date: 2026-06-18

## Verdict

Inn satisfies the v1.0 production-readiness objective defined in
`.spec/PRODUCTION_READINESS.md`.

No known blocker remains for publishing the current app as the first public
version.

## Product Contract

- Pass: default state and database are user-level:
  `${XDG_STATE_HOME:-~/.local/state}/inn` and `telemetry.sqlite`.
- Pass: daemon pid, registry, and log files live in the state directory.
- Pass: CLI query commands use the configured HTTP server and do not open
  cwd-local databases.
- Pass: current working directory is not part of database selection, daemon
  identity, registry path, or query target.
- Pass: traces, logs, and metrics ingest through OTLP/HTTP JSON.
- Pass: query API covers services, traces, spans, logs, metrics, stats, facets,
  endpoint inventory, instructions, OpenAPI, and AI call views.
- Pass: MCP stdio exposes read-only query tools over the configured HTTP API.

## Motel Parity

TUI and web UI remain intentionally out of scope.

Implemented non-TUI surfaces:

- `daemon`, `server`, `status`, `health`, `stop`, `restart`.
- `services`, `traces`, `trace`, `trace-spans`, `span`, `span-logs`.
- `search-spans`, `search-traces`, `trace-stats`.
- `logs`, `search-logs`, `log-stats`, `trace-logs`.
- `facets`.
- `metrics`.
- `ai-calls`, `ai-call`, `ai-stats`.
- `instructions`, `endpoints`, `openapi`.
- `mcp`.

## Eta SQL Dogfooding

- Pass: application storage uses Eta SQL typed schema/query builders.
- Pass: raw SQL is not used for application/test storage access.
- Pass: Eta SQL API gaps discovered during implementation are recorded in
  `.spec/ETA_SQL_DOGFOODING.md`.

Known Eta SQL gaps are not release blockers because Inn uses typed
workarounds:

- heterogeneous composite indexes;
- heterogeneous `ON CONFLICT DO UPDATE` set lists;
- transaction body error-type widening.

## Verification Evidence

Commands run successfully:

```sh
nix develop .#oxcaml -c dune build
nix develop .#oxcaml -c dune runtest test
nix flake show --no-write-lock-file
```

Raw-SQL scan:

```sh
rg -n "Pool\\.Raw|execute_script|prepare|SELECT |INSERT |DELETE |CREATE TABLE|CREATE INDEX|PRAGMA|with_stmt|raw SQL|Sqlite\\." lib test bin .spec README.md
```

Result: only documentation references and `lib/store.ml` SQLite backend
configuration were reported.

Daemon smoke:

- Started a managed daemon with a temp state dir and non-default port.
- Queried `status` from `/tmp`.
- Stopped the daemon and verified it reported not running.

End-to-end smoke:

- Started a managed daemon with long retention for deterministic fixture
  timestamps.
- Ingested trace, log, and metric OTLP JSON through HTTP.
- Queried from `/tmp` with `services`, `search-traces`, `span`,
  `search-logs`, `trace-stats`, `log-stats`, `facets`, and `metrics`.
- Ran an MCP `tools/call` smoke for `inn_services`.
- Stopped the daemon.

Unit/integration tests cover:

- config defaults and env overrides;
- OTLP trace/log/metric decoding;
- typed store ingest/query/search/stats/facets;
- server handler ingest/query/discovery;
- AI call search/detail/stats.

## Residual Risks

- AI call detection is convention-based over `ai.*` and `gen_ai.*`
  OpenTelemetry attributes plus common operation names. This is appropriate for
  a generic local collector, but adding SDK-specific normalizers may improve
  summaries later.
- MCP currently exposes tools only. It does not expose prompts or resources.
  This is sufficient for agent query parity and keeps the server small.
- Size-pressure retention deletes bounded oldest batches once per ingest when
  the file is over the target. SQLite reuses freed pages; explicit file
  shrinking still requires an offline vacuum chosen by the operator.

These risks are documented behavior, not release blockers.
