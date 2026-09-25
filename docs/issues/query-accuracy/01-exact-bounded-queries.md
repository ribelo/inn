---
status: ready-for-agent
---

# Accurate, bounded queries

## Problem Statement

Several Inn queries silently answer from a sample instead of from all matching
data:

- Trace search with span-level filters looks at only the newest 10,000
  matching spans.
- Trace stats, log stats, facets, AI calls, and AI stats all start from a
  10,000-row fetch and aggregate in memory.
- AI call search fetches the newest 10,000 spans of any kind, then filters for
  AI spans. On a busy machine, older AI calls simply vanish.

Attribute filters first load every matching owner id into memory, then send
them back to SQLite as one `IN (...)` list. A popular attribute (such as
`http.method=GET`) makes that slow, and can exceed SQLite's bound-variable
limit and fail the request.

Facet counts also differ in meaning from motel's:

- Trace facets count spans, not traces.
- The "operation" facet lists every span operation instead of root operations.
- The "status" facet lists span statuses, not trace health.

`/services` includes metric-only services, while trace listing by service
matches only a trace's root service.

## Solution

Every filter, aggregate, and facet runs in SQL over *all* matching rows in the
requested window. Results are exact, and memory stays bounded. Attribute
predicates are subqueries, not materialized id lists. AI spans are identified
once, at ingest, and indexed, so AI queries touch only AI spans. Trace facets
count distinct traces and describe trace-level properties. When a query cannot
be exact, the response says so instead of silently truncating.

## User Stories

1. As an agent, I want trace search results to include every matching trace in the window, not just those found among the newest 10,000 spans, so that search results are complete ^acc-879n
2. As an agent, I want trace stats, log stats, and AI stats computed over all matching rows in the window, so that counts, averages, and error rates are exact ^acc-laac
3. As an agent, I want p95 duration computed exactly, using the nearest-rank method over all matching rows, so that the percentile does not depend on sampling ^acc-7kkc
4. As an agent, I want attribute-filtered queries on common attributes to succeed quickly and never fail from too many SQL variables, so that filtering by `http.method=GET` works on a busy store ^acc-whoa
5. As an agent, I want AI call search to find every AI call in the window, however many non-AI spans exist, so that older AI calls do not disappear ^acc-gkoz
6. As an agent, I want trace facets for service, operation, and status to describe traces (root service, root operation, trace health) and count distinct traces, so that the numbers match what trace search returns ^acc-jjlo
7. As an agent, I want attribute key and attribute value facets for traces to count distinct traces, and to skip values longer than 512 characters, so that facets stay readable and meaningful ^acc-lh84
8. As an agent, I want log facets computed over all logs in the window, so that facet counts are exact ^acc-efzp
9. As an agent, I want a `service` filter on trace list and trace search to match traces in which that service emitted any span, with the root service still shown in the summary, so that I can find traces my service took part in ^acc-km90
10. As an agent, I want `/services` to list services that emitted spans or logs, and optionally metrics with `signal=metrics`, so that the default list matches what I can debug with traces and logs ^acc-itfo
11. As an operator, I want stats and facet queries on a store with a million rows to finish in bounded time and memory, so that the service stays responsive ^acc-1ccu
12. As an agent, I want any response that could not be computed exactly (for example because of a hard safety cap) to carry `meta.approximate: true`, so that silent sampling never happens ^acc-g6qx

## Implementation Decisions

- **Pushdown.** Attribute `attr.` and `attrContains.` filters become
  correlated `EXISTS` subqueries against the attribute index tables, on
  (key, value) and owner. No owner-id lists are materialized in OCaml.
- **Aggregates.** Count, avg, error-rate, and token sums use SQL
  `GROUP BY`. p95 uses a window function or an ordered fetch of just the
  duration column per group; either way it is exact. If Eta SQL's typed
  builders cannot express `GROUP BY`, aggregate functions, window functions,
  or `EXISTS` subqueries, stop and report exactly which construct is
  missing, so that an Eta ticket can be opened. Do not work around it with
  in-memory scans.
- **Trace participation.** Maintain a trace-to-service participation table
  at ingest, keyed by (trace id, service name) and maintained with the trace
  summary. The service filter uses it.
- **AI flag.** A boolean AI-call column on spans, set at ingest by the AI
  detection rule defined in the AI call spec, with an index. Until that spec
  lands, use the current `is_ai_span` rule.
- **Facets.** Trace facets for service and operation come from trace
  summaries (root service, root operation). The status facet comes from the
  trace summary's error count. Attribute facets count
  `DISTINCT trace_id` through the span-to-trace mapping.
- **Indexes and upserts.** Eta now supports mixed-type column lists
  (`Q.Column.any`). Add the composite indexes the new queries need, such as
  (service_name, start time) and (trace_id, parent_span_id). Replace the span
  and trace-summary insert-then-update pairs with single
  `on_conflict_update` upserts.
- Remove the 10,000-row fetches from stats, facets, AI, and trace search.
- Schema changes bump the schema version.

## Testing Decisions

- Store tests with more than 10,000 rows show that results are exact where
  the old code truncated: 12,000 spans with the AI call being the oldest, and
  a trace stat over 11,000 traces (acc-879n, acc-laac, acc-gkoz, acc-efzp).
- p95 against a known distribution (acc-7kkc).
- An attribute filter matching 40,000 rows succeeds, which exceeds the
  default variable limit of 32,766 (acc-whoa).
- Facet semantics fixture (acc-jjlo, acc-lh84). Participation filter
  (acc-km90). Services with `signal` (acc-itfo).
- A timing guard with a generous threshold on a synthetic store of about
  200,000 rows. Mark it as a slow test if the suite has that notion
  (acc-1ccu).
- If a safety cap is kept, a test shows the approximate flag (acc-g6qx).

## Out of Scope

- Materialized rollups and pre-aggregation.
- New aggregate kinds beyond those that exist today.

## Further Notes

- Implement after the search filter spec. Both touch the same predicate
  builders.
