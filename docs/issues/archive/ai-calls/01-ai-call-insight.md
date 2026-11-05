---
status: completed
---

# AI call insight

## Problem Statement

Motel shows an AI call as a readable record:

- previews of the prompt and response
- token usage (input, output, total, cached, reasoning)
- finish reason
- tool-call count

Its detail view adds the parsed prompt messages, the full response, the tool
calls, the available tools, provider metadata, and timing (time to first
chunk, tokens per second).

Inn gives a raw attribute dump with at most model, provider, and input and
output tokens. Inn also has problems finding AI calls:

- Its detection counts any span carrying an `ai.` or `gen_ai.` attribute, so
  nested provider spans (`ai.generateText.doGenerate`) and tool-execution
  spans appear as separate "calls" next to their parent.
- Detection runs after fetching 10,000 arbitrary spans, and has no
  minimum-duration or time-window filter.

The apps that send to Inn are Effect (`effect/unstable/ai`) and Ox
(`ox_ai`). Both follow the OpenTelemetry GenAI semantic conventions
(`gen_ai.*`). Motel only understands the Vercel AI SDK `ai.*` keys.

## Solution

Inn classifies AI spans at ingest into *AI calls* (one model invocation or a
top-level AI operation), *tool executions*, and *nested provider spans*. It
understands both the GenAI semantic conventions (primary) and the Vercel AI
SDK keys. AI call search and stats cover only AI calls, and they are exact and
indexed. The summary and detail give motel's level of insight, built from
whichever convention the span uses.

## User Stories

1. As an agent, I want AI calls detected from GenAI semantic-convention spans (such as `gen_ai.operation.name` chat or text_completion, or `gen_ai.request.model`) and from Vercel AI SDK top-level `ai.*` spans, so that calls from Effect, Ox, and Vercel apps all show up ^aic-cw6h
2. As an agent, I want nested provider spans (Vercel `ai.*.do*` under a top-level `ai.*` span) excluded when their parent is an AI call, so that one logical call is not listed twice ^aic-jupv
3. As an agent, I want tool-execution spans (`gen_ai.operation.name=execute_tool`, Vercel `ai.toolCall`) classified as tool calls and not as AI calls, so that the call list shows model invocations ^aic-qs41
4. As an agent, I want each AI call summary to include operation, service, provider, model, status, start time, duration, finish reason, session id, function id, user id, tool-call count, and usage (input, output, total, cached-input, and reasoning tokens, each nullable), so that I can scan calls quickly ^aic-q5qt
5. As an agent, I want 200-character previews of the prompt and response in the summary when the span has that content, so that I can recognize a call without opening it ^aic-kqhv
6. As an agent, I want the AI call detail to include the parsed prompt messages, the full response text, the tool calls (name, span id, status, duration, arguments and result when present), the available tools, provider metadata, and timing (time to first chunk, time to finish, output tokens per second), so that I can debug a model interaction fully ^aic-fy0u
7. As an agent, I want the AI call detail to include correlated logs, and to link to the parent trace, so that I can see what happened around the call ^aic-hjcg
8. As an agent, I want `minDurationMs`, `lookback`, `cursor`, `operation`, `finishReason`, and `text` filters on AI call search, next to the existing model, provider, session, function, status, and service filters, so that I can find slow, failed, or specific calls ^aic-yfcd
9. As an agent, I want `text` to match prompt, response, and tool content, ignoring case, so that I can find the call where a phrase appeared ^aic-gywl
10. As an agent, I want AI stats grouped by provider, model, functionId, sessionId, status, operation, or finishReason, with count, avg_duration, p95_duration, total_input_tokens, total_output_tokens, total_tokens, and error_rate, all exact over the window, so that I can compare models and costs ^aic-qpv6
11. As an agent, I want an unsupported `groupBy` or `agg` rejected with 400 listing the allowed values, so that typos are caught ^aic-e67r
12. As an agent, I want a request for the detail of a span that is not an AI call to return 404 with a hint when the span is a tool call or a nested provider span, pointing to its AI call parent, so that I can navigate to the right record ^aic-t8tl
13. As a CLI and MCP user, I want the new fields and filters available in `inn ai-calls`, `inn ai-call`, `inn ai-stats`, and the matching MCP tools, so that every surface has the same insight ^aic-5j9w
14. As an agent, I want where each field came from (GenAI convention or Vercel key) documented in one table in the docs, so that I know what my instrumentation must emit ^aic-6xrr

## Implementation Decisions

- **Classification** is a pure module applied at ingest. It maps a span
  (operation name and merged attributes) to AI call, tool execution, nested
  provider span, or none. The result is stored on the span with an index.
  The query accuracy spec's AI flag is this classification.
- **Extraction** is a pure module from a span, plus its child spans for tool
  calls, to a typed AI call summary and detail. It looks keys up in a
  precedence table: GenAI conventions first (`gen_ai.provider.name`,
  `gen_ai.system`, `gen_ai.request.model`, `gen_ai.response.model`,
  `gen_ai.usage.*`, `gen_ai.response.finish_reasons`,
  `gen_ai.response.time_to_first_chunk`, `gen_ai.input.messages`,
  `gen_ai.output.messages`, `gen_ai.tool.*`, and GenAI events when
  present), then Vercel `ai.*` keys (`ai.model.id`, `ai.model.provider`,
  `ai.usage.*`, `ai.prompt.messages`, `ai.response.text`,
  `ai.prompt.tools`, `ai.response.providerMetadata`,
  `ai.response.msToFirstChunk`, `ai.telemetry.*`). Typed attribute values
  from the OTLP ingest spec are used directly. JSON-string content is parsed
  when valid and kept raw otherwise.
- **Storage.** Summary fields used for filtering, grouping, and aggregation
  (provider, model, operation, finish reason, session, function, token
  counts) are denormalized into an AI call table at ingest. Stats then run in
  SQL. This bumps the schema version.
- **Text search** is a case-insensitive literal substring match over the
  stored prompt, response, and tool content, as in the search filter spec.
- Inspect Ox's `ox_ai` and Effect's `effect/unstable/ai` telemetry code
  to confirm the exact keys they emit. Ox is at
  /home/ribelo/projects/ribelo/ocaml/ox/lib/ai. An Effect checkout is in the
  node_modules of /home/ribelo/projects/ribelo/effect-pie. Build fixtures from
  what they actually emit.

## Testing Decisions

- Unit tests for classification and extraction with fixtures for an Ox
  gen_ai chat span, an Effect gen_ai span with a tool execution child, and a
  Vercel `ai.generateText` span with a `doGenerate` child and `ai.toolCall`
  children (aic-cw6h … aic-fy0u).
- Store and handler tests for search filters, pagination, stats, 400s, and
  the 404 hint (aic-hjcg, aic-yfcd, aic-gywl, aic-qpv6, aic-e67r, aic-t8tl).
- CLI and MCP schema coverage (aic-5j9w). Docs table presence (aic-6xrr).

## Out of Scope

- Cost estimation in currency.
- Prompt redaction.

## Further Notes

- Implement after the query accuracy spec.
