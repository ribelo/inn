# Instrumenting an Eta app for Inn

Inn accepts OTLP/HTTP with JSON bodies, so an Eta app needs no extra collector:
`Eta_otel` exports Eta's tracer, logger, and meter capabilities straight to
Inn's `/v1/traces`, `/v1/logs`, and `/v1/metrics` endpoints.

Inn endpoints (default local server `http://127.0.0.1:27687`):

| Signal | Endpoint |
|---|---|
| Traces | `POST /v1/traces` |
| Logs | `POST /v1/logs` |
| Metrics | `POST /v1/metrics` |

There is no auth and no query string. Protobuf, gzip, and gRPC are not
supported; `Eta_otel` already speaks OTLP/JSON.

## Create the exporter

`Eta_otel.create` needs three things from the application: a runtime factory for
exporter-owned work, an HTTP client, and the collector endpoint.

```ocaml
open Eta

let run () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in

  let runtime_factory tracer = Eta_eio.Runtime.create ~sw ~clock ~tracer () in
  let http_client = Eta_http_eio.Client.make_h1 ~sw ~net () in

  let exporter =
    Eta_otel.create ~runtime_factory ~http_client ~clock:(Eta_eio.clock clock)
      ~endpoint:(Eta_http.Core.Url.of_string "http://127.0.0.1:27687")
      ~service_name:"my-app" ~service_version:"0.1.0" ()
  in

  let rt =
    Eta_eio.Runtime.create ~sw ~clock
      ~tracer:(Eta_otel.tracer exporter)
      ~logger:(Eta_otel.logger exporter)
      ~meter:(Eta_otel.meter exporter) ()
  in

  let work = Eta_observability.named "http.request" (Effect.pure "ok") in
  let result = Eta.Runtime.run rt work in
  let settlement = Eta_otel.shutdown exporter in
  (result, settlement)
```

The dune stanza for that program:

```dune
(executable
 (name app)
 (libraries eta eta_observability eta_eio eta_http_eio eta_otel eio_main))
```

## Configuration that matters

- `~endpoint:(Eta_http.Core.Url.t)` — the collector base URL, for example
  `Eta_http.Core.Url.of_string "http://127.0.0.1:27687"`. It replaced the old
  `?host`/`?port` pair; the endpoint's scheme and authority are kept on every
  OTLP request URL.
- `?traces_path`, `?logs_path`, `?metrics_path` — default to `/v1/traces`,
  `/v1/logs`, and `/v1/metrics`, which is exactly what Inn serves, so pointing
  `~endpoint` at Inn is enough.
- `?self_metrics_path` — where the exporter's own health metrics go; defaults to
  the metrics path. Inn accepts them, so leave it alone. Use
  `~disable_self_metrics:true` only for a collector that rejects OTLP metrics
  (Inn does not). Setting both `~disable_self_metrics:true` and
  `~self_metrics_path` raises `Invalid_argument`.
- `?service_name` and `?service_version` — become `service.name` and
  `service.version`; every Inn query starts from the service name, so set it.
- `?resource_attrs` — extra resource attributes on every signal.
- `?queue_capacity` — per-signal mailbox bound, `1024` by default. When a
  mailbox is full, telemetry is dropped and counted instead of blocking the
  application fiber (`Eta_otel.dropped`, `queue_depth`, `in_flight`).
- `?on_error:(diagnostic -> unit)` — receives a structured diagnostic with the
  phase, the signal, and the complete cause tree, for example:

```ocaml
~on_error:(fun (diagnostic : Eta_otel.diagnostic) ->
  prerr_endline
    (Printf.sprintf "otlp %s failed in %s"
       (Eta_otel.signal_to_string diagnostic.signal)
       (Eta_otel.phase_to_string diagnostic.phase)))
```

- `?on_send` and `~debug:true` — local debugging of the exporter itself (the
  request body, or one stderr line per POST).

Export failures are non-fatal: the exporter retries the OTLP retryable statuses
(`429`, `502`, `503`, `504`), counts drops, and reports through `~on_error`.
Inn answers `200` with `{}` for a clean export, `200` plus
`partialSuccess.rejectedSpans` (or `rejectedLogRecords` /
`rejectedDataPoints`) when individual records were rejected, `400` for
malformed JSON, `413` for an oversized body, `415` for a non-JSON content type,
and `503` with `Retry-After: 1` when the store is busy.

## Settle the exporter

`Eta_otel.shutdown` closes admission, drains everything that was admitted, and
waits for the exporter's own task to finish, so the last spans and logs reach
Inn before the process exits:

```ocaml
match Eta_otel.shutdown exporter with
| Eta.Exit.Ok Eta_otel.Drained -> ()
| Eta.Exit.Ok (Eta_otel.Deadline_reached { remaining }) ->
    Printf.eprintf "exporter deadline: %d signals remain\n" remaining
| Eta.Exit.Error cause ->
    Printf.eprintf "%a\n" (Eta.Cause.pp Eta_otel.pp_export_error) cause
```

Use `Eta_otel.flush` instead when the exporter stays open. Both take
`?timeout_s`. Completion means the captured records settled, not that Inn
accepted them: a handled export failure stays reported through `~on_error`.

## Instrument usefully

- `Eta_observability.named "operation" work` for meaningful spans;
- `Eta_observability.log "message"` (or the logger capability) for correlated
  log records — they inherit the current span's `traceId` and `spanId`;
- `Eta_observability.metric_update` with a counter, gauge, histogram, or
  summary for measurements;
- attributes for anything you will want to search: put them in span or log
  attributes rather than only in the message text.

Tag temporary debugging instrumentation with the shared keys so one query finds
all of it:

```ocaml
(* #region inn debug *)
let debug_attrs =
  [ ("debug.session", "abc123"); ("debug.hypothesis", "cache-miss");
    ("debug.step", "after-read") ]
(* #endregion inn debug *)
```

Remove every marked block once the fix is verified; see `GET /docs/debug` for
the workflow that uses `attr.debug.session` and `attrContains.debug.label`.

## Verify

```sh
curl -s http://127.0.0.1:27687/health
curl -s 'http://127.0.0.1:27687/services?lookback=all'
curl -s 'http://127.0.0.1:27687/traces?service=my-app&lookback=15m'
curl -s 'http://127.0.0.1:27687/logs?service=my-app&lookback=15m'
curl -s 'http://127.0.0.1:27687/metrics?service=my-app&lookback=15m'
```

If `services` stays empty, check the exporter configuration before the
instrumentation: a wrong `~endpoint`, an exporter that was never used to build
the runtime, or a process that exited before `shutdown`.

## Environment-driven bootstrap

Eta also ships `Eta_otel_eio`, an Eio bootstrap over the same exporter core. It
resolves `OTEL_EXPORTER_OTLP_ENDPOINT` (default `http://127.0.0.1:4318`),
`OTEL_SERVICE_NAME` (default `eta`), and `OTEL_SDK_DISABLED`, so pointing an app
at Inn can be pure configuration:

```sh
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:27687
```

- `Eta_otel_eio.init_scoped_from_env ~sw ~net ~clock ()` returns a handle whose
  `Scoped.runtime` the caller runs on, with `Scoped.tracer`, `Scoped.logger`,
  `Scoped.meter`, and `Scoped.shutdown` on the caller's switch.
- `Eta_otel_eio.with_otlp ~sw ~net ~clock body` runs `body` on that runtime and
  settles the exporter before returning.
- `Eta_otel_eio.init_from_env ()` starts a private worker thread and returns a
  `Threaded.t` sink with a producer-side logger and meter for code with no
  ambient Eta runtime; tracing stays on the scoped API.

Either way, set `OTEL_EXPORTER_OTLP_ENDPOINT` to Inn and the defaults line up:
`Eta_otel`'s signal paths are already `/v1/traces`, `/v1/logs`, and
`/v1/metrics`.

Read `GET /docs/debug` next for the investigation workflow, and
`GET /openapi.json` for every parameter and response schema.
