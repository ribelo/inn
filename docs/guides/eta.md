# Instrumenting an Eta app for Inn

Inn accepts OTLP/HTTP JSON at `POST /v1/traces`, `POST /v1/logs`, and
`POST /v1/metrics`. Eta-next's `Eta_otel` exports completed
`Eta_observability.Logger.span` spans and logger records to the first two
endpoints. It does **not** expose a meter or export metrics: use another OTLP
metrics producer if you need metrics. The default Inn base URL is
`http://127.0.0.1:27687`.

## Create and settle an exporter

The HTTP client and exporter share a caller-owned Eio switch. The exporter
borrows the HTTP client; create the client first, and call `shutdown` before
leaving the switch. An exporter also registers a switch release hook for
pending records when the application stops without an explicit shutdown.

`test/eta_guide_snippet.ml` is compiled against eta-next and checked against
this example by Inn's test suite:

```ocaml
let run () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let http_client =
    Eta_http.Client.create ~sw ~net:(Eio.Stdenv.net stdenv) ~clock ()
  in
  let exporter =
    match
      Eta_otel.create ~sw ~clock ~http_client
        ~endpoint:"http://127.0.0.1:27687" ~service_name:"my-app"
        ~resource:[ ("service.version", "0.1.0") ] ()
    with
    | Ok exporter -> exporter
    | Error error -> failwith (Format.asprintf "%a" Eta_otel.pp_error error)
  in
  let logger =
    Eta_observability.Logger.create ~service:"my-app" ~clock
      ~mono_clock:stdenv#mono_clock ~reporter:(Eta_otel.reporter exporter)
      ~span_ids:(Eta_otel.span_ids exporter) ()
  in
  let result =
    Eta_observability.Logger.span logger "http.request" (fun () ->
        Eta_observability.Logger.info logger "work completed";
        Ok "ok")
  in
  let settlement = Eta_otel.shutdown exporter in
  (result, settlement)
```

The application's Dune stanza needs `eta`, `eta_http`, `eta_otel`,
`eta_observability`, and `eio_main`.

`Eta_otel.create` takes the endpoint as a **string**; a path prefix, if
present, is prepended to `/v1/logs` and `/v1/traces`. Its `~resource`
adds attributes such as `service.version`; `service.name` comes from
`~service_name`. Use `~headers` for authentication to a remote
collector. `~batch_size` and `~max_queue` bound buffering; a full queue
drops the newest item, reported by `Eta_otel.dropped`. `~on_error`
receives typed transport/status errors (render with `Eta_otel.pp_error`).

`Eta_otel.flush exporter` settles earlier records but keeps admission
open. `Eta_otel.shutdown exporter` closes admission and returns
`(unit, Eta_otel.error) result`. Both can report an HTTP error; shutdown
also takes an optional `Eta.Duration.t` timeout and can return
```Drain_deadline```.

## Instrument usefully

Use `Eta_observability.Logger.span` around work and log inside it so
trace/span IDs correlate the completed span and its logs. Nested spans inherit
the trace ID. Add searchable attributes via `~fields` and
`Eta_observability.Context.with_fields`, rather than burying them in the
message. Tag temporary debugging instrumentation with shared keys such as
`debug.session`, `debug.hypothesis`, and `debug.step`; remove it after
investigation (see `GET /docs/debug`).

Inn responds `200` with `{}` for a clean export and `200` with
`partialSuccess` for individually rejected spans/log records; malformed
JSON gets `400`, oversized bodies `413`, non-JSON `415`, and a busy
store `503` with `Retry-After: 1`.

## Verify

```sh
curl -s http://127.0.0.1:27687/health
curl -s 'http://127.0.0.1:27687/services?lookback=all'
curl -s 'http://127.0.0.1:27687/traces?service=my-app&lookback=15m'
curl -s 'http://127.0.0.1:27687/logs?service=my-app&lookback=15m'
```

If services stays empty, check `~endpoint`, whether the logger actually
emitted records, and whether the process exited before the exporter settled.
Read `GET /docs/debug` for the investigation workflow and
`GET /openapi.json` for the query schemas.
