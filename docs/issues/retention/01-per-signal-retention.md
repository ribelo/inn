---
status: ready-for-agent
---

# Per-signal retention with background pruning

## Problem Statement

Inn runs all the time as a systemd user service and collects telemetry from
every local app. That telemetry is only useful for a short time: logs for a few
hours, maybe a day or two. Traces and metrics are useful for a day or two.
Today the store has a single `INN_RETENTION_HOURS` value (default 7 days) for
every signal. Pruning runs only inside ingest transactions, so a server that
receives nothing never prunes. Each prune also loads every expired row id into
memory and deletes them with one `IN (...)` list. After a burst, that list can
exceed SQLite's bound-variable limit, and then every ingest fails until the
backlog is cleared by hand. The size cap compares the database *file size* to
`INN_MAX_DB_SIZE_MB`. SQLite never shrinks the file after deletes, so once the
file has grown past the cap, every ingest deletes the oldest 100 traces, 500
logs, and 500 metric points forever, even when the database is nearly empty.
Timestamps come from the client, so a client that sends a zero or skewed
timestamp gets its data deleted immediately, or never.

## Solution

Each signal gets its own time-to-live. The defaults are logs 24 hours, traces
48 hours, and metrics 48 hours. The TTL counts from when Inn *received* the
data, not from the client's timestamp. A background pruner runs once at
startup and then on a fixed interval, independent of ingest. It deletes expired
data in small bounded batches, so it never holds the write lock for long and
never hits variable limits. The size cap measures live data (pages in use), not
file size. It removes the oldest data only until live data is under the cap,
and it lets SQLite reuse or release the freed space. Operators can see the
active retention settings and the last prune result.

## User Stories

1. As a developer running Inn as a systemd service, I want logs kept for 24 hours by default, so that noisy logs do not pile up into gigabytes ^ret-mvsc
2. As a developer, I want traces kept for 48 hours by default, so that I can still debug yesterday's run ^ret-57b8
3. As a developer, I want metrics kept for 48 hours by default, so that recent metric history is available without unbounded growth ^ret-ggir
4. As a developer, I want to override each signal's TTL with its own environment variable and CLI flag, so that I can keep one signal longer while debugging ^ret-6pix
5. As a developer, I want the old single `INN_RETENTION_HOURS` setting to fail at startup with a message that names the new per-signal settings, so that a stale config is noticed instead of silently ignored ^ret-f1oo
6. As a developer, I want expired data pruned even when no new telemetry arrives, so that an idle machine does not keep old data forever ^ret-sj15
7. As a developer, I want pruning to happen once at server startup, so that data that expired while the service was stopped goes away promptly ^ret-sbgj
8. As a developer, I want ingest requests to never run pruning work, so that exporters see low, stable ingest latency ^ret-rkrf
9. As a developer, I want pruning to delete in bounded batches, so that a large backlog of expired data never causes a failed statement or a long write lock that stalls ingest ^ret-xbij
10. As a developer, I want retention measured from the time Inn received the data, so that a client with a zero, skewed, or future timestamp cannot cause immediate deletion or permanent retention ^ret-ovry
11. As a developer, I want a trace kept as long as any of its spans was received within the trace TTL, so that a long-running trace is not partly deleted while it is still receiving spans ^ret-4hhb
12. As a developer, I want attribute index rows removed together with the span, log, or metric point they belong to, so that the database has no orphaned index rows ^ret-hy7e
13. As a developer, I want the size cap to act on the amount of live data, not on the file size, so that Inn does not keep deleting data after the file stopped shrinking ^ret-zjzs
14. As a developer, I want size-cap pruning to remove only the oldest data, and only until live data is below the cap, so that it never deletes more than needed ^ret-bizv
15. As a developer, I want the pruning interval configurable, with a sensible default of a few minutes, so that I can tune pruning cost against how quickly storage is freed ^ret-qd9f
16. As a developer, I want the active TTLs, the size cap, and the time and row counts of the last prune visible through the stats API, CLI, and MCP, so that I can check what the service is doing without reading its logs ^ret-eeb1

## Implementation Decisions

- **Configuration.** The configuration record replaces the single retention
  value with three positive-integer hour values:
  `INN_TRACES_RETENTION_HOURS` (default 48), `INN_LOGS_RETENTION_HOURS`
  (default 24), and `INN_METRICS_RETENTION_HOURS` (default 48). Add a prune
  interval, `INN_PRUNE_INTERVAL_SECONDS` (default 300). `INN_MAX_DB_SIZE_MB`
  keeps its current default. Each value also gets a matching server CLI flag,
  following the existing override pattern. If `INN_RETENTION_HOURS` is set,
  configuration resolution returns an error that names the replacement
  variables.
- **Retention clock.** Retention uses ingestion time. Spans, logs, and metric
  points already record `ingested_at_ms`. Trace expiry uses the trace
  summary's last-update time, so an entire trace is deleted only when none of
  its spans arrived inside the TTL. This resolves ret-4hhb: it deletes whole
  traces, never partial traces.
- **Pruner placement.** The pruner is a server-lifetime fiber started by the
  server run function. It runs immediately, then sleeps for the interval
  between runs, using the Eta and Eio clock so tests can drive it. Remove
  retention from the three ingest transactions entirely. The pruner is
  cancelled with the server switch. A failed prune pass is logged and retried
  on the next interval; it must not crash the server.
- **Store interface.** The store exposes a single deep operation, a prune call
  that takes the current time and returns a prune report (rows deleted per
  signal and whether the size cap triggered). The store also exposes the last
  report for stats. The pruner fiber is a thin loop around that operation.
- **Batching.** Each batch deletes at most a fixed number of owner rows (on the
  order of 1,000) together with their attribute rows, inside one short
  transaction. Batches repeat until nothing expired remains. Id lists sent as
  bound parameters are capped at the batch size. A subquery-based delete is
  preferred where Eta SQL can express it.
- **Size cap.** Live bytes are computed as (page count minus freelist count)
  times page size. Eta SQL has no typed pragma API. Its sanctioned escape hatch
  for pragmas is Pool.Raw. Read and run pragmas (page_count, freelist_count,
  page_size, auto_vacuum, incremental_vacuum) through one small, clearly named
  store helper that uses it. Use no raw SQL anywhere else. Under size pressure,
  delete the oldest data first by ingestion time, across all signals, in
  batches, until live bytes are under the cap. Create new databases with
  auto_vacuum=INCREMENTAL. End each prune pass that deleted rows with an
  incremental vacuum, so the file shrinks. Record the missing typed pragma API
  in the dogfooding notes.
- **Indexes.** Add ingestion-time indexes for logs, metric points, and trace
  summaries, so pruning is an index range scan. The schema versioning spec
  covers the schema change.
- **Stats.** The stats response gains a retention section: the three TTLs in
  hours, the prune interval, the size cap, live bytes, and the last prune
  report.

## Testing Decisions

- Test through the store's public prune operation with an injected "now",
  plus ingest and query calls. Do not reach into internal tables except
  through the public query functions.
- Per-signal TTL: ingest one item of each signal with backdated ingestion
  time (via injected time), prune, and check that each signal expires
  independently (ret-mvsc, ret-57b8, ret-ggir, ret-ovry).
- Client timestamps far in the past or future do not affect expiry (ret-ovry).
- A trace with one old span and one fresh span survives. A trace whose spans
  are all old is deleted, including its summary and attribute rows. After
  that, an attribute-filtered search does not return the deleted trace
  (ret-4hhb, ret-hy7e).
- A backlog larger than several batches (for example 5,000 expired logs) is
  fully pruned without error (ret-xbij).
- Ingest does not prune: expired data stays until the prune operation runs
  (ret-rkrf).
- Configuration tests cover defaults, overrides, invalid values, and the
  rejection of `INN_RETENTION_HOURS` (ret-6pix, ret-f1oo, ret-qd9f).
- Size cap: with a tiny cap, pruning stops once live bytes are under the cap.
  A second prune with no new data deletes nothing (ret-zjzs, ret-bizv).
- The stats API includes the retention section after a prune (ret-eeb1).
- Server-level test: the pruner fiber runs at startup, using an Eio mock
  clock or a short interval (ret-sj15, ret-sbgj).
- Prior art: the existing store and config tests in Inn's Alcotest suite.

## Out of Scope

- Per-service or per-attribute retention rules.
- Archiving or exporting data before deletion.
- Changes to the NixOS or home-manager unit. The defaults live in Inn, so the
  unit needs no retention settings.

## Further Notes

- Depends on the Eta migration spec and on the schema versioning spec.
- Because the TTL uses ingestion time, the stored client timestamps stay
  purely descriptive.
