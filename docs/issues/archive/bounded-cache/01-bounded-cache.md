---
status: done
category: enhancement
---

# Inn is a bounded cache that cannot fail silently

## Problem Statement

On 2026-10-10 Inn stopped working for hours. Five faults added up:

1. The background pruner stopped on 2026-10-08 with an exception, at every
   restart too. The server still reported healthy. For two days no retention
   and no size cap ran, and the database grew to 8 GB.
2. One Exergy span type carried a 7.7 KB attribute on 250,000 spans. Inn kept
   every attribute three times: in the JSON column, in the attribute table,
   and in the key/value index.
3. One Exergy trace grew to 42,000 spans. At every ingest batch, Inn read the
   complete trace again, decoded every span and updated every span row. Memory
   grew to 96 GB and earlyoom stopped the process.
4. earlyoom sends SIGTERM. Inn then exits with status 0, and the unit restarts
   only on failure, so Inn stayed down.
5. An agent started `inn daemon` from a stale binary on `PATH` (a June
   build in `~/.local/bin`). That binary did not match the database schema,
   so every query returned HTTP 500. The service also ran a binary ten days
   older than the code.

The agents use Inn for one thing: to look at the run that they just did. A scan
of 924 `inn` commands in agent sessions found searches by service, by a
`debug.session` attribute, by operation and by status, with limits of 1 to 5,
`inn trace <id>`, and status checks. `--lookback all` occurred 4 times. No
agent used the AI-call commands.

## Solution

Inn is a cache of recent telemetry with a fixed size. The size limit is a
property of how Inn writes data, not a job that can stop:

- Data goes into segment files. When the newest segment is full, Inn starts a
  new one. When there are more segments than the budget allows, Inn deletes the
  oldest segment file. There is no pruner, no time-to-live and no vacuum.
- Inn cuts oversized data when it arrives and marks it.
- A trace summary is updated from the new spans of a batch, never by reading
  and decoding the complete trace.
- The systemd user service is the only way to run the server. The service
  restarts after every exit.
- A failure of any part of the server stops the process, so systemd restarts
  it. `inn status` shows the real state of the store.
- Every change that lands in this repository is installed into the service and
  checked.

## User Stories

1. As an agent, I want the newest telemetry always accepted, and the oldest dropped when the budget is full, so that the run I just did is always visible ^bcache-r1ng
2. As the owner, I want the store to stay inside `INN_MAX_DB_SIZE_MB` (default 1024) with no other retention setting, so that Inn never fills the disk ^bcache-c4p7
3. As the owner, I want old data removed by deleting a whole file, so that removal is quick and cannot stop half way ^bcache-f1le
4. As the owner, I want attribute values over 1 KB, log bodies and status messages over 8 KB cut at ingest and the record marked with `inn.truncated = true`, so that one program cannot fill Inn with large values ^bcache-t8nc
5. As the owner, I want at most 5,000 spans of one trace in a segment, with the number of dropped spans in the trace summary, so that one runaway trace cannot flood Inn ^bcache-s5kc
6. As the owner, I want each attribute stored once in its record, with only short values (up to 256 bytes) in the search index, so that large values do not multiply on disk ^bcache-a1x1
7. As the owner, I want ingest memory to depend on the batch, not on the length of the trace, so that a long trace cannot exhaust memory ^bcache-m3m0
8. As the owner, I want the AI-call analysis removed (`ai-calls`, `ai-call`, `ai-stats`, `/ai/*`, the MCP tools and the AI text search), because no agent uses it and it was the most expensive part of ingest ^bcache-n0ai
9. As the owner, I want `inn daemon`, `inn stop` and `inn restart` removed, and the CLI to tell me to run `systemctl --user restart inn` when Inn is down, so that a stale copy can never compete with the service ^bcache-d0nd
10. As the owner, I want the service to restart after every exit, including SIGTERM from earlyoom, so that Inn comes back without me ^bcache-r5rt
11. As the owner, I want the server process to exit with a failure when one of its parts fails, so that no part can stop while the server reports healthy ^bcache-x1t0
12. As an agent, I want `inn status` and `GET /stats` to show the budget, the bytes in use, the segments, the time of the oldest data, and the count of failed ingest batches with the last error, so that I can see what the store does ^bcache-s7at
13. As the owner, I want every landed change installed into the service and health-checked, so that the service never runs old code ^bcache-i9st

## Implementation Decisions

- **Segments.** A segment is an SQLite file `<state>/segments/<sequence>.sqlite`
  with the full schema (spans, logs, metric points, short-value attribute
  indexes, trace parts, trace services, `inn_meta`). The budget is divided into
  8 segments: a segment is full at `INN_MAX_DB_SIZE_MB / 8`. When a write makes
  the newest segment full, the next write goes to a new segment; when more than
  8 segments exist, the oldest file and its WAL files are deleted.
- **Segments rotate by size, not by clock hour.** The design discussion said
  "hourly slices". Without an age limit, hourly files would grow to hundreds
  of files during a quiet week. Rotation by size keeps the file count at 8 and
  keeps the rule "the oldest data goes first".
- **Writer and reader.** One connection writes to the newest segment. One
  connection reads: it attaches every segment and defines temporary views with
  the table names that the queries use (`spans`, `logs`, `trace_summaries`
  and the others). After a rotation the reader attaches the new set of
  segments before its next query. The query code does not know about
  segments.
- **Trace parts.** Each segment keeps one row per trace for the spans in that
  segment (count, errors, running spans, first start, last end, root span,
  missing parents, dropped spans). After each batch, Inn computes the row from
  a light projection of that trace's spans in the newest segment (ids, parent,
  times, status, names), bounded by the 5,000-span cap. The `trace_summaries`
  view combines the parts of all segments. The trace detail always computes
  its summary from the complete span tree. In the list, the warning count
  counts missing parents and multiple roots, not parent cycles.
- **Body limit.** The HTTP server accepts request bodies up to 32 MiB, the
  limit of the body extractor. Ox's default of 1 MiB reset the connections of
  exporter batches with large attributes before Inn could cut them.
- **Attributes.** The record keeps all attributes as JSON. The attribute index
  tables keep a row only when the string value is at most 256 bytes. Attribute
  filters and facets match indexed values only.
- **Schema versions.** A segment whose `inn_meta` version differs from the
  current version, or which is not readable, is deleted at startup with a
  message. The old single database file is not migrated.
- **Configuration.** `INN_MAX_DB_SIZE_MB` stays. `INN_DB_PATH`,
  `INN_TRACES_RETENTION_HOURS`, `INN_LOGS_RETENTION_HOURS`,
  `INN_METRICS_RETENTION_HOURS`, `INN_PRUNE_INTERVAL_SECONDS` and
  `INN_RETENTION_HOURS` are refused at startup with a message, so that a
  setting is never ignored silently.
- **Failure policy.** An ingest that fails returns an error to the exporter,
  increments the failure count and records the last error. A failed write does
  not stop the server. An exception from a server fiber ends the process with
  a non-zero status.
- **Service unit.** `Restart=always` in the home-manager unit in
  `~/nixos-config`.
- **Landing rule.** `AGENTS.md` requires `scripts/install-inn-service.sh` and
  a health check after each landed change.

## Testing Decisions

- The existing suite runs through the store and the HTTP handler.
  Retention tests are replaced by segment tests: rotation at the segment size,
  deletion of the oldest segment, a query that spans two segments, and a trace
  whose spans are in two segments.
- Truncation and the span cap are checked through ingest and query.
- A load run outside the suite sends one long trace with large attributes to an
  isolated Inn and records the resident memory and the size on disk.

## Out of Scope

- Changes to Exergy. Its agent receives a separate instruction.
- A migration of the old database file.
