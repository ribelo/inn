---
status: ready-for-agent
---

# Search filters with motel's reach

## Problem Statement

Motel's searches are more forgiving and more expressive than Inn's. Examples of
what Inn gets wrong today:

- `operation=GET /api` matches only an operation named exactly that.
- A log stored as "error" is not found with `severity=ERROR`.
- Attribute values can only be matched exactly: there is no
  `attrContains.<key>`.
- There is no minimum-duration filter for finding slow traces.
- `parentOperation` is resolved against every span in the store, not against
  the candidate's actual parent.
- Trace search `status=ok` returns traces that contain errors, as long as
  one span was OK.
- The body filter treats `%` and `_` in the user's text as wildcards.

## Solution

Operation, parent operation, log body, and AI text filters are
case-insensitive substring matches, with the user's text taken literally.
`attrContains.<key>=<text>` complements `attr.<key>=<value>` on every
endpoint that takes attribute filters. `minDurationMs` finds slow traces,
spans, and AI calls. Severity matching ignores case and also understands
severity numbers. Trace status means trace health. The CLI and MCP expose the
same filters.

## User Stories

1. As an agent, I want `operation` to match any span or trace whose operation name contains my text, ignoring case, so that "users" finds "GET /api/users/:id" ^srch-sjbi
2. As an agent, I want `parentOperation` to match spans whose actual parent span (in the same trace) has an operation containing my text, ignoring case, so that parent filtering means what it says ^srch-ypr2
3. As an agent, I want log `body` (and its alias `contains`) to be a literal, case-insensitive substring match, so that searching for `100%` or `user_id` works ^srch-zjff
4. As an agent, I want `attrContains.<key>=<text>` on trace search, span search, log list and search, trace and log stats, and trace and span log lists, so that I can find, for example, any URL containing "/checkout" ^srch-odnn
5. As an agent, I want several `attr.` and `attrContains.` filters combined with AND, so that I can narrow results step by step ^srch-ynd1
6. As an agent, I want `minDurationMs` on trace search, trace stats, span search, AI call search, and AI stats, so that I can find slow work directly ^srch-w4sn
7. As an agent, I want `severity=error` to match ERROR, Error, and error, so that I don't have to guess each logger's casing ^srch-pxq5
8. As an agent, I want `minSeverity=warn` to match every log at WARN or above by OTLP severity number, falling back to severity text when the number is absent, so that I can see "everything bad" in one query ^srch-qplh
9. As an agent, I want trace search and trace stats `status=error` to mean "the trace has at least one error span", and `status=ok` to mean "the trace has no error spans", so that status describes trace health ^srch-k254
10. As an agent, I want span search `status` to keep filtering individual spans (with ok meaning "not error"), so that span-level queries stay precise ^srch-sh8y
11. As an agent, I want a `text` filter on trace search that matches traces having an AI span whose prompt or response contains my text, so that I can find the conversation where something was said ^srch-oylo
12. As an agent, I want invalid filter values (a non-numeric `minDurationMs`, an unknown `minSeverity`) rejected with 400, so that typos do not silently return everything ^srch-jk2v
13. As a CLI user, I want `--attr-contains KEY=TEXT`, `--min-duration-ms`, `--min-severity`, and `--text` flags on the matching commands, so that the CLI can express every filter ^srch-fe5d
14. As an agent using MCP, I want `attributeContains`, `minDurationMs`, `minSeverity`, and `text` arguments on the matching MCP tools, so that MCP has the same power as HTTP ^srch-reld
15. As an agent, I want the filters each endpoint supports listed in the endpoint inventory and OpenAPI, so that I can discover them ^srch-z5cu

## Implementation Decisions

- **Substring matching** uses `LIKE` with an escape character. The user's
  `%`, `_`, and escape characters are escaped. Matching is case-insensitive
  for ASCII, which is SQLite's default `LIKE` behavior. If Eta SQL's
  expression builder cannot express `LIKE ... ESCAPE`, stop and report it as
  an Eta gap. Do not paper over it.
- No full-text index in this spec. Substring matching over the retained
  24-48 hours is expected to be fast enough, and it is more predictable than
  motel's token-prefix FTS. Revisit only if measurements show otherwise.
- **attrContains** matches the string form of attribute values in the
  attribute index table: `value LIKE %text%` for that key. All attribute
  predicates are pushed into SQL as `EXISTS` or semi-join subqueries on the
  attribute table. They are not materialized as id lists (see the query
  accuracy spec). If both specs are implemented by one worker, share the
  mechanism.
- **Severity.** Store an uppercase normalized severity text next to the raw
  text, or compare case-insensitively. `minSeverity` takes
  trace/debug/info/warn/error/fatal and maps each to OTLP severity number
  ranges (1, 5, 9, 13, 17, 21). When a log has no number, it falls back to the
  normalized text.
- **Trace status** is evaluated on the trace summary's error count.
- **Parent operation** is evaluated with a self-join of spans on (trace id,
  parent span id).
- **AI text** reuses the AI-content attribute keys defined by the AI call
  spec. Until that spec lands, it uses the keys for prompt, response, and
  tool content from both the Vercel `ai.*` and the `gen_ai.*` conventions.
- The filter set per endpoint is declared once, and the HTTP parser, endpoint
  inventory, OpenAPI, CLI, and MCP schemas are all generated from that
  declaration where practical.

## Testing Decisions

- Store and handler tests with a fixture of mixed spans and logs cover each
  filter, including literal `%` and `_`, mixed case, the AND of attribute
  filters, and trace-health status on a trace with mixed span statuses
  (srch-sjbi … srch-oylo).
- 400 cases (srch-jk2v).
- CLI and MCP schema coverage as in the query windows spec (srch-fe5d,
  srch-reld). Inventory and OpenAPI listing (srch-z5cu).

## Out of Scope

- Full-text indexing and relevance ranking.
- Regex matching.

## Further Notes

- Depends on the query windows spec. Implement it afterwards, in the same
  files.
