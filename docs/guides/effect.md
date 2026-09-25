# Instrumenting an Effect app for Inn

Inn accepts OTLP/HTTP with JSON bodies. Effect's `effect/unstable/observability`
modules export OTLP directly, so you need no OpenTelemetry SDK, no collector
binary, and no protobuf or gRPC support — Inn rejects both with a `415`.

Inn endpoints (default local server `http://127.0.0.1:27687`):

| Signal | Endpoint |
|---|---|
| Traces | `POST /v1/traces` |
| Logs | `POST /v1/logs` |
| Metrics | `POST /v1/metrics` |

There is no auth and no query string: the URL is the whole configuration.

## Layers

Use `OtlpTracer.layer`, `OtlpLogger.layer`, and `OtlpMetrics.layer` from
`effect/unstable/observability`. Each one needs an `OtlpSerialization` (use
`OtlpSerialization.layerJson`: Inn does not accept protobuf) and an
`HttpClient` (use `FetchHttpClient.layer` in Node/Bun).

```ts
import { Layer } from "effect"
import { FetchHttpClient } from "effect/unstable/http"
import {
  OtlpLogger,
  OtlpMetrics,
  OtlpSerialization,
  OtlpTracer,
} from "effect/unstable/observability"

const baseUrl = process.env["OTEL_EXPORTER_OTLP_ENDPOINT"]
  ?.trim()
  .replace(/\/+$/, "") ?? "http://127.0.0.1:27687"

if (process.env["OTEL_EXPORTER_OTLP_ENDPOINT"] === undefined) {
  // Default to the local Inn instance when the caller did not set one.
  process.env["OTEL_EXPORTER_OTLP_ENDPOINT"] = baseUrl
}

const resource = {
  serviceName: "my-app",
  serviceVersion: "0.1.0",
}

export const otlpLayer = (): Layer.Layer<never> =>
  Layer.mergeAll(
    OtlpTracer.layer({
      url: `${baseUrl}/v1/traces`,
      resource,
    }),
    OtlpLogger.layer({
      url: `${baseUrl}/v1/logs`,
      resource,
    }),
    OtlpMetrics.layer({
      url: `${baseUrl}/v1/metrics`,
      resource,
      // "cumulative" is the default; use "delta" only if your backend needs it.
      temporality: "cumulative",
    }),
  ).pipe(
    Layer.provide(OtlpSerialization.layerJson),
    Layer.provide(FetchHttpClient.layer),
  )
```

Provide the layer to the application's main runtime once, not per feature,
request, or test:

```ts
import { Effect, Layer } from "effect"
import { otlpLayer } from "./otl"

const MainLive = Layer.mergeAll(AppLive, otlpLayer())

const program = Effect.gen(function* () {
  yield* Effect.logInfo("started", { service: "my-app" })
  // ...
})

Effect.runPromise(program.pipe(Effect.provide(MainLive)))
```

## Options that matter

- `url` — absolute URL of the signal endpoint, including `/v1/traces`,
  `/v1/logs`, or `/v1/metrics`. Inn's server base URL is `servers[0].url` in
  `GET /openapi.json`.
- `resource.serviceName` — becomes `service.name`. Every query filter in this
  guide starts from it, so set it deliberately.
- `resource.serviceVersion` — becomes `service.version`, and `/health` reports
  Inn's own version, so you can tell which build produced which telemetry.
- `headers` — extra HTTP headers on every export; unnecessary for Inn.
- `exportInterval` and `maxBatchSize` — batching; shorten the interval while
  debugging so a failing request is exported before you query Inn.
- `temporality` (`OtlpMetrics`) — `cumulative` (default) or `delta`; Inn stores
  each point with its timestamps and value, so either works.
- `shutdownTimeout` — how long a final flush may take when the scope closes.

Inn returns `200` with `{}` for a clean export. A batch with individually
rejected spans answers `200` with
`{"partialSuccess":{"rejectedSpans":1,"errorMessage":"..."}}`; logs and metrics
use `rejectedLogRecords` and `rejectedDataPoints`. Malformed JSON is a `400`, a
content type other than `application/json` is a `415`, an oversized body is a
`413`, and a busy store is a `503` with `Retry-After: 1`.

## What Inn records

- Spans, including status, timestamps, attributes, resource attributes, events,
  and links.
- Log records with `severityText`, `severityNumber`, body, attributes, and the
  correlation `traceId`/`spanId` when Effect provides the span context.
- Metric points with name, kind, timestamps, value, and attributes.
- AI calls: spans that carry OpenTelemetry GenAI attributes or Vercel AI SDK
  keys are classified at ingest, so `GET /ai/calls` finds them with `model`,
  `provider`, `sessionId`, `functionId`, `finishReason`, token usage, and the
  prompt/response previews.

## Instrument usefully

Prefer `Effect.fn("name")` for meaningful workflow spans, add child spans around
boundaries that fail or add latency, and put searchable values in structured
fields rather than only in the message:

```ts
// #region inn debug
yield* Effect.logInfo("cache lookup finished", {
  debug: {
    session: "abc123",
    hypothesis: "cache-miss",
    step: "after-read",
    label: "cache value after read",
  },
})
// #endregion inn debug
```

The `debug.*` attributes are the shared debugging keys used by
`GET /docs/debug`; wrap temporary blocks in `#region inn debug` /
`#endregion inn debug` markers so they are easy to remove after the fix is
verified.

## Verify

```sh
curl -s http://127.0.0.1:27687/health
curl -s 'http://127.0.0.1:27687/services?lookback=all'
curl -s 'http://127.0.0.1:27687/traces?service=my-app&lookback=15m'
curl -s 'http://127.0.0.1:27687/logs?service=my-app&lookback=15m'
curl -s 'http://127.0.0.1:27687/metrics?service=my-app&lookback=15m'
curl -s 'http://127.0.0.1:27687/ai/calls?service=my-app&lookback=15m'
```

If `services` is empty, check the exporter first: the layer was never provided,
the URL is wrong, or the process exited before the export interval elapsed. Inn
logs nothing about rejected telemetry on purpose — read the export response in
your own trace/log stream, or set a short `exportInterval` while debugging.

Read `GET /docs/debug` next for the investigation workflow, and
`GET /openapi.json` for every parameter and response schema.
