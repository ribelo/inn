---
status: ready-for-agent
---

# OTLP/HTTP JSON ingest conformance

## Problem Statement

Inn's ingest path deviates from OTLP/HTTP in ways that lose data or confuse
exporters:

- An export request with no spans, logs, or points is valid OTLP, but Inn
  rejects it with 400. Exporters log this as an error.
- Responses are `{"accepted":n}` instead of an OTLP export response.
  Rejected items are never reported through `partialSuccess`.
- Time is truncated to whole milliseconds before the duration is computed.
  Every span shorter than a millisecond shows a duration of 0, and spans that
  start within the same millisecond have an arbitrary order.
- A log whose `timeUnixNano` is `"0"` (unknown, per the OTLP data model) is
  stored at the epoch and does not fall back to `observedTimeUnixNano`.
- Span kind is stored as the raw enum number ("2"), not a name. Status UNSET
  and OK are merged.
- Spans with missing or malformed trace or span ids are stored with empty ids.
  Logs with an empty `traceId` or `spanId` string are stored as correlated to
  an empty id.
- Attribute values are converted to strings at ingest, so an integer or boolean
  attribute comes back as a string. Span links are dropped.
- Store failures return 500, which exporters treat as non-retryable. A
  protobuf body gets a confusing JSON parse error instead of 415.

## Solution

`POST /v1/traces`, `/v1/logs`, and `/v1/metrics` follow the OTLP/HTTP
specification for the JSON encoding. The only clients are Effect (TypeScript)
with JSON serialization and Eta's `eta_otel`, which also sends JSON, so
protobuf and gzip are out of scope. Inn keeps nanosecond time precision. It
normalizes kind and status to names, and keeps attribute value types and span
links. It reports rejected items through `partialSuccess` and uses the
status codes OTLP defines for retryable and non-retryable failures.

## User Stories

1. As an app developer, I want an empty export request accepted with 200, so that my exporter does not log spurious errors ^otlp-dtfh
2. As an app developer, I want successful ingest to return an OTLP export response body (`{}`, or `partialSuccess` when items were rejected), so that standard exporters read the result correctly ^otlp-2k5g
3. As an app developer, I want spans with missing or malformed trace or span ids rejected individually and counted in `partialSuccess`, while the valid spans in the same request are stored, so that one bad span does not lose the batch ^otlp-r73z
4. As a developer debugging performance, I want span start, end, and duration kept at nanosecond precision, so that sub-millisecond spans show real durations and correct order ^otlp-6ul3
5. As an API consumer, I want span and log timestamps exposed both as fractional milliseconds and as the original nanosecond strings, so that I can use either without losing precision ^otlp-l754
6. As a developer, I want a log with a zero or missing `timeUnixNano` to use `observedTimeUnixNano`, falling back to the ingestion time, so that such logs sort and filter at the right moment ^otlp-e9t0
7. As a developer, I want span kind stored and returned as a lowercase name (internal, server, client, producer, consumer), or null when unspecified, so that output is readable ^otlp-5oj4
8. As a developer, I want span status stored as unset, ok, or error, so that explicit OK and UNSET stay distinguishable ^otlp-a16d
9. As a developer, I want a status filter value of `ok` to match every span that is not an error (unset or ok), so that existing queries keep their meaning ^otlp-u6rw
10. As a developer, I want trace and span ids normalized to lowercase hex, and empty correlation ids on logs treated as absent, so that correlation lookups match ^otlp-hb7r
11. As a developer, I want attribute values returned with their original JSON types (string, number, boolean, array, object), so that numeric and boolean attributes are not turned into strings ^otlp-8avj
12. As a developer, I want attribute filters (`attr.key=value`) to keep matching on the string form of the value, so that filtering works the same for every value type ^otlp-zc8b
13. As a developer, I want span links (linked trace id, span id, and attributes) stored and returned with the span, so that I can follow causality across traces ^otlp-l0be
14. As an app developer, I want ingest failures caused by the store (busy, timeout, pool shutdown) to return 503 with a Retry-After header, so that my exporter retries instead of dropping data ^otlp-2wg5
15. As an app developer, I want a non-JSON content type such as `application/x-protobuf` rejected with 415 and a message saying only OTLP JSON is supported, and an oversized body rejected with 413, so that misconfiguration is obvious ^otlp-ohmj
16. As an app developer, I want a malformed JSON body rejected with 400 and an OTLP-style error body, so that the exporter reports a clear, non-retryable error ^otlp-qso2

17. As a developer, I want a log with no top-level trace or span id, but with `traceId`/`trace_id` or `spanId`/`span_id` log attributes, correlated through those attributes, so that loggers that only put ids in attributes still link to traces (motel does this) ^otlp-beaj

## Implementation Decisions

- **Model changes.** Span start and end become integer Unix nanoseconds, with
  duration derived from them. Log timestamp and observed timestamp become
  nanoseconds. Metric point times become nanoseconds. JSON output keeps the
  existing millisecond field names as floats with sub-millisecond precision,
  and adds `...UnixNano` string fields. Kind and status become closed
  variants inside the model, rendered as lowercase names. Attributes become an
  ordered list of key and typed value. The typed value mirrors OTLP AnyValue
  in JSON form. The string form used for indexing is derived in one place.
- **Storage.** Time columns store nanoseconds. Attribute JSON columns store the
  typed values. Attribute index rows keep storing the string form. Span links
  are stored as JSON on the span row. These are schema changes: bump the
  schema version from the schema versioning spec.
- **Decoder output.** The decoder returns the accepted items and a rejection
  count with a message. The server renders `partialSuccess` from that result
  (`rejectedSpans`, `rejectedLogRecords`, or `rejectedDataPoints`, plus
  `errorMessage`). A span is valid when its trace id is 32 hex characters,
  its span id is 16 hex characters, and neither is all zeros.
- **Status codes.** Empty request → 200 `{}`. Malformed JSON → 400 with an
  OTLP-style `{"code":3,"message":...}` body (google.rpc.Status, INVALID_ARGUMENT).
  Unsupported content type → 415. Oversized body → 413. Store
  failure → 503 with `Retry-After: 1`.
- **Status filter semantics.** `status=ok` means "not error" wherever a status
  filter exists: span search, trace search, stats, and AI calls.
- Protobuf, gzip, and gRPC stay out of scope.

## Testing Decisions

- Attribute-based log correlation fallback, with a valid hex id taken from the attributes (otlp-beaj).

- Decoder unit tests use fixture payloads shaped like those from Effect's
  `OtlpSerialization.layerJson` and from `eta_otel`. Capture one real payload
  from each if practical. Cover empty requests, invalid ids, zero timestamps,
  kinds, statuses, typed attributes, links, and sub-millisecond spans
  (otlp-dtfh, otlp-r73z, otlp-6ul3, otlp-e9t0, otlp-5oj4, otlp-a16d,
  otlp-hb7r, otlp-8avj, otlp-l0be).
- Server handler tests (existing prior art: the handler test in the Alcotest
  suite) check response bodies and status codes for success, partial success,
  empty requests, malformed JSON, protobuf content type, oversized bodies, and
  a store failure (otlp-2k5g, otlp-2wg5, otlp-ohmj, otlp-qso2).
- Query round trips: ingest, then query spans and logs, and check the ms and
  ns fields, typed attributes, attribute filters on numeric values, and
  status=ok semantics (otlp-l754, otlp-zc8b, otlp-u6rw).

## Out of Scope

- OTLP protobuf, gzip, and gRPC.
- Metric-specific aggregation semantics beyond storing the points.

## Further Notes

- Depends on the Eta migration spec and the schema versioning spec. It touches
  the same store code as the retention spec, so implement the two one after
  the other, not in parallel.
