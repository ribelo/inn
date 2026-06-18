# Inn Objective

## Goal

Build `inn`, an OxCaml/Eta local telemetry collector and query tool that
replaces the useful parts of `motel` without current-working-directory-coupled
behavior.

`inn` should let any local process emit telemetry once and let any shell query
that telemetry from any directory.

## Core Decision

Design `inn` around one user-level telemetry store and one server-owned query
surface, rather than per-project daemon/database state.

The server is the authority for:

- schema version and migrations;
- write coordination;
- retention policy;
- query semantics;
- index maintenance.

CLI queries should go through the running `inn` server by default. Direct
SQLite access is reserved for explicit offline, admin, or debugging commands.

## Storage Contract

Default state directory:

```text
${XDG_STATE_HOME:-~/.local/state}/inn
```

Default database path:

```text
${XDG_STATE_HOME:-~/.local/state}/inn/telemetry.sqlite
```

Overrides:

- `INN_STATE_DIR` changes the default state directory.
- `INN_DB_PATH` points at an explicit database path.

No database or daemon identity may be derived from the caller's current
working directory.

## API And CLI Contract

A clean new CLI and API are acceptable.

`motel` compatibility is not a hard constraint. Avoid needless incompatibility
when an existing shape is good, but do not preserve behavior that creates
cwd-coupled state, confusing fallbacks, or split query semantics.

## Anti-Goals

- No UI, TUI, or web UI.
- No cwd-derived database identity.
- No silent fallback to cwd-local state.
- No split where some commands query the server and others silently open a
  different SQLite database.
- No compatibility shim for `motel` behavior that conflicts with the storage
  and query contracts above.

## Evidence From Motel

Installed `motel` currently mixes a fixed HTTP server port with cwd-derived
daemon and database identity.

Observed behavior:

- From the daemon workdir, `motel services` works.
- From another directory, `motel status` can see the live daemon but marks it
  unusable because the workdir differs.
- From another directory, `motel services` tries to open a cwd-local
  `.motel-data/telemetry.sqlite` and can fail with `SQLITE_CANTOPEN`.
- Direct HTTP queries to the running daemon are cwd-independent.

`inn` should preserve the good property, cwd-independent server queries, and
discard the broken property, cwd-derived daemon/database selection.

## Eta Direction

Use Eta as the implementation substrate.

Relevant local Eta surfaces:

- `eta_http_eio` for the local HTTP server.
- `eta_sql.Table`, `Eta_schema`, `Insert`, `Select`, `Update`, `Delete`, and
  `Pool.Typed` for SQLite access.
- `eta_sql.Sqlite` only for connection configuration and backend-specific
  settings exposed through typed/configured APIs.
- `eta_otel` as the existing OTLP/HTTP JSON emitter surface that `inn` should
  ingest from.

SQLite is the natural durable store for spans and logs. LadybugDB is not the
default storage choice for OTLP telemetry because its graph/Cypher model does
not match the primary ingest/query workload as directly as SQLite tables and
indexes.

Application storage code should not use raw SQL strings when Eta SQL can express
the operation. If Eta SQL cannot express a production-relevant operation, record
the gap so Eta can be improved.

Metrics are stored and queried as a first-class signal alongside traces and
logs.

## Review Checkpoints

Work should proceed through reviewable design and implementation checkpoints,
but these checkpoints are not product-version slices. The target is one
complete design, not a deliberately incomplete first version.

Each checkpoint should produce an inspectable artifact, such as:

- architecture contract;
- schema and retention design;
- CLI/API contract;
- ingestion implementation;
- query implementation;
- verification evidence.
