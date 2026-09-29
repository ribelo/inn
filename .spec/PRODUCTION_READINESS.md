# Inn Production Readiness Checklist

Inn is production-ready for public v1.0 only when every item below is true and
verified. TUI and web UI parity with Motel are intentionally out of scope.

## Product Contract

- One user-level database is used by default, independent of the current working
  directory.
- The default state directory is `${XDG_STATE_HOME:-~/.local/state}/inn`.
- CLI read commands query the configured Inn server by default.
- Direct database access is reserved for explicit offline/admin/debug flows.
- OTLP traces, logs, and metrics are accepted as first-class signals.
- Ox SQL typed APIs are used for application database access. Raw SQL is not
  used in Inn application or test code.
- Ox HTTP is used for the local API server and CLI HTTP client.

## Required Non-TUI Motel Parity

- Server lifecycle: `daemon`, `server`, `status`, `stop`, `restart`.
- Service and trace reads: `services`, `traces`, `trace`, `span`,
  `trace-spans`.
- Span search: service, operation, parent operation, status, attributes, limit.
- Trace search: service, operation, status, attributes, limit.
- Trace stats: grouping and aggregation for trace counts/durations/errors.
- Log reads and search: `logs`, `search-logs`, `trace-logs`, `span-logs`,
  `log-stats`.
- Facets for trace/log service, operation/status/severity, attribute keys, and
  attribute values.
- AI call search, detail, and stats derived from spans with AI-related
  OpenTelemetry attributes.
- Machine-readable endpoint inventory and agent instructions.
- HTTP API parity for every CLI query command under both canonical and `/api`
  paths.
- MCP query surface for agent use.

## Operational Gates

- Runtime files live under the user-level state directory and never under the
  caller's current directory.
- Daemon status validates the configured global server, not a project-local
  workdir.
- Server shutdown closes the store cleanly.
- Retention runs after ingest and supports both age and size pressure.
- Database initialization and schema upgrades are repeatable.
- Errors are JSON, stable, and script-friendly.
- CLI exits non-zero for failed HTTP/store operations.
- Documentation covers build, run, configuration, API, CLI, and agent usage.
- `flake.nix` provides the OxCaml/Ox development environment.

## Verification Gates

- `nix develop .#oxcaml -c dune build`
- `nix develop .#oxcaml -c dune runtest test`
- Raw-SQL scan must show no application/test raw SQL access.
- Smoke test must ingest traces, logs, and metrics through HTTP and query them
  through the CLI from a different directory.
- Daemon smoke test must start, report healthy status, answer queries, stop, and
  leave no stale process.
- Self-audit must be written to `.spec/SELF_AUDIT.md` before the goal can be
  marked complete.
