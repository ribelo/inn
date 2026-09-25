# Inn issues

Specs for the Eta migration and motel-parity work, in implementation order.
Each spec's frontmatter carries its status. Story IDs are cited by tests.

| Order | Spec | Status |
|---|---|---|
| 1 | [eta-migration](eta-migration/01-build-on-latest-eta.md) | done (879fe3a, 7a04a97) |
| 2 | [mcp-stdio](mcp-stdio/01-standard-stdio-transport.md) | done (dd2f3b9) |
| 3 | [schema-versioning](schema-versioning/01-recreate-on-mismatch.md) | done (4faa31e) |
| 4 | [retention](retention/01-per-signal-retention.md) | done (4faa31e) |
| 5 | [otlp-ingest](otlp-ingest/01-otlp-json-conformance.md) | done (3a13813) |
| 6 | [query-windows](query-windows/01-lookback-and-cursors.md) | done |
| 7 | [search-filters](search-filters/01-search-filters.md) | ready |
| 8 | [query-accuracy](query-accuracy/01-exact-bounded-queries.md) | ready |
| 9 | [trace-tree](trace-tree/01-trace-tree-view.md) | ready |
| 10 | [ai-calls](ai-calls/01-ai-call-insight.md) | ready |
| 11 | [self-description](self-description/01-openapi-and-guides.md) | ready |
| 12 | [systemd-service](systemd-service/01-service-runs.md) | ready (runs last) |

Specs 3–11 all touch the store and server, so they are implemented one at a
time, in this order.

The retention stats (ret-eeb1) are reachable from MCP through the `inn_stats`
tool, which proxies `GET /stats`; it landed with the query-windows slice.

Eta issues opened from this work (in the Eta repository):

- `docs/issues/sql-heterogeneous-column-lists`: done (Eta 5a24b687)
- `docs/issues/sql-notadb-spin`: done (Eta 54e48e79)

Deliberately out of scope: the TUI, web UI, HTML trace page, Scalar docs UI,
OTLP protobuf/gzip/gRPC (the only clients are Effect and eta_otel, both JSON),
and motel's cwd-based multi-instance locator (Inn has one user-level instance).
