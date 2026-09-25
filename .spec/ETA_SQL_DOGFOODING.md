# Eta SQL Dogfooding Notes

Inn uses Eta SQL's typed builders for application storage:

- `Table.Make` for table and column declarations.
- `Eta_schema.create_table` and `Eta_schema.create_index` for schema creation.
- `Insert`, `Update`, `Delete`, and `Select` builders for writes and reads.
- `Pool.Typed` and `Pool.with_transaction` for execution.

Raw SQL is not part of the application store path, with one exception: SQLite
pragmas. `Eta_sql.mli` documents `Pool.Raw` as the escape hatch for
"migrations, pragmas, diagnostics, and backend-specific SQL", and every pragma
Inn runs goes through one helper in `lib/store.ml` built on it. Pragmas that
`Eta_sql.Sqlite.config` covers (`journal_mode`, `synchronous`,
`foreign_keys`, `cache_size`) are still supplied through the config.

## Resolved Gaps

Eta commit `5a24b687` adds `Eta_sql.Column.any`. `create_index`,
`on_conflict_do_nothing`, and `on_conflict_update ~set` now accept mixed-type
column lists, which resolves the two heterogeneous-list gaps below. Inn wraps its
columns with `Q.Column.any`. The query accuracy spec adopts composite indexes and
single-statement upserts.


None of the gaps below is resolved by local Eta master at `d38804d0` (checked
against its SQL public interfaces). Inn therefore keeps its typed builders and
the workarounds described here.

## Remaining Gaps

### Spin on a File That Is Not a SQLite Database

Found while adding the schema-version check. A pool on a file that is not a
SQLite database spins at 100% CPU inside `Pool.Typed.select` instead of
returning an error when the pool's `Sqlite.config.synchronous` is `None`:

{[
(* Eta master, with the text "not a database" written to /tmp/bad.sqlite. *)
let config =
  { (Eta_sql.Sqlite.default_config "/tmp/bad.sqlite") with
    synchronous = None;
    mode = Eta_sql.Sqlite.Read_write }
in
let query =
  Eta_sql.Select.compile
    Eta_sql.Select.(from Meta.table (Eta_sql.Projection.one Meta.key))
in
let* pool = Eta_sql.Pool.create ~default_timeout:(Eta.Duration.ms 5000) config in
let* _rows = Eta_sql.Pool.Typed.select pool query in
let* () = Eta_sql.Pool.shutdown pool in
Eta.Effect.unit
]}

The program never returns; the 5 s default operation timeout does not fire. With
`synchronous` set to `Some Normal` the same program fails cleanly at
connection open, so the failure is only observable when connection setup runs no
pragma that touches the file. Inn does not rely on the spinning path: the store checks the
SQLite file header before it opens any connection, and the inspection pool keeps
the store's `synchronous` setting. Reported here so it is not lost.

### Typed Pragma API

Retention needs `page_count`, `freelist_count`, and `page_size` to size live
data, `auto_vacuum` to create new databases in incremental mode, and
`incremental_vacuum` to return freed pages to the filesystem. `Eta_sql.Sqlite.config`
exposes no `auto_vacuum` field, and the DSL has no typed pragma builder, so Inn
routes all five through one `Pool.Raw` helper. Two details make the raw route
awkward: `auto_vacuum` only takes effect on an empty database and before any
connection switches it to WAL, and `PRAGMA incremental_vacuum` steps once per
freed page, so `Pool.Raw.execute` (which expects one step to `DONE`) rejects it
and the helper has to fold the statement instead. A typed pragma API with a
documented "must run before schema creation" ordering would remove the raw
escape hatch from the store.

### Heterogeneous Composite Indexes

`Eta_schema.create_index` accepts a regular OCaml list of columns. That makes
the list homogeneous at the column value type level, so mixed-type indexes such
as `(service_name TEXT, timestamp_ms INTEGER)` cannot be expressed.

Inn currently uses typed single-column indexes instead. For production query
planning, Eta SQL should support heterogeneous column lists for schema indexes.

### Heterogeneous Conflict Update Sets

`Insert.on_conflict_update` accepts a regular OCaml list for `set`, which also
requires all updated columns to have the same value type. Mixed-field upserts
such as span or trace summary updates cannot be expressed directly.

Inn currently emits a typed `INSERT ... ON CONFLICT DO NOTHING` followed by a
typed `UPDATE ... SET ... WHERE ...` in the same transaction. Eta SQL should
support heterogeneous update-set lists for conflict updates.

### Transaction Body Error Type

`Pool.with_transaction` requires the transaction body to use `Q.Pool.error`.
That works for Inn's ingest/retention path, but it means application-level
typed errors cannot be raised directly inside a transaction body.

Inn keeps transaction internals pool-error-only and widens errors at the public
store boundary. Eta SQL could consider a transaction helper whose body error can
be a supertype of pool errors.
