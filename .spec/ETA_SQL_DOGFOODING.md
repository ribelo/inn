# Eta SQL Dogfooding Notes

Inn uses Eta SQL's typed builders for application storage:

- `Table.Make` for table and column declarations.
- `Eta_schema.create_table` and `Eta_schema.create_index` for schema creation.
- `Insert`, `Update`, `Delete`, and `Select` builders for writes and reads.
- `Pool.Typed` and `Pool.with_transaction` for execution.

Raw SQL is not part of the application store path. SQLite pragmas are supplied
through `Eta_sql.Sqlite.config`.

## API Gaps Found

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
