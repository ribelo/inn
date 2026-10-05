# Inn issues

Specs for the Ox migration and motel-parity work, in implementation order.
Each spec's frontmatter carries its status (completed = implemented and accepted). Story IDs are cited by tests.

| Order | Spec | Status |
|---|---|---|
| 1 | [ox-migration](ox-migration/01-build-on-latest-ox.md) | done (879fe3a, 7a04a97) |
| 2 | [mcp-stdio](mcp-stdio/01-standard-stdio-transport.md) | done (dd2f3b9) |
| 3 | [schema-versioning](schema-versioning/01-recreate-on-mismatch.md) | done (4faa31e) |
| 4 | [retention](retention/01-per-signal-retention.md) | done (4faa31e) |
| 5 | [otlp-ingest](otlp-ingest/01-otlp-json-conformance.md) | done (3a13813) |
| 6 | [query-windows](query-windows/01-lookback-and-cursors.md) | done (da7ed14) |
| 7 | [search-filters](search-filters/01-search-filters.md) | done (6154c60) |
| 8 | [query-accuracy](query-accuracy/01-exact-bounded-queries.md) | done (6154c60) |
| 9 | [trace-tree](trace-tree/01-trace-tree-view.md) | done (3426a91) |
| 10 | [ai-calls](ai-calls/01-ai-call-insight.md) | done (3426a91) |
| 11 | [self-description](self-description/01-openapi-and-guides.md) | done (c03f279) |
| 12 | [systemd-service](systemd-service/01-service-runs.md) | done (fb9bd18) |
| 13 | [eta-next-migration](eta-next-migration/01-eta-next-migration.md) | in progress |
| 14 | [caps](caps/01-caps.md) | done (uncommitted; ox row 52) |
| 15 | [caps-on-ox-lint](caps-on-ox-lint/01-caps-on-ox-lint.md) | done |
| 16 | [thread-door-capabilities](thread-door-capabilities/01-thread-door-capabilities.md) | done (uncommitted for review) |
| 17 | [restart-daemon-exec](restart-daemon-exec/01-restart-daemon-exec.md) | ready-for-agent |
| 18 | [delayed-command-cancellation](delayed-command-cancellation/01-classify-delayed-command-cancellation.md) | ready-for-agent |

Specs 3–11 all touch the store and server, so they are implemented one at a
time, in this order.

The retention stats (ret-eeb1) are reachable from MCP through the `inn_stats`
tool, which proxies `GET /stats`; it landed with the query-windows slice.

Ox issues opened from this work (in the Ox repository):

- `docs/issues/sql-heterogeneous-column-lists`: done (Ox 5a24b687)
- `docs/issues/sql-notadb-spin`: done (Ox 54e48e79, 13749175)
- `docs/issues/sql-like-escape`: done (Ox 426d7f33)
- `docs/issues/changelog-audit-breaks`: done (Ox d00ed4c7)
- `docs/issues/sql-nullable-aggregates`: done (Ox d64f1e88)
- `docs/issues/http-serve-sigterm-drain`: done (Ox bca907d5)

Deliberately out of scope: the TUI, web UI, HTML trace page, Scalar docs UI,
OTLP protobuf/gzip/gRPC (the only clients are Effect and ox_otel, both JSON),
and motel's cwd-based multi-instance locator (Inn has one user-level instance).
