---
status: completed
---

# Self-describing API and agent guides

## Problem Statement

Motel teaches agents how to use it:

- a full OpenAPI document with every parameter and response schema
- a docs index serving a debugging-workflow guide and an Effect
  instrumentation guide over HTTP and MCP
- a health response that reports version and start time

Inn's OpenAPI document is a stub, with no parameters and no schemas, and it
leaves out `/v1/metrics`, `/healthz`, and `/ready`. Inn has no guides. Its
health response has no version or start time, and `serverInfo.version` and
the CLI version report "dev". An agent pointed at Inn has to guess which
filters exist and how to debug with them.

## Solution

Inn generates its OpenAPI document and endpoint inventory from the same
per-endpoint declarations that drive request parsing. That includes the
parameters, with types, defaults, and descriptions, and the response schemas.
It serves a small set of Markdown guides: a debugging workflow for agents, an
Effect OTLP setup guide, and an Eta `eta_otel` setup guide. The guides are
available over HTTP, the CLI, and MCP. Health reports version, start time, and
uptime.

## User Stories

1. As an agent, I want `/openapi.json` to list every endpoint with its query parameters (type, default, allowed values, description) and response schema, so that I can call Inn correctly without reading source ^desc-iduq
2. As an agent, I want the endpoint inventory (`/endpoints`) and OpenAPI generated from the same declarations the server uses to parse requests, so that the documentation cannot drift from behavior ^desc-de6o
3. As an agent, I want `/v1/metrics`, `/healthz`, `/ready`, and the `/api` alias policy included in the inventory and OpenAPI, so that nothing is hidden ^desc-dmuw
4. As an agent, I want `GET /docs` to list the available guides (name, title, path) and `GET /docs/{name}` to return one guide as Markdown, so that I can learn the debugging workflow from the server itself ^desc-bqwh
5. As an agent, I want a "debug" guide describing how to investigate with Inn (find the service, narrow the window, search traces and logs, open the tree, check AI calls, use stats and facets), with example queries, so that I follow an effective workflow ^desc-wy48
6. As an app developer, I want an "effect" guide showing how to point an Effect app's OtlpTracer, OtlpLogger, and metrics at Inn with JSON serialization, so that new apps are instrumented correctly ^desc-od3y
7. As an app developer, I want an "eta" guide showing how to point an Eta app's `eta_otel` exporter at Inn, so that OCaml apps are instrumented correctly ^desc-62du
8. As an agent using MCP, I want `inn_docs_index` and `inn_get_doc` tools, so that I can read the guides through MCP ^desc-s5j5
9. As a CLI user, I want `inn docs` and `inn docs NAME`, so that I can read the guides in the terminal ^desc-85u9
10. As an agent, I want `/health` to report `version`, `startedAt` (ISO 8601), and `uptimeSeconds`, so that I can tell which build is running and whether it restarted ^desc-8syr
11. As a user, I want `inn --version`, the MCP `serverInfo.version`, and `/health` to all report the same real version, so that versions are consistent ^desc-lqpr
12. As an agent, I want `/instructions` to point to the guides and to the OpenAPI document, so that the setup text leads to the full documentation ^desc-qv27
13. As an agent, I want unknown doc names answered with 404 listing the available names, so that I can recover ^desc-7wwz

## Implementation Decisions

- **Declarations.** Each endpoint is declared once, with method, path, the
  parameters it accepts (name, kind, default, allowed values, description),
  and a response schema description. The HTTP parameter parsing uses the
  declared parameter set. OpenAPI 3.1 and `/endpoints` are rendered from
  it. The list-policy and filter declarations from the query windows and
  search filter specs feed into this.
- **Guides** are Markdown files in the repository, embedded into the binary
  at build time (for example with a dune rule generating an OCaml module), so
  the service does not depend on a checkout path at run time.
- **Docs paths** are `/docs` and `/docs/{name}`, with `/api/docs` aliases
  under the existing alias policy. There is no HTML documentation UI.
- **Version** comes from a single build-time source shared with the MCP
  stdio spec.

## Testing Decisions

- A test walks the router's declared endpoints and checks that each appears
  in OpenAPI and `/endpoints` with its parameters (desc-iduq, desc-de6o,
  desc-dmuw).
- Handler tests for docs index, doc content, the 404, health fields, and
  instructions links (desc-bqwh, desc-7wwz, desc-8syr, desc-qv27).
- A guide content smoke test: each guide is non-empty and mentions the
  endpoints it describes (desc-wy48, desc-od3y, desc-62du). Check the guide
  instructions against real Effect and Eta exporter configuration in
  /home/ribelo/projects/ribelo/effect-pie/src/otl.ts and Eta's lib/otel.
- MCP and CLI coverage (desc-s5j5, desc-85u9, desc-lqpr).

## Out of Scope

- Scalar or any other HTML API reference UI.
- Web UI or static file serving.

## Further Notes

- Implement last among the API specs, so that it describes the final
  parameter set.
