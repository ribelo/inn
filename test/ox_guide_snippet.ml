(* A stand-in collector: an in-process OTLP/HTTP server that records every
   request it receives and answers 200 with {}. Running the example against it
   shows a counter and a histogram leaving the process for POST /v1/metrics;
   set OTEL_EXPORTER_OTLP_ENDPOINT to export to a real collector instead. *)
let start_collector ~sw ~net ~clock =
  let received = ref [] in
  let router = Ox_http.Service.Router.create () in
  let record req =
    let body =
      match Ox_http.Service.Extractors.body_text req with
      | Ok body -> body
      | Error _ -> ""
    in
    received := (Ox_http.Service.Req.path req, body) :: !received;
    Ok
      (Ox_http.Server.Response.text
         ~headers:
           (Ox_http.Header.unsafe_of_list
              [ ("content-type", "application/json") ])
         "{}")
  in
  List.iter
    (fun path ->
      Ox_http.Service.Router.add_exn router ~methods:[ "POST" ] path record)
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
      Ox_http.Server.run_h1_on_socket ~sw ~clock ~socket:listener
        (Ox_http.Service.Router.compile router);
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

let run ~(caps : < Ox_caps.Cap.env ; Ox_caps.Cap.random ; .. >) () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  (* Inn, or any OTLP collector, when the environment names one; otherwise the
     stand-in collector above, which also lets the example check what arrived. *)
  let endpoint, received =
    match Ox_caps.Cap_sys.getenv_opt ~caps "OTEL_EXPORTER_OTLP_ENDPOINT" with
    | Some endpoint -> (endpoint, None)
    | None ->
        let endpoint, received = start_collector ~sw ~net ~clock in
        (endpoint, Some received)
  in
  let http_client = Ox_http.Client.create ~sw ~net ~clock () in
  let exporter =
    match
      Ox_otel.create ~caps ~sw ~clock ~http_client ~endpoint
        ~service_name:"my-app" ~ending_budget:(Ox.Duration.seconds 5)
        ~resource:[ ("service.version", "0.1.0") ] ()
    with
    | Ok exporter -> exporter
    | Error error -> failwith (Format.asprintf "%a" Ox_otel.pp_error error)
  in
  let logger =
    Ox_observability.Logger.create ~service:"my-app" ~clock
      ~mono_clock:stdenv#mono_clock ~reporter:(Ox_otel.reporter exporter)
      ~span_ids:(Ox_otel.span_ids exporter) ()
  in
  let meter = Ox_otel.meter exporter in
  let requests =
    Ox_otel.Meter.counter meter ~name:"http.requests" ~unit_:"{request}"
      ~description:"requests served" ()
  in
  let durations =
    Ox_otel.Meter.histogram meter ~name:"http.request.duration" ~unit_:"ms"
      ~boundaries:[ 10.0; 50.0; 200.0 ] ()
  in
  let result =
    Ox_observability.Logger.span logger "http.request" (fun () ->
        Ox_otel.Meter.add requests 1.0;
        Ox_otel.Meter.record durations 42.0;
        Ox_observability.Logger.info logger "work completed";
        Ok "ok")
  in
  let settlement = Ox_otel.shutdown exporter in
  (* shutdown settles the meter's window before returning, so the collector has
     already answered POST /v1/metrics when the example checks what it holds. *)
  (match received with Some received -> check_metrics received | None -> ());
  (result, settlement)

let main ~(caps : < Ox_caps.Cap.env ; Ox_caps.Cap.random ; Ox_caps.Cap.stdout ; .. >) () =
  let _, settlement = run ~caps () in
  match settlement with
  | Ok () ->
      Ox_caps.Cap_stdlib.print_endline ~caps "spans, logs, the counter and the histogram reached the collector"
  | Error error -> failwith (Format.asprintf "%a" Ox_otel.pp_error error)

let () =
  let caps = Ox_test.powerbox () in
  main ~caps ()
