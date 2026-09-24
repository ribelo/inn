---
status: ready-for-agent
---

# Time windows and cursor pagination for queries

## Problem Statement

Motel lets agents and people ask "what happened in the last 15 minutes" and
page through long results. Inn cannot. Every Inn list, search, stats, and facet
query covers all stored data. The only bound is a `limit`, so the next page
of results cannot be fetched. Correlated trace and span log lists have no
limit at all. Log records have no stable id, so a cursor could not even be
built. Responses do not say whether results were truncated. Agents therefore
cannot tell "these are all matches" from "these are the first N".

## Solution

Every list, search, stats, and facet endpoint takes a relative time window
(`lookback`). Every list and search endpoint also takes an opaque `cursor`
for the next page. List responses include a `meta` object with the effective
limit and window, the number returned, whether more results exist, and the
next cursor when they do. Log records get a stable id. The same parameters
exist in the CLI and the MCP tools. Inn improves on motel in three ways: it
rejects an invalid cursor or window with 400 instead of silently ignoring it,
it emits a cursor only when another page exists, and it paginates span search
and AI call search too.

## User Stories

1. As an agent, I want a `lookback` parameter (such as `15m`, `2h`, `1d`) on every list, search, stats, facet, and services query, so that I only see recent activity ^win-nzur
2. As an agent, I want list and search queries to default to a one-hour window when I give no `lookback`, so that a first query is fast and focused on recent activity ^win-e7k8
3. As an agent, I want `lookback=all` to mean the whole retained history, so that I can search older data on purpose ^win-m4ld
4. As an agent, I want stats and facet queries to default to the whole retained history, so that aggregates are complete unless I narrow them ^win-jee9
5. As an agent, I want every list and search response to include `meta` with `limit`, `lookback`, `returned`, `truncated`, and `nextCursor`, so that I know whether I have seen everything ^win-fl8w
6. As an agent, I want to pass `nextCursor` back as `cursor` and get the next page with no duplicates and no gaps, even when new data arrives between requests, so that I can walk long result sets ^win-edze
7. As an agent, I want `nextCursor` present only when another page exists, so that I do not make an empty extra request ^win-7xet
8. As an agent, I want a malformed cursor, a cursor from another endpoint kind, or an invalid lookback rejected with a 400 that explains the expected format, so that mistakes are visible ^win-xl30
9. As an agent, I want cursor pagination on trace lists, trace search, span search, logs, log search, trace logs, span logs, and AI call search, so that every long list can be walked ^win-5hgv
10. As an agent, I want the correlated trace and span log lists to honor `limit`, `lookback`, and `cursor` like other log queries, so that a noisy trace does not return an unbounded payload ^win-ggl7
11. As an agent, I want each log record to carry a stable `id`, so that I can refer to one log line and so that cursors are well-defined ^win-xpfn
12. As a CLI user, I want `--lookback` and `--cursor` flags on the matching commands, so that the CLI can do everything the HTTP API can ^win-y63l
13. As an agent using MCP, I want `lookback` and `cursor` arguments on the matching MCP tools, so that I can page without leaving the tool interface ^win-2olw
14. As an agent, I want the services list to accept `lookback` and default to the whole retained history, so that I can ask which services were active recently ^win-3ghy
15. As an agent, I want the order of list results documented and stable (newest first, with a unique tie-breaker), so that pagination and comparisons are deterministic ^win-xi3q

## Implementation Decisions

- **Lookback grammar.** A positive integer followed by `m`, `h`, or `d`,
  or the literal `all`. There is no upper clamp: retention already bounds the
  data. The window is resolved once per request against the server clock and
  applies to the signal's own event timestamp (span start, log timestamp,
  metric timestamp), not to ingestion time.
- **Defaults.** Lists and searches default to `1h`. Stats, facets, and
  services default to `all`. Keep the existing limit validation (400 on
  invalid input, range 1..10000) and the existing per-endpoint default limits.
- **Cursor.** An opaque base64url token encoding the endpoint kind (trace,
  span, log, or AI call), the sort key of the last row, a unique tie-breaker
  id, and the resolved window start. With the window start in the cursor,
  later pages use the same window as page one. Decoding validates the kind
  and the shape. Keyset pagination only: `(sort_key < k) OR (sort_key = k AND
  id < i)` with a matching descending `ORDER BY`. No offsets.
- **Truncation.** Fetch `limit + 1` rows to compute `truncated`.
- **Log ids.** Log rows already have a unique text id. Expose it as `id` in
  log JSON. Ordering is by timestamp, then id.
- **Response shape.** Keep Inn's named collection keys (`traces`, `spans`,
  `logs`, `calls`) and add a sibling `meta` object to list and search
  responses. Stats and facets add `meta` with only `lookback` and `limit`.
  This is a deliberate Inn improvement over motel's `data` envelope. There is
  no compatibility alias.
- **Placement.** Parsing and validation of `lookback`, `limit`, and `cursor`
  is one list-policy module, used by the HTTP layer. The store query
  functions take a resolved window, a limit, and an optional decoded cursor
  position. CLI and MCP only pass these parameters through to HTTP.

## Testing Decisions

- Test the list-policy module with a table of inputs: lookback grammar, the
  limit range, cursor round trips, and rejection of wrong-kind or garbage
  cursors (win-xl30).
- Store and handler tests: ingest items with controlled timestamps, then
  check the window boundaries (win-nzur, win-e7k8, win-m4ld, win-jee9,
  win-3ghy). Walk a result set of 250 items in pages of 100, adding new items
  between pages, and check for no duplicates, no gaps, and that the last page
  has no cursor (win-edze, win-7xet, win-fl8w, win-5hgv, win-ggl7, win-xi3q).
- Check that log JSON carries an `id` (win-xpfn).
- CLI coverage via cram or the argument-parsing unit layer. MCP coverage via
  the pure MCP handler from the MCP stdio spec: check that tool schemas list
  the new arguments and that they reach the HTTP query (win-y63l, win-2olw).

## Out of Scope

- Absolute `since`/`until` timestamps. Could come later.
- Changes to filter semantics. See the search filter spec.

## Further Notes

- Depends on the OTLP ingest spec (nanosecond time columns) and on the MCP
  stdio spec (MCP module location). Implement after both.
