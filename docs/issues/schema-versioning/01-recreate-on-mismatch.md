---
status: completed
---

# Schema versioning: recreate on mismatch

## Problem Statement

Inn writes a `schema_version` row but never reads it. Schema creation is
`CREATE ... IF NOT EXISTS` only. Any schema change coming in the retention,
query, or ingest specs (new columns, new indexes, new tables) would silently not
apply to an existing database, or would fail at query time with confusing
errors. Inn's data is a short-lived debugging cache with a TTL measured in
hours, so writing and maintaining data migrations is not worth the cost.

## Solution

At open, Inn compares the stored schema version with the version it expects.
If the database is missing, empty, or has the expected version, Inn opens it
normally. If the version differs, or the database is not an Inn database, Inn
logs one clear warning. It then removes the old database files, including WAL
and SHM, and creates a fresh database with the current schema. Every
schema-changing spec bumps the version.

## User Stories

1. As a developer upgrading Inn, I want an incompatible old database replaced automatically at startup, so that the service starts after an upgrade without manual cleanup ^schm-s13e
2. As a developer, I want a warning in the service log that names the old version, the new version, and the database path when that happens, so that the loss of old telemetry is not a surprise ^schm-s52b
3. As a developer, I want a database with the current version opened as-is, so that restarts keep existing telemetry ^schm-ld81
4. As a developer, I want Inn to refuse to delete a file at the database path that is not an Inn database (for example, no Inn metadata table but other tables present), and to fail with a clear error instead, so that a misconfigured path cannot destroy unrelated data ^schm-xkk2
5. As an Inn contributor, I want one schema version constant that each schema change must bump, with a test that catches a schema change made without a bump, so that the recreate path is never skipped by accident ^schm-hnis

## Implementation Decisions

- The schema version is an integer constant owned by the store. The metadata
  table keeps storing it.
- Decision flow at open: file absent → create. File present with an Inn
  metadata table → compare versions; equal → open; different → warn, then
  delete the database, `-wal`, and `-shm` files, then create. File present
  with no Inn metadata table and no tables → create. File present with other
  tables but no Inn metadata table → error.
- The version check must run before any schema statement touches the file.
- To guard against a missing bump, a test compares a fingerprint of the
  compiled schema statements with a recorded value tied to the version. When a
  contributor changes the schema, they must update both.

## Testing Decisions

- Store-level tests use temporary directories: open a fresh database, ingest,
  reopen, and check that the data is kept (schm-ld81). Write a different
  version into the metadata table, reopen, and check that the data is gone and
  the store works (schm-s13e). A foreign SQLite file with an unrelated table
  gives an error and the file is untouched (schm-xkk2).
- The fingerprint test covers schm-hnis.
- The log warning is checked through the reporter, or at least exercised
  without failing (schm-s52b).

## Out of Scope

- Data-preserving migrations.

## Further Notes

- Depends on the Ox migration spec. The retention and query specs build on it.
