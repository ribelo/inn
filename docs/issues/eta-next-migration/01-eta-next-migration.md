---
status: in-progress
package: inn
consumer: inn
---

# Inn on eta-next

## Problem Statement

Inn's live collector still links v1 Eta's effect interpreter, HTTP service and SQL pool. Its CLI, tests and published Eta guide also use the v1 runtime. The first direct-style server and SQL consumer must retain ingestion, queries, retention, database ownership, CLI errors and orderly shutdown without replacing the running systemd user service during migration.

## Solution

Pin the flake to the eta-next branch and depend only on its consolidated `eta_http`, `eta_sql` and core packages. Call the HTTP client, server/service router and typed SQL pool directly inside Eio scopes; preserve Inn's existing Cmdliner entry point and application-owned store lifecycle rather than grafting on a second Door. Update the guide to an exporter snippet that compiles on eta-next. Use a private build directory and a separate temporary port/database for the run check. No v1 effect runtime, compatibility bridge or mixed dependency graph remains.

## User Stories

1. As an Inn maintainer, I want the Nix input and OPAM metadata to resolve only eta-next packages, so that a fresh build cannot silently link v1. ^innnext-7s8b
2. As an Inn operator, I want OTLP ingestion and HTTP query routes to preserve their responses and error codes, so that my existing exporters and queries keep working. ^innnext-7l5h
3. As an Inn maintainer, I want the SQLite schema, typed queries, pool and migration lifecycle to work in direct style, so that data survives ingestion, pruning and restart. ^innnext-lmjl
4. As an Inn CLI caller, I want the direct HTTP client to preserve output and connection diagnostics, so that querying a stopped or running server stays understandable. ^innnext-lleq
5. As an Eta application reader, I want Inn's exporter guide example to compile against eta-next and show correlated logs and spans, so that I can instrument an application without v1 runtime calls. ^innnext-8nuj
6. As an Inn operator, I want a fresh isolated server to answer health and query requests while the installed systemd unit remains untouched, so that migration validation cannot disrupt telemetry collection. ^innnext-5lh2

## Requirements

- The Inn build shall link only eta-next Eta packages and shall contain no v1 `Effect.t` interpreter or compatibility bridge. ^innnext-574z
- When an OTLP JSON request reaches a supported endpoint, Inn shall ingest valid records and return the existing partial-success or validation response. ^innnext-9nue
- When a client calls an existing HTTP query route, Inn shall preserve its documented status and JSON response shape. ^innnext-knf9
- When Inn opens an existing compatible SQLite database, Inn shall retain its data and use typed queries and migrations through the direct-style SQL pool. ^innnext-btr0
- If Inn cannot connect to the configured query server, then the Inn CLI shall print its actionable connection hint and return a nonzero status. ^innnext-jojb
- When a reader compiles the Eta exporter example, the example shall use only the eta-next HTTP client, logger and OTLP exporter APIs. ^innnext-8otv
- While the installed user service is active, the migration run check shall use a separate temporary database and port and shall not restart or replace that service. ^innnext-7np3

## Implementation Decisions

- Preserve Inn's existing Cmdliner command group: `Eta_app.run` owns the Door's own command/config parsing and SIGINT/SIGTERM lifecycle, not an embeddable `serve` function. Swapping only `inn server` into it would change the `inn server`, `inn daemon`, query and MCP command tree and the present flag/environment-based configuration (including systemd invocation), and replace the established five-second HTTP drain boundary. For this migration Inn explicitly owns its Eio switch, store and shutdown signals. Follow up separately on ADR-0004's one-application model by mapping Inn's complete CLI and configuration to the Door before deleting `with_shutdown_signals`; do not graft on half a Door during a compatibility migration.
- Use `Eta_http.Client.request` for CLI calls, `Eta_http.Service.Router` and `Service.Serve.h1` for routes and listening, and `Eta_sql.Pool` for typed and raw SQLite operations. Expected errors stay typed results; no local reimplementation of kernel packages.
- Preserve the published TypeScript Effect guide as a separate client integration: `Effect` there refers to the external JavaScript library, not v1 Eta.

## Testing Decisions

- Existing OTLP, route and response tests cover innnext-7l5h, innnext-9nue and innnext-knf9. Existing schema/retention tests cover innnext-lmjl and innnext-btr0. Direct CLI and guide checks cover innnext-lleq, innnext-8nuj, innnext-jojb and innnext-8otv. A private build, Nix input audit and grep cover innnext-7s8b and innnext-574z. An isolated HTTP/database smoke check covers innnext-5lh2 and innnext-7np3.
- Run `nix develop -c dune build @install`, `nix develop -c dune test` and `nix develop -c dune build @fmt` with a private `--build-dir` under timeout. Check the guide executable with `INN_ETA_GUIDE_SNIPPET=1`.

## Out of Scope

Replacing the running systemd service or installed shared-switch executable; redesigning Inn's CLI with Eta's Door; changes to eta-next or Leash source.

## Further Notes

Eta-next supplied every server/service and SQL pool contract needed for Inn ingestion and queries. One nonblocking parity gap remains for applications that read the previous Inn Eta guide: eta-next `Eta_otel` does not yet expose a meter or OTLP metrics export, and the v1 `Eta_otel_eio` environment bootstrap is absent. Inn still accepts third-party OTLP metrics at `/v1/metrics`; the compiled guide explicitly limits its Eta example to spans and logs.

Draft eta-next consumer spec for a later slice: As an Eta application using Inn, I want direct-style metric instruments and an OTLP/HTTP JSON metrics exporter, so my existing measurements reach Inn alongside spans and logs. When a metric is recorded, the exporter shall attach configured service/resource attributes and deliver it to the configured `/v1/metrics` path with bounded buffering. When the caller flushes or shuts down the exporter, it shall settle admitted metric records or return a typed deadline/transport error. Treat environment-variable bootstrap as a separate consumer story rather than silently rebuilding the v1 runtime. No eta-next source change is included here.
