---
status: completed
package: inn
consumer: inn
---

# Inn on eta-next

## Problem Statement

Inn's live collector still links v1 Ox's effect interpreter, HTTP service and SQL pool. Its CLI, tests and published Ox guide also use the v1 runtime. The first direct-style server and SQL consumer must retain ingestion, queries, retention, database ownership, CLI errors and orderly shutdown without replacing the running systemd user service during migration.

## Solution

Pin the flake to the eta-next branch and depend only on its consolidated `ox_http`, `ox_sql` and core packages. Call the HTTP client, server/service router and typed SQL pool directly inside Eio scopes; preserve Inn's existing Cmdliner entry point and application-owned store lifecycle rather than grafting on a second Door. Update the guide to an exporter snippet that compiles on eta-next. Use a private build directory and a separate temporary port/database for the run check. No v1 effect runtime, compatibility bridge or mixed dependency graph remains.

## User Stories

1. As an Inn maintainer, I want the Nix input and OPAM metadata to resolve only eta-next packages, so that a fresh build cannot silently link v1. ^innnext-7s8b
2. As an Inn operator, I want OTLP ingestion and HTTP query routes to preserve their responses and error codes, so that my existing exporters and queries keep working. ^innnext-7l5h
3. As an Inn maintainer, I want the SQLite schema, typed queries, pool and migration lifecycle to work in direct style, so that data survives ingestion, pruning and restart. ^innnext-lmjl
4. As an Inn CLI caller, I want the direct HTTP client to preserve output and connection diagnostics, so that querying a stopped or running server stays understandable. ^innnext-lleq
5. As an Ox application reader, I want Inn's exporter guide example to compile against eta-next and show correlated logs, spans and metric instruments, so that I can instrument an application without v1 runtime calls. ^innnext-8nuj
6. As an Inn operator, I want a fresh isolated server to answer health and query requests while the installed systemd unit remains untouched, so that migration validation cannot disrupt telemetry collection. ^innnext-5lh2

## Requirements

- The Inn build shall link only eta-next Ox packages and shall contain no v1 `Effect.t` interpreter or compatibility bridge. ^innnext-574z
- When an OTLP JSON request reaches a supported endpoint, Inn shall ingest valid records and return the existing partial-success or validation response. ^innnext-9nue
- When a client calls an existing HTTP query route, Inn shall preserve its documented status and JSON response shape. ^innnext-knf9
- When Inn opens an existing compatible SQLite database, Inn shall retain its data and use typed queries and migrations through the direct-style SQL pool. ^innnext-btr0
- If Inn cannot connect to the configured query server, then the Inn CLI shall print its actionable connection hint and return a nonzero status. ^innnext-jojb
- When a reader compiles the Ox exporter example, the example shall use only the eta-next HTTP client, logger, meter and OTLP exporter APIs, and its counter and histogram shall reach the collector's `/v1/metrics` path. ^innnext-8otv
- While the installed user service is active, the migration run check shall use a separate temporary database and port and shall not restart or replace that service. ^innnext-7np3

## Implementation Decisions

- Preserve Inn's existing Cmdliner command group: `Ox_app.run` owns the Door's own command/config parsing and SIGINT/SIGTERM lifecycle, not an embeddable `serve` function. Swapping only `inn server` into it would change the `inn server`, `inn daemon`, query and MCP command tree and the present flag/environment-based configuration (including systemd invocation), and replace the established five-second HTTP drain boundary. For this migration Inn explicitly owns its Eio switch, store and shutdown signals. Follow up separately on ADR-0004's one-application model by mapping Inn's complete CLI and configuration to the Door before deleting `with_shutdown_signals`; do not graft on half a Door during a compatibility migration.
- Use `Ox_http.Client.request` for CLI calls, `Ox_http.Service.Router` and `Service.Serve.h1` for routes and listening, and `Ox_sql.Pool` for typed and raw SQLite operations. Expected errors stay typed results; no local reimplementation of kernel packages.
- Preserve the published TypeScript Effect guide as a separate client integration: `Effect` there refers to the external JavaScript library, not v1 Ox.

## Testing Decisions

- Existing OTLP, route and response tests cover innnext-7l5h, innnext-9nue and innnext-knf9. Existing schema/retention tests cover innnext-lmjl and innnext-btr0. Direct CLI and guide checks cover innnext-lleq, innnext-8nuj, innnext-jojb and innnext-8otv: the compiled example asserts that its counter and histogram reached a collector's `POST /v1/metrics`, and a second run of the same binary against a real Inn on a free port and a temporary state directory requires `GET /metrics` to return both. A private build, Nix input audit and grep cover innnext-7s8b and innnext-574z. An isolated HTTP/database smoke check covers innnext-5lh2 and innnext-7np3.
- Run `nix develop -c dune build @install`, `nix develop -c dune test` and `nix develop -c dune build @fmt` with a private `--build-dir` under timeout. Check the guide executable, and its run against an isolated Inn, with `INN_ETA_GUIDE_SNIPPET=1`.

## Out of Scope

Replacing the running systemd service or installed shared-switch executable; redesigning Inn's CLI with Ox's Door; changes to eta-next or Leash source.

## Further Notes

Ox-next supplied every server/service and SQL pool contract needed for Inn ingestion and queries. The metrics gap this spec left open is closed: eta-next row 34 (`d8d2d237`) added `Ox_otel.meter` with `Ox_otel.Meter.counter`, `up_down_counter` and `histogram`, their `add` and `record`, and a window posted to `/v1/metrics` on `~metrics_interval`, on `flush`, on `shutdown` and when the exporter's switch ends. The guide's compiled example now records a counter and a histogram on that window, `test/ox_guide_snippet.ml` fails unless both reached a collector's `POST /v1/metrics`, and the same binary run against an isolated Inn must leave both in `GET /metrics`.

Restoring the example found an eta-next defect older than row 34: `Ox_otel.post` passed `~max_body_bytes:0`, so a collector answering with a body — Inn answers `200 {}` — failed every export as an OTLP transport error. Ox-next `14f80b76` reads and ignores a bounded 64 KiB response body, with its own suite and the isolated-Inn check covering it; Inn's ox input is pinned to that revision.

The v1 `Ox_otel_eio` environment bootstrap is still absent from eta-next. It stays out of scope here; treat it as a separate consumer story rather than silently rebuilding the v1 runtime.
