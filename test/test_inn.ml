open Inn

let env pairs key = List.assoc_opt key pairs

let test_config_defaults_are_user_level () =
  match Config.resolve ~env:(env []) ~home:"/home/alice" () with
  | Error message -> Alcotest.fail message
  | Ok config ->
      Alcotest.(check string)
        "state dir" "/home/alice/.local/state/inn" config.state_dir;
      Alcotest.(check string)
        "db path" "/home/alice/.local/state/inn/telemetry.sqlite"
        config.db_path;
      Alcotest.(check string) "host" "127.0.0.1" config.host;
      Alcotest.(check int) "port" 27687 config.port

let test_config_env_overrides () =
  let env =
    env
      [
        ("XDG_STATE_HOME", "/state");
        ("INN_STATE_DIR", "/custom/state");
        ("INN_DB_PATH", "/custom/inn.sqlite");
        ("INN_HOST", "0.0.0.0");
        ("INN_PORT", "39000");
        ("INN_BASE_URL", "http://127.0.0.1:39000");
        ("INN_RETENTION_HOURS", "72");
        ("INN_MAX_DB_SIZE_MB", "2048");
      ]
  in
  match Config.resolve ~env ~home:"/home/alice" () with
  | Error message -> Alcotest.fail message
  | Ok config ->
      Alcotest.(check string) "state dir" "/custom/state" config.state_dir;
      Alcotest.(check string) "db path" "/custom/inn.sqlite" config.db_path;
      Alcotest.(check string) "host" "0.0.0.0" config.host;
      Alcotest.(check int) "port" 39000 config.port;
      Alcotest.(check string)
        "base url" "http://127.0.0.1:39000" config.base_url;
      Alcotest.(check int) "retention" 72 config.retention_hours;
      Alcotest.(check int) "max db" 2048 config.max_db_size_mb

let trace_fixture =
  {|{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"svc"}}]},"scopeSpans":[{"scope":{"name":"scope"},"spans":[{"traceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","spanId":"bbbbbbbbbbbbbbbb","name":"root","kind":"SPAN_KIND_SERVER","startTimeUnixNano":"1000000000","endTimeUnixNano":"1500000000","status":{"code":2,"message":"boom"},"attributes":[{"key":"route","value":{"stringValue":"/users"}}],"events":[{"name":"event","timeUnixNano":"1200000000","attributes":[{"key":"x","value":{"intValue":"1"}}]}]}]}]}]}|}

let log_fixture =
  {|{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"svc"}}]},"scopeLogs":[{"scope":{"name":"scope"},"logRecords":[{"timeUnixNano":"1600000000","traceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","spanId":"bbbbbbbbbbbbbbbb","severityText":"ERROR","severityNumber":17,"body":{"stringValue":"failed"},"attributes":[{"key":"route","value":{"stringValue":"/users"}}]}]}]}]}|}

let metric_fixture =
  {|{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"svc"}}]},"scopeMetrics":[{"scope":{"name":"scope"},"metrics":[{"name":"requests.total","description":"requests","unit":"1","sum":{"dataPoints":[{"startTimeUnixNano":"1000000000","timeUnixNano":"2000000000","asInt":"3","attributes":[{"key":"route","value":{"stringValue":"/users"}}]}]}}]}]}]}|}

let ai_trace_fixture =
  {|{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"svc"}}]},"scopeSpans":[{"scope":{"name":"ai"},"spans":[{"traceId":"cccccccccccccccccccccccccccccccc","spanId":"dddddddddddddddd","name":"streamText","kind":"SPAN_KIND_CLIENT","startTimeUnixNano":"3000000000","endTimeUnixNano":"3800000000","status":{"code":1},"attributes":[{"key":"ai.model.id","value":{"stringValue":"gpt-test"}},{"key":"ai.model.provider","value":{"stringValue":"openai"}},{"key":"ai.telemetry.functionId","value":{"stringValue":"session.llm"}},{"key":"ai.usage.inputTokens","value":{"intValue":"7"}},{"key":"ai.usage.outputTokens","value":{"intValue":"11"}}]}]}]}]}|}

let test_otlp_decodes_traces_logs_and_metrics () =
  let spans =
    match Otlp.decode_traces_json trace_fixture with
    | Ok spans -> spans
    | Error message -> Alcotest.fail message
  in
  let logs =
    match Otlp.decode_logs_json log_fixture with
    | Ok logs -> logs
    | Error message -> Alcotest.fail message
  in
  let metrics =
    match Otlp.decode_metrics_json metric_fixture with
    | Ok metrics -> metrics
    | Error message -> Alcotest.fail message
  in
  Alcotest.(check int) "span count" 1 (List.length spans);
  Alcotest.(check string) "span service" "svc" (List.hd spans).service_name;
  Alcotest.(check string) "span status" "error" (List.hd spans).status;
  Alcotest.(check int) "log count" 1 (List.length logs);
  Alcotest.(check string) "log body" "failed" (List.hd logs).body;
  Alcotest.(check int) "metric count" 1 (List.length metrics);
  Alcotest.(check string) "metric name" "requests.total" (List.hd metrics).name;
  Alcotest.(check string) "metric value" "3" (List.hd metrics).value

let temp_config () =
  let db_path = Filename.temp_file "inn-test-" ".sqlite" in
  Sys.remove db_path;
  {
    Config.state_dir = Filename.dirname db_path;
    db_path;
    host = "127.0.0.1";
    port = 27687;
    base_url = "http://127.0.0.1:27687";
    retention_hours = 876_000;
    max_db_size_mb = 1024;
  }

let cleanup_config config =
  List.iter
    (fun path -> if Sys.file_exists path then Sys.remove path)
    [ config.Config.db_path; config.db_path ^ "-wal"; config.db_path ^ "-shm" ]

let run_store program =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%a" (Eta.Cause.pp Store.pp_error) cause

let run_server_effect program =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%a" (Eta.Cause.pp Eta_http.Server.Error.pp) cause

let request ?(method_ = "GET") ?(target = "/health") ?(body = "") () =
  let path, query = Eta_http.Server.Request.split_target target in
  let body =
    if String.equal body "" then Eta_http.Server.Body.empty ()
    else
      let chunks = ref [ Bytes.of_string body ] in
      Eta_http.Server.Body.of_reader (fun () ->
          match !chunks with
          | [] -> Eta.Effect.pure None
          | chunk :: rest ->
              chunks := rest;
              Eta.Effect.pure (Some chunk))
  in
  {
    Eta_http.Server.Request.id = lazy "req-test";
    version = Eta_http.Core.Version.H1_1;
    scheme = "http";
    authority = Some "127.0.0.1";
    method_;
    target;
    path;
    query;
    headers = Eta_http.Core.Header.empty;
    body;
    trailers = (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 43123 };
    tls = false;
    alpn_protocol = Some "http/1.1";
    stream_id = None;
    connection_id = "conn-test";
  }

let response_body_string response =
  match Eta_http.Server.Response.body response with
  | Empty -> ""
  | Fixed chunks -> Bytes.to_string (Bytes.concat Bytes.empty chunks)
  | Stream _ -> Alcotest.fail "expected fixed response body"

let response_json response =
  response |> response_body_string |> Yojson.Safe.from_string

let json_string_field field = function
  | `Assoc fields -> (
      match List.assoc_opt field fields with
      | Some (`String value) -> value
      | _ -> Alcotest.failf "expected JSON string field %s" field)
  | _ -> Alcotest.fail "expected JSON object"

let json_list_length field = function
  | `Assoc fields -> (
      match List.assoc_opt field fields with
      | Some (`List values) -> List.length values
      | _ -> Alcotest.failf "expected JSON list field %s" field)
  | _ -> Alcotest.fail "expected JSON object"

let test_store_ingests_and_queries_all_signals () =
  let config = temp_config () in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  let spans =
    match Otlp.decode_traces_json trace_fixture with
    | Ok spans -> spans
    | Error message -> Alcotest.fail message
  in
  let logs =
    match Otlp.decode_logs_json log_fixture with
    | Ok logs -> logs
    | Error message -> Alcotest.fail message
  in
  let metrics =
    match Otlp.decode_metrics_json metric_fixture with
    | Ok metrics -> metrics
    | Error message -> Alcotest.fail message
  in
  let
    ( inserted_spans,
      inserted_logs,
      inserted_metrics,
      services,
      summaries,
      trace,
      span,
      trace_spans,
      trace_logs,
      span_logs,
      searched_spans,
      searched_traces,
      searched_logs,
      trace_stats,
      log_stats,
      trace_facets,
      log_facets,
      read_logs,
      read_metrics,
      stats )
    =
    let open Eta.Syntax in
    Store.with_db config (fun store ->
        let* inserted_spans = Store.ingest_traces store spans in
        let* inserted_logs = Store.ingest_logs store logs in
        let* inserted_metrics = Store.ingest_metrics store metrics in
        let* services = Store.list_services store in
        let* summaries = Store.list_trace_summaries ~service:"svc" store in
        let* trace = Store.get_trace store "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" in
        let* span = Store.get_span store "bbbbbbbbbbbbbbbb" in
        let* trace_spans =
          Store.list_trace_spans store "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        in
        let* trace_logs =
          Store.list_trace_logs store "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        in
        let* span_logs = Store.list_span_logs store "bbbbbbbbbbbbbbbb" in
        let* searched_spans =
          Store.search_spans
            {
              service = Some "svc";
              trace_id = None;
              operation = Some "root";
              parent_operation = None;
              status = Some "error";
              attrs = [ ("route", "/users") ];
              limit = 10;
            }
            store
        in
        let* searched_traces =
          Store.search_traces
            {
              service = Some "svc";
              operation = Some "root";
              status = Some "error";
              attrs = [ ("route", "/users") ];
              limit = 10;
            }
            store
        in
        let* searched_logs =
          Store.search_logs
            {
              service = Some "svc";
              trace_id = Some "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
              span_id = Some "bbbbbbbbbbbbbbbb";
              severity = Some "ERROR";
              body = Some "fail";
              attrs = [ ("route", "/users") ];
              limit = 10;
            }
            store
        in
        let* trace_stats =
          Store.trace_stats
            {
              group_by = "operation";
              agg = "count";
              service = Some "svc";
              operation = None;
              status = Some "error";
              attrs = [];
              limit = 10;
            }
            store
        in
        let* log_stats =
          Store.log_stats
            {
              group_by = "severity";
              service = Some "svc";
              trace_id = None;
              span_id = None;
              severity = None;
              body = None;
              attrs = [];
              limit = 10;
            }
            store
        in
        let* trace_facets =
          Store.facets
            {
              kind = "traces";
              field = "attribute_keys";
              key = None;
              service = Some "svc";
              limit = 10;
            }
            store
        in
        let* log_facets =
          Store.facets
            {
              kind = "logs";
              field = "severity";
              key = None;
              service = Some "svc";
              limit = 10;
            }
            store
        in
        let* read_logs =
          Store.list_logs
            {
              service = Some "svc";
              severity = Some "ERROR";
              contains = Some "fail";
              limit = 10;
            }
            store
        in
        let* read_metrics =
          Store.list_metric_points
            { service = Some "svc"; name = Some "requests.total"; limit = 10 }
            store
        in
        let* stats = Store.stats store in
        Eta.Effect.pure
          ( inserted_spans,
            inserted_logs,
            inserted_metrics,
            services,
            summaries,
            trace,
            span,
            trace_spans,
            trace_logs,
            span_logs,
            searched_spans,
            searched_traces,
            searched_logs,
            trace_stats,
            log_stats,
            trace_facets,
            log_facets,
            read_logs,
            read_metrics,
            stats ))
    |> run_store
  in
      Alcotest.(check int) "inserted spans" 1 inserted_spans;
      Alcotest.(check int) "inserted logs" 1 inserted_logs;
      Alcotest.(check int) "inserted metrics" 1 inserted_metrics;
      Alcotest.(check (list string)) "services" [ "svc" ] services;
      Alcotest.(check int) "summary count" 1 (List.length summaries);
      Alcotest.(check string)
        "root operation" "root"
        (List.hd summaries).root_operation_name;
      Alcotest.(check bool) "trace exists" true (Option.is_some trace);
      Alcotest.(check bool) "span exists" true (Option.is_some span);
      Alcotest.(check int) "trace span count" 1 (List.length trace_spans);
      Alcotest.(check int) "trace log count" 1 (List.length trace_logs);
      Alcotest.(check int) "span log count" 1 (List.length span_logs);
      Alcotest.(check int) "searched spans" 1 (List.length searched_spans);
      Alcotest.(check int) "searched traces" 1 (List.length searched_traces);
      Alcotest.(check int) "searched logs" 1 (List.length searched_logs);
      Alcotest.(check int) "trace stats" 1 (List.length trace_stats);
      Alcotest.(check int) "log stats" 1 (List.length log_stats);
      Alcotest.(check int) "trace facets" 2 (List.length trace_facets);
      Alcotest.(check int) "log facets" 1 (List.length log_facets);
      Alcotest.(check int) "trace logs" 1 (List.length read_logs);
      Alcotest.(check int) "metric points" 1 (List.length read_metrics);
      Alcotest.(check int) "stats spans" 1 stats.spans;
      Alcotest.(check int) "stats logs" 1 stats.logs;
      Alcotest.(check int) "stats metrics" 1 stats.metric_points;
      Alcotest.(check int) "stats traces" 1 stats.traces;
      Alcotest.(check int) "stats services" 1 stats.services

let test_server_handler_ingests_and_queries_services () =
  let config = temp_config () in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  let store = run_store (Store.open_ config) in
  Fun.protect
    ~finally:(fun () -> run_store (Store.close store))
    (fun () ->
      let ingest =
        run_server_effect
          (Inn.Server.handler config store
             (request ~method_:"POST" ~target:"/v1/traces" ~body:trace_fixture ()))
      in
      Alcotest.(check int)
        "ingest status" 200 (Eta_http.Server.Response.status ingest);
      Alcotest.(check string)
        "ingest body" "{\"accepted\":1}\n" (response_body_string ingest);
      let ingest_ai =
        run_server_effect
          (Inn.Server.handler config store
             (request ~method_:"POST" ~target:"/v1/traces" ~body:ai_trace_fixture ()))
      in
      Alcotest.(check int)
        "ingest ai status" 200 (Eta_http.Server.Response.status ingest_ai);
      let ingest_logs =
        run_server_effect
          (Inn.Server.handler config store
             (request ~method_:"POST" ~target:"/v1/logs" ~body:log_fixture ()))
      in
      Alcotest.(check int)
        "ingest logs status" 200 (Eta_http.Server.Response.status ingest_logs);
      let services =
        run_server_effect
          (Inn.Server.handler config store (request ~target:"/services" ()))
      in
      Alcotest.(check int)
        "services status" 200 (Eta_http.Server.Response.status services);
      Alcotest.(check string)
        "services body" "{\"services\":[\"svc\"]}\n"
        (response_body_string services);
      let span =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/spans/bbbbbbbbbbbbbbbb" ()))
      in
      Alcotest.(check int)
        "span status" 200 (Eta_http.Server.Response.status span);
      Alcotest.(check string)
        "span id" "bbbbbbbbbbbbbbbb"
        (span |> response_json |> json_string_field "spanId");
      let trace_spans =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:"/traces/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/spans" ()))
      in
      Alcotest.(check int)
        "trace spans status" 200 (Eta_http.Server.Response.status trace_spans);
      Alcotest.(check int)
        "trace spans length" 1
        (trace_spans |> response_json |> json_list_length "spans");
      let trace_logs =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/api/traces/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/logs" ()))
      in
      Alcotest.(check int)
        "trace logs status" 200 (Eta_http.Server.Response.status trace_logs);
      Alcotest.(check int)
        "trace logs length" 1
        (trace_logs |> response_json |> json_list_length "logs");
      let span_logs =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/spans/bbbbbbbbbbbbbbbb/logs" ()))
      in
      Alcotest.(check int)
        "span logs status" 200 (Eta_http.Server.Response.status span_logs);
      Alcotest.(check int)
        "span logs length" 1
        (span_logs |> response_json |> json_list_length "logs");
      let searched_spans =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:
                  "/spans/search?service=svc&operation=root&status=error&attr.route=%2Fusers"
                ()))
      in
      Alcotest.(check int)
        "search spans status" 200
        (Eta_http.Server.Response.status searched_spans);
      Alcotest.(check int)
        "search spans length" 1
        (searched_spans |> response_json |> json_list_length "spans");
      let searched_traces =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:
                  "/traces/search?service=svc&operation=root&status=error&attr.route=%2Fusers"
                ()))
      in
      Alcotest.(check int)
        "search traces status" 200
        (Eta_http.Server.Response.status searched_traces);
      Alcotest.(check int)
        "search traces length" 1
        (searched_traces |> response_json |> json_list_length "traces");
      let searched_logs =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:
                  "/logs/search?service=svc&body=fail&severity=ERROR&attr.route=%2Fusers"
                ()))
      in
      Alcotest.(check int)
        "search logs status" 200
        (Eta_http.Server.Response.status searched_logs);
      Alcotest.(check int)
        "search logs length" 1
        (searched_logs |> response_json |> json_list_length "logs");
      let ai_calls =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/ai/calls?model=gpt-test&provider=openai" ()))
      in
      Alcotest.(check int)
        "ai calls status" 200 (Eta_http.Server.Response.status ai_calls);
      Alcotest.(check int)
        "ai calls length" 1
        (ai_calls |> response_json |> json_list_length "calls");
      let ai_call =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/ai/calls/dddddddddddddddd" ()))
      in
      Alcotest.(check int)
        "ai call status" 200 (Eta_http.Server.Response.status ai_call);
      let ai_stats =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/ai/stats?groupBy=model&agg=count" ()))
      in
      Alcotest.(check int)
        "ai stats status" 200 (Eta_http.Server.Response.status ai_stats);
      Alcotest.(check int)
        "ai stats length" 1
        (ai_stats |> response_json |> json_list_length "stats");
      let trace_stats =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:
                  "/traces/stats?groupBy=operation&agg=count&service=svc&status=error"
                ()))
      in
      Alcotest.(check int)
        "trace stats status" 200 (Eta_http.Server.Response.status trace_stats);
      Alcotest.(check int)
        "trace stats length" 1
        (trace_stats |> response_json |> json_list_length "stats");
      let log_stats =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/logs/stats?groupBy=severity&service=svc" ()))
      in
      Alcotest.(check int)
        "log stats status" 200 (Eta_http.Server.Response.status log_stats);
      Alcotest.(check int)
        "log stats length" 1
        (log_stats |> response_json |> json_list_length "stats");
      let facets =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/facets?type=traces&field=attribute_keys&service=svc" ()))
      in
      Alcotest.(check int)
        "facets status" 200 (Eta_http.Server.Response.status facets);
      Alcotest.(check int)
        "facets length" 7
        (facets |> response_json |> json_list_length "facets");
      let endpoints =
        run_server_effect
          (Inn.Server.handler config store (request ~target:"/api/endpoints" ()))
      in
      Alcotest.(check int)
        "endpoints status" 200 (Eta_http.Server.Response.status endpoints);
      Alcotest.(check int)
        "endpoint inventory is present" 26
        (endpoints |> response_json |> json_list_length "endpoints");
      let instructions =
        run_server_effect
          (Inn.Server.handler config store (request ~target:"/instructions" ()))
      in
      Alcotest.(check int)
        "instructions status" 200
        (Eta_http.Server.Response.status instructions);
      Alcotest.(check bool)
        "instructions body" true
        (String.length (response_body_string instructions) > 0);
      let openapi =
        run_server_effect
          (Inn.Server.handler config store (request ~target:"/openapi.json" ()))
      in
      Alcotest.(check int)
        "openapi status" 200 (Eta_http.Server.Response.status openapi);
      Alcotest.(check string)
        "openapi version" "3.1.0"
        (openapi |> response_json |> json_string_field "openapi"))

let () =
  Alcotest.run "inn"
    [
      ( "config",
        [
          Alcotest.test_case "defaults are user-level" `Quick
            test_config_defaults_are_user_level;
          Alcotest.test_case "environment overrides are explicit" `Quick
            test_config_env_overrides;
        ] );
      ( "otlp",
        [
          Alcotest.test_case "decodes traces, logs, and metrics" `Quick
            test_otlp_decodes_traces_logs_and_metrics;
        ] );
      ( "store",
        [
          Alcotest.test_case "ingests and queries all signals" `Quick
            test_store_ingests_and_queries_all_signals;
        ] );
      ( "server",
        [
          Alcotest.test_case "handler ingests and queries services" `Quick
            test_server_handler_ingests_and_queries_services;
        ] );
    ]
