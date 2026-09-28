# Instrumenting an Eta app for Inn

Inn accepts OTLP/HTTP JSON at `POST /v1/traces`, `POST /v1/logs`, and
`POST /v1/metrics`. Eta-next's `Eta_otel` exports all three from one
exporter: completed `Eta_observability.Logger.span` spans, logger records, and
the measurements made through the meter it hands out. The default Inn base URL
is `http://127.0.0.1:27687`.

## Create and settle an exporter

The HTTP client and exporter share a caller-owned Eio switch. The exporter
borrows the HTTP client; create the client first, and call `shutdown` before
leaving the switch. An exporter also registers a switch release hook for
pending records when the application stops without an explicit shutdown.

`test/eta_guide_snippet.ml` is compiled against eta-next and checked against
this example by Inn's test suite. The example exports to a collector it starts
itself on a loopback port, records one request on a counter and its duration on
a histogram, and fails unless the counter and the histogram reached its
`POST /v1/metrics`. Set `OTEL_EXPORTER_OTLP_ENDPOINT` (for example to
`http://127.0.0.1:27687`) to send the same program to Inn instead.

```ocaml
(* A stand-in collector: an in-process OTLP/HTTP server that records every
   request it receives and answers 200 with {}. Running the example against it
   shows a counter and a histogram leaving the process for POST /v1/metrics;
   set OTEL_EXPORTER_OTLP_ENDPOINT to export to a real collector instead. *)
let start_collector ~sw ~net ~clock =
  let received = ref [] in
  let router = Eta_http.Service.Router.create () in
  let record req =
    let body =
      match Eta_http.Service.Extractors.body_text req with
      | Ok body -> body
      | Error _ -> ""
    in
    received := (Eta_http.Service.Req.path req, body) :: !received;
    Ok
      (Eta_http.Server.Response.text
         ~headers:
           (Eta_http.Header.unsafe_of_list
              [ ("content-type", "application/json") ])
         "{}")
  in
  List.iter
    (fun path ->
      Eta_http.Service.Router.add_exn router ~methods:[ "POST" ] path record)
    [ "/v1/traces"; "/v1/logs"; "/v1/metrics" ];
  let listener =
    Eio.Net.listen ~sw ~backlog:8 net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr listener with
    | `Tcp (_, port) -> port
    | _ -> assert false
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eta_http.Server.run_h1_on_socket ~sw ~clock ~socket:listener
        (Eta_http.Service.Router.compile router);
      `Stop_daemon);
  (Printf.sprintf "http://127.0.0.1:%d" port, received)

(* Metric names are JSON strings in the OTLP body, so splitting on quotes
   leaves each one as an element of its own. *)
let mentions body name = List.mem name (String.split_on_char '"' body)

let check_metrics received =
  let bodies =
    List.filter_map
      (fun (path, body) ->
        if String.equal path "/v1/metrics" then Some body else None)
      !received
  in
  match bodies with
  | [] -> failwith "no POST /v1/metrics reached the collector"
  | _ ->
      let body = String.concat "\n" bodies in
      if not (mentions body "http.requests") then
        failwith "the counter never reached POST /v1/metrics";
      if not (mentions body "http.request.duration") then
        failwith "the histogram never reached POST /v1/metrics";
      if not (mentions body "bucketCounts") then
        failwith "the histogram's samples were never aggregated"

let run () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  (* Inn, or any OTLP collector, when the environment names one; otherwise the
     stand-in collector above, which also lets the example check what arrived. *)
  let endpoint, received =
    match Sys.getenv_opt "OTEL_EXPORTER_OTLP_ENDPOINT" with
    | Some endpoint -> (endpoint, None)
    | None ->
        let endpoint, received = start_collector ~sw ~net ~clock in
        (endpoint, Some received)
  in
  let http_client = Eta_http.Client.create ~sw ~net ~clock () in
  let exporter =
    match
      Eta_otel.create ~sw ~clock ~http_client ~endpoint ~service_name:"my-app"
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
  let meter = Eta_otel.meter exporter in
  let requests =
    Eta_otel.Meter.counter meter ~name:"http.requests" ~unit_:"{request}"
      ~description:"requests served" ()
  in
  let durations =
    Eta_otel.Meter.histogram meter ~name:"http.request.duration" ~unit_:"ms"
      ~boundaries:[ 10.0; 50.0; 200.0 ] ()
  in
  let result =
    Eta_observability.Logger.span logger "http.request" (fun () ->
        Eta_otel.Meter.add requests 1.0;
        Eta_otel.Meter.record durations 42.0;
        Eta_observability.Logger.info logger "work completed";
        Ok "ok")
  in
  let settlement = Eta_otel.shutdown exporter in
  (* shutdown settles the meter's window before returning, so the collector has
     already answered POST /v1/metrics when the example checks what it holds. *)
  (match received with Some received -> check_metrics received | None -> ());
  (result, settlement)

let () =
  let _, settlement = run () in
  match settlement with
  | Ok () ->
      print_endline "spans, logs, the counter and the histogram reached the collector"
  | Error error -> failwith (Format.asprintf "%a" Eta_otel.pp_error error)
```

The application's Dune stanza needs `eta`, `eta_http`, `eta_otel`,
`eta_observability`, and `eio_main`.

`Eta_otel.create` takes the endpoint as a **string**; a path prefix, if
present, is prepended to `/v1/logs`, `/v1/traces`, and `/v1/metrics`. Its
`~resource` adds attributes such as `service.version`; `service.name` comes
from `~service_name`. Use `~headers` for authentication to a remote collector.
`~batch_size` and `~max_queue` bound buffering; a full queue drops the newest
item, reported by `Eta_otel.dropped`. `~on_error` receives typed
transport/status errors (render with `Eta_otel.pp_error`).

`Eta_otel.flush exporter` settles earlier records but keeps admission open.
`Eta_otel.shutdown exporter` closes admission and returns
`(unit, Eta_otel.error) result`. Both can report an HTTP error; shutdown also
takes an optional `Eta.Duration.t` timeout and can return
`` `Drain_deadline ``.

## Record measurements

`Eta_otel.meter exporter` is the meter; instruments made from it aggregate each
measurement into its series as it is recorded, so recording never suspends and
never blocks on collector I/O.

- `Eta_otel.Meter.counter meter ~name ()` and `Eta_otel.Meter.add instrument
  delta` — a monotonic counter whose increments are summed over one export
  window and sent as a delta sum with `isMonotonic` set. A negative increment
  is a caller defect, not a decrease: a value that can go down belongs on
  `Eta_otel.Meter.up_down_counter`.
- `Eta_otel.Meter.histogram meter ~boundaries ~name ()` and
  `Eta_otel.Meter.record instrument sample` — one sample per call, counted into
  the explicit bounds plus an overflow bucket, with the window's count, sum,
  min and max.

Create each instrument once and reuse it. `~unit_`, `~description` and `~attrs`
become the OTLP metric's unit and description and its data point's attributes,
which `GET /metrics` returns with the point. A window reports only what was
recorded during it, so a counter starts again from zero in the next window
rather than resending a running total.

The window goes to `/v1/metrics` of the same endpoint, under the same resource
attributes and headers as logs and traces: every `~metrics_interval` (sixty
seconds by default), on `Eta_otel.flush`, on `Eta_otel.shutdown`, and when the
switch that owns the exporter ends, so a short-lived program's measurements
still arrive. `~max_metric_series` bounds how many distinct series — a name, a
kind and an attribute set — the exporter aggregates; a record that would begin
one more is dropped and counted by `Eta_otel.dropped`.

## Instrument usefully

Use `Eta_observability.Logger.span` around work and log inside it so
trace/span IDs correlate the completed span and its logs. Nested spans inherit
the trace ID. Add searchable attributes via `~fields` and
`Eta_observability.Context.with_fields`, rather than burying them in the
message. Tag temporary debugging instrumentation with shared keys such as
`debug.session`, `debug.hypothesis`, and `debug.step`; remove it after
investigation (see `GET /docs/debug`).

Inn responds `200` with `{}` for a clean export and `200` with
`partialSuccess` for individually rejected spans/log records; malformed JSON
gets `400`, oversized bodies `413`, non-JSON `415`, and a busy store `503` with
`Retry-After: 1`.

## Verify

```sh
curl -s http://127.0.0.1:27687/health
curl -s 'http://127.0.0.1:27687/services?lookback=all'
curl -s 'http://127.0.0.1:27687/traces?service=my-app&lookback=15m'
curl -s 'http://127.0.0.1:27687/logs?service=my-app&lookback=15m'
curl -s 'http://127.0.0.1:27687/metrics?service=my-app&lookback=15m'
```

If services stays empty, check `~endpoint`, whether the logger actually
emitted records, and whether the process exited before the exporter settled.
For metrics, check that the instruments came from `Eta_otel.meter` and that the
process lived through a window: an interval, a flush, or a shutdown.
`GET /metrics?name=<metric>` narrows one series. Read `GET /docs/debug` for the
investigation workflow and `GET /openapi.json` for the query schemas.