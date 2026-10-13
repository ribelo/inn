open Inn

let env pairs key = List.assoc_opt key pairs

let hour_ms = 60 * 60 * 1000

(* A fixed ingestion-clock base: retention tests drive the store clock, so no
   test depends on wall-clock time. *)
let base_time = 1_700_000_000_000

let contains haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if index + needle_len > len then false
    else if String.equal (String.sub haystack index needle_len) needle then true
    else loop (index + 1)
  in
  needle_len = 0 || loop 0

(* Config ---------------------------------------------------------------- *)

let test_config_defaults_are_user_level ~(caps : < Ox_caps.Cap.env ; .. >) () =
  match Config.resolve ~caps ~env:(env []) ~home:"/home/alice" () with
  | Error message -> Alcotest.fail message
  | Ok config ->
      Alcotest.(check string)
        "state dir" "/home/alice/.local/state/inn" config.state_dir;
      Alcotest.(check string)
        "data dir" "/home/alice/.local/state/inn/segments" config.data_dir;
      Alcotest.(check string) "host" "127.0.0.1" config.host;
      Alcotest.(check int) "port" 27687 config.port;
      Alcotest.(check int) "budget (bcache-c4p7)" 1024 config.max_db_size_mb

let test_config_env_overrides ~(caps : < Ox_caps.Cap.env ; .. >) () =
  let env =
    env
      [
        ("XDG_STATE_HOME", "/state");
        ("INN_STATE_DIR", "/custom/state");
        ("INN_HOST", "0.0.0.0");
        ("INN_PORT", "39000");
        ("INN_BASE_URL", "http://127.0.0.1:39000");
        ("INN_MAX_DB_SIZE_MB", "2048");
      ]
  in
  match Config.resolve ~caps ~env ~home:"/home/alice" () with
  | Error message -> Alcotest.fail message
  | Ok config ->
      Alcotest.(check string) "state dir" "/custom/state" config.state_dir;
      Alcotest.(check string) "data dir" "/custom/state/segments" config.data_dir;
      Alcotest.(check string) "host" "0.0.0.0" config.host;
      Alcotest.(check int) "port" 39000 config.port;
      Alcotest.(check string)
        "base url" "http://127.0.0.1:39000" config.base_url;
      Alcotest.(check int) "budget" 2048 config.max_db_size_mb

let test_config_rejects_removed_settings ~(caps : < Ox_caps.Cap.env ; .. >) () =
  (* bcache-c4p7: a removed setting is refused by name, never ignored. *)
  List.iter
    (fun name ->
      match Config.resolve ~caps ~env:(env [ (name, "72") ]) ~home:"/home/alice" () with
      | Ok _ -> Alcotest.failf "%s must be rejected" name
      | Error message ->
          Alcotest.(check bool) (name ^ " is named") true (contains message name);
          Alcotest.(check bool)
            (name ^ " points at the budget") true
            (contains message "INN_MAX_DB_SIZE_MB"))
    [
      "INN_DB_PATH";
      "INN_RETENTION_HOURS";
      "INN_TRACES_RETENTION_HOURS";
      "INN_LOGS_RETENTION_HOURS";
      "INN_METRICS_RETENTION_HOURS";
      "INN_PRUNE_INTERVAL_SECONDS";
    ]

let test_config_rejects_invalid_values ~(caps : < Ox_caps.Cap.env ; .. >) () =
  let check_invalid name value =
    let env = env [ (name, value) ] in
    match Config.resolve ~caps ~env ~home:"/home/alice" () with
    | Ok _ -> Alcotest.failf "%s = %S must be rejected" name value
    | Error message ->
        Alcotest.(check bool)
          (Printf.sprintf "%s is named in the error" name)
          true (contains message name)
  in
  check_invalid "INN_PORT" "0";
  check_invalid "INN_MAX_DB_SIZE_MB" "huge";
  check_invalid "INN_MAX_DB_SIZE_MB" "-1"

(* Fixtures -------------------------------------------------------------- *)

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
    | Ok decoded -> decoded.items
    | Error message -> Alcotest.fail message
  in
  let logs =
    match Otlp.decode_logs_json log_fixture with
    | Ok decoded -> decoded.items
    | Error message -> Alcotest.fail message
  in
  let metrics =
    match Otlp.decode_metrics_json metric_fixture with
    | Ok decoded -> decoded.items
    | Error message -> Alcotest.fail message
  in
  Alcotest.(check int) "span count" 1 (List.length spans);
  Alcotest.(check string) "span service" "svc" (List.hd spans).service_name;
  Alcotest.(check string) "span status" "error" (Model.span_status_to_string (List.hd spans).status);
  Alcotest.(check int) "log count" 1 (List.length logs);
  Alcotest.(check string) "log body" "failed" (List.hd logs).body;
  Alcotest.(check int) "metric count" 1 (List.length metrics);
  Alcotest.(check string) "metric name" "requests.total" (List.hd metrics).name;
  Alcotest.(check string) "metric value" "3" (List.hd metrics).value

(* [page_items] unwraps a keyset page: store tests assert on the rows, while
   the pagination tests below assert on the cursor itself. *)
let page_items (page : 'a Store.page) = page.items

let all_window = Model.window_all

let test_span ?(trace_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    ?(span_id = "bbbbbbbbbbbbbbbb") ?(parent_span_id = None) ?(service_name = "svc")
    ?(operation_name = "root") ?(status = "ok") ?(attributes = [])
    ?(timestamp_ms = base_time) () =
  {
    Model.trace_id;
    span_id;
    parent_span_id;
    service_name;
    scope_name = Some "scope";
    operation_name;
    kind = Some Model.Server;
    start_time_ns = timestamp_ms * 1_000_000;
    end_time_ns = (timestamp_ms * 1_000_000) + 1_000_000;
    duration_ms = 1.0;
    status = Option.value (Model.span_status_of_string status) ~default:Model.Unset;
    status_message = None;
    attributes = List.map (fun (key, value) -> (key, `String value)) attributes;
    resource = [ ("service.name", `String service_name) ];
    events = [];
    links = [];
  }

let test_log ?(service_name = "svc") ?(body = "failed") ?(timestamp_ms = base_time)
    ?(attributes = []) ?(resource = [ ("service.name", "svc") ]) () =
  {
    Model.id = "";
    trace_id = None;
    span_id = None;
    service_name;
    scope_name = Some "scope";
    severity_text = "ERROR";
    severity_number = Some 17;
    timestamp_ns = timestamp_ms * 1_000_000;
    observed_timestamp_ns = None;
    body;
    attributes = List.map (fun (key, value) -> (key, `String value)) attributes;
    resource = List.map (fun (key, value) -> (key, `String value)) resource;
  }

let test_metric ?(service_name = "svc") ?(name = "requests.total")
    ?(timestamp_ms = base_time) ?(attributes = [ ("route", "/users") ]) () =
  {
    Model.service_name;
    scope_name = Some "scope";
    name;
    description = None;
    unit_ = None;
    kind = "sum";
    start_time_ns = Some (base_time * 1_000_000);
    timestamp_ns = timestamp_ms * 1_000_000;
    value = "3";
    attributes = List.map (fun (key, value) -> (key, `String value)) attributes;
    resource = [ ("service.name", `String service_name) ];
    raw_json = `Assoc [];
  }

(* Store helpers --------------------------------------------------------- *)

let temp_state_dir ~(caps : < Ox_caps.Cap.tmp ; .. >) () =
  Ox_caps.Cap_stdlib.Filename.temp_dir ~caps "inn-test-" ""

let test_config ?(port = Config.default_port) ?(max_db_size_mb = 1024) state_dir =
  {
    Config.state_dir;
    data_dir = Filename.concat state_dir "segments";
    host = "127.0.0.1";
    port;
    base_url = Printf.sprintf "http://127.0.0.1:%d" port;
    max_db_size_mb;
  }

let temp_config ~(caps : < Ox_caps.Cap.tmp ; .. >) ?port ?max_db_size_mb () =
  test_config ?port ?max_db_size_mb ((temp_state_dir ~caps) ())

let segment_file config slot =
  Filename.concat config.Config.data_dir (Printf.sprintf "segment-%d.sqlite" slot)

let rec remove_tree ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; .. >) path =
  if Sys.is_directory path then (
    Array.iter
      (fun name -> remove_tree ~caps (Filename.concat path name))
      (Ox_caps.Cap_sys.readdir ~caps path);
    Ox_caps.Cap_sys.rmdir ~caps path)
  else Ox_caps.Cap_sys.remove ~caps path

let cleanup_config ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; .. >) config =
  if Sys.file_exists config.Config.state_dir then remove_tree ~caps config.Config.state_dir

let active_store_switch = ref None
let active_mono_clock = ref None

let run_store_scope f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let previous = !active_store_switch in
  let previous_clock = !active_mono_clock in
  active_store_switch := Some sw;
  active_mono_clock := Some (Eio.Stdenv.mono_clock env);
  Fun.protect
    ~finally:(fun () ->
      active_store_switch := previous;
      active_mono_clock := previous_clock)
    f

(* Seconds since [started] on the monotonic clock of the current store scope. *)
let elapsed_seconds started =
  match !active_mono_clock with
  | Some clock ->
      Mtime.Span.to_float_ns (Mtime.span started (Eio.Time.Mono.now clock)) /. 1e9
  | None -> Alcotest.fail "no store scope"

let mono_now () =
  match !active_mono_clock with
  | Some clock -> Eio.Time.Mono.now clock
  | None -> Alcotest.fail "no store scope"

let run_store program =
  let run sw =
    match program sw with
    | Ok value -> value
    | Error error -> Alcotest.failf "%a" Store.pp_error error
  in
  match !active_store_switch with
  | Some sw -> run sw
  | None -> Eio_main.run @@ fun _env -> Eio.Switch.run run

let run_store_error program =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  match program sw with
  | Ok _ -> None
  | Error error -> Some (Format.asprintf "%a" Store.pp_error error)

let run_store_in ~sw ~clock:_ program =
  match program sw with
  | Ok value -> value
  | Error error -> Alcotest.failf "%a" Store.pp_error error

let with_store ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; .. >) ?now_ms ?report config f =
  run_store (fun sw -> Store.with_db ~caps ~sw ?now_ms ?report config f)

(* Test-only database probes. The store's public interface cannot produce a
   stale schema version or a foreign database, and it cannot prove that no
   orphaned attribute row is left behind, so these helpers use Ox SQL typed
   builders directly. *)

let pp_pool_error ppf = function
  | `Ox_sql error -> Ox_sql.pp_error ppf error
  | `Pool_shutdown -> Format.pp_print_string ppf "pool shutdown"
  | `Timeout -> Format.pp_print_string ppf "timeout"

module Test_meta = struct
  module T = Ox_sql.Table.Make (struct
    let name = "inn_meta"
  end)

  include T

  let key = column "key" Ox_sql.text
  let value = column "value" Ox_sql.text
end

let run_test_db ~(caps : < Ox_caps.Cap.time ; .. >) path program =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let ( let* ) = Result.bind in
  let program =
    let* pool =
      Ox_sql.Pool.create ~caps
        ~sw ~default_timeout:(Ox.Duration.seconds 5)
        (Ox_sql.Sqlite.default_config path)
    in
    let* value = program pool in
    let* () = Ox_sql.Pool.shutdown pool in
    Result.ok value
  in
  match program with
  | Ok value -> value
  | Error error -> Alcotest.failf "%a" pp_pool_error error

let write_schema_version ~(caps : < Ox_caps.Cap.time ; .. >) path version =
  (run_test_db ~caps) path (fun pool ->
      let ( let* ) = Result.bind in
      let update =
        Ox_sql.Update.(
          table Test_meta.table
          |> set Test_meta.value version
          |> where Ox_sql.Expr.(eq Test_meta.key "schema_version")
          |> compile)
      in
      let* _ = Ox_sql.Pool.Typed.execute_compiled pool update in
      Result.ok ())

(* Server helpers -------------------------------------------------------- *)

let run_server_effect program =
  match program with
  | Ok value -> value
  | Error error -> Alcotest.failf "%a" Ox_http.Server.Error.pp error

let request ?(method_ = "GET") ?(target = "/health") ?(body = "")
    ?(headers = Ox_http.Header.empty) () =
  let path, query = Ox_http.Server.Request.split_target target in
  let body =
    if String.equal body "" then Ox_http.Server.Body.empty ()
    else
      let chunks = ref [ Bytes.of_string body ] in
      Ox_http.Server.Body.of_reader (fun () ->
          match !chunks with
          | [] -> Result.ok None
          | chunk :: rest ->
              chunks := rest;
              Result.ok (Some chunk))
  in
  {
    Ox_http.Server.Request.id = lazy "req-test";
    version = Ox_http.Version.H1_1;
    scheme = "http";
    authority = Some "127.0.0.1";
    method_;
    target;
    path;
    query;
    headers;
    body;
    trailers = (fun () -> Result.ok Ox_http.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 43123 };
    tls = false;
    alpn_protocol = Some "http/1.1";
    stream_id = None;
    connection_id = "conn-test";
  }

let response_body_string response =
  match Ox_http.Server.Response.body response with
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

(* Schema ---------------------------------------------------------------- *)

(* Recorded together with [Store.schema_version]: change one and you must
   change the other (schm-hnis). *)
let recorded_schema_fingerprint = "639aa55284b5bcc1b16037fa9e6391d1"

let test_schema_fingerprint_matches_version () =
  Alcotest.(check int) "schema version" 7 Store.schema_version;
  Alcotest.(check string)
    "schema fingerprint (schm-hnis)" recorded_schema_fingerprint
    Store.schema_fingerprint

let test_schema_reopen_keeps_data ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  (with_store ~caps) config (fun store ->
      let ( let* ) = Result.bind in
      let* _ = Store.ingest_traces store [ test_span () ] in
      let* _ = Store.ingest_logs store [ test_log () ] in
      Result.ok ());
  let stats =
    (with_store ~caps) config (fun store ->
        let ( let* ) = Result.bind in
        let* _ = Store.ingest_metrics store [ test_metric () ] in
        Store.stats store)
  in
  Alcotest.(check int) "traces kept (schm-ld81)" 1 stats.Model.traces;
  Alcotest.(check int) "spans kept (schm-ld81)" 1 stats.Model.spans;
  Alcotest.(check int) "logs kept (schm-ld81)" 1 stats.Model.logs;
  Alcotest.(check int) "metrics kept (schm-ld81)" 1 stats.Model.metric_points

let test_schema_mismatch_recreates_database ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  (with_store ~caps) config (fun store ->
      let ( let* ) = Result.bind in
      let* _ = Store.ingest_logs store [ test_log () ] in
      Result.ok ());
  (write_schema_version ~caps) (segment_file config 0) "0";
  (* A file that is not SQLite at all is replaced the same way. *)
  let channel = Ox_caps.Cap_stdlib.open_out_bin ~caps (segment_file config 1) in
  output_string channel "not a database\n";
  close_out channel;
  let messages = ref [] in
  let stats, ingested =
    (with_store ~caps)
      ~report:(fun message -> messages := message :: !messages)
      config
      (fun store ->
        let ( let* ) = Result.bind in
        let* stats = Store.stats store in
        let* ingested = Store.ingest_logs store [ test_log ~body:"fresh" () ] in
        Result.ok (stats, ingested))
  in
  Alcotest.(check int) "old data is gone (schm-s13e)" 0 stats.Model.logs;
  Alcotest.(check int) "store works after recreate (schm-s13e)" 1 ingested;
  match List.rev !messages with
  | [ stale; foreign ] ->
      Alcotest.(check bool)
        "warning names the old version (schm-s52b)" true
        (contains stale "schema version 0");
      Alcotest.(check bool)
        "warning names the new version (schm-s52b)" true
        (contains stale (string_of_int Store.schema_version));
      Alcotest.(check bool)
        "warning names the segment path (schm-s52b)" true
        (contains stale (segment_file config 0));
      Alcotest.(check bool)
        "the non-SQLite segment is replaced (bcache-f1le)" true
        (contains foreign (segment_file config 1))
  | messages ->
      Alcotest.failf "expected two segment warnings, got %d" (List.length messages)

(* Store ----------------------------------------------------------------- *)

let test_store_ingests_and_queries_all_signals ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  let spans =
    match Otlp.decode_traces_json trace_fixture with
    | Ok decoded -> decoded.items
    | Error message -> Alcotest.fail message
  in
  let logs =
    match Otlp.decode_logs_json log_fixture with
    | Ok decoded -> decoded.items
    | Error message -> Alcotest.fail message
  in
  let metrics =
    match Otlp.decode_metrics_json metric_fixture with
    | Ok decoded -> decoded.items
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
    let ( let* ) = Result.bind in
    (fun sw -> Store.with_db ~caps ~sw config (fun store ->
        let* inserted_spans = Store.ingest_traces store spans in
        let* inserted_logs = Store.ingest_logs store logs in
        let* inserted_metrics = Store.ingest_metrics store metrics in
        let* services = Store.list_services store in
        let* summaries =
          Store.list_trace_summaries ~service:"svc" ~window:all_window ~limit:100
            store
          |> Result.map page_items
        in
        let* trace = Store.get_trace store "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" in
        let* span = Store.get_span store "bbbbbbbbbbbbbbbb" in
        let* trace_spans =
          Store.list_trace_spans store ~window:all_window ~limit:100
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          |> Result.map page_items
        in
        let* trace_logs =
          Store.list_trace_logs store ~window:all_window ~limit:100
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          |> Result.map page_items
        in
        let* span_logs =
          Store.list_span_logs store ~window:all_window ~limit:100
            "bbbbbbbbbbbbbbbb"
          |> Result.map page_items
        in
        let* searched_spans =
          Store.search_spans
            {
              service = Some "svc";
              trace_id = None;
              operation = Some "root";
              parent_operation = None;
              status = Some "error";
              attrs = [ ("route", "/users") ];
              window = all_window;
              cursor = None;
              limit = 10;
            }
            store
          |> Result.map page_items
        in
        let* searched_traces =
          Store.search_traces
            {
              service = Some "svc";
              operation = Some "root";
              status = Some "error";
              attrs = [ ("route", "/users") ];
              window = all_window;
              cursor = None;
              limit = 10;
            }
            store
          |> Result.map page_items
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
              window = all_window;
              cursor = None;
              limit = 10;
            }
            store
          |> Result.map page_items
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
              window = all_window;
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
              window = all_window;
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
              window = all_window;
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
              window = all_window;
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
              window = all_window;
              cursor = None;
              limit = 10;
            }
            store
          |> Result.map page_items
        in
        let* read_metrics =
          Store.list_metric_points
            {
              service = Some "svc";
              name = Some "requests.total";
              window = all_window;
              cursor = None;
              limit = 10;
            }
            store
          |> Result.map page_items
        in
        let* stats = Store.stats store in
        Result.ok
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
            stats )))
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
  Alcotest.(check int) "stats services" 1 stats.services;
  Alcotest.(check int)
    "stats expose the budget (bcache-s7at)" (1024 * 1024 * 1024)
    stats.storage.max_bytes;
  Alcotest.(check bool)
    "stats expose the bytes in use (bcache-s7at)" true
    (stats.storage.used_bytes > 0);
  Alcotest.(check int)
    "one segment holds data (bcache-s7at)" 1
    (List.length stats.storage.segments);
  Alcotest.(check int)
    "no failed ingest batch (bcache-s7at)" 0 stats.storage.ingest_failures

(* Segments -------------------------------------------------------------- *)

let log_search ?body () : Store.log_search_filter =
  {
    service = None;
    trace_id = None;
    span_id = None;
    severity = None;
    body;
    attrs = [];
    window = all_window;
    cursor = None;
    limit = 10;
  }

let numbered_body index = Printf.sprintf "log %06d " index ^ String.make 6000 'x'

let ingest_numbered_logs store ~first ~count =
  let ( let* ) = Result.bind in
  let rec loop index =
    if index >= first + count then Ok ()
    else
      let batch =
        List.init 10 (fun k ->
            test_log ~body:(numbered_body (index + k))
              ~timestamp_ms:(base_time + index + k) ())
      in
      let* _ = Store.ingest_logs store batch in
      loop (index + 10)
  in
  loop first

let test_segments_keep_the_newest ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* bcache-r1ng, bcache-c4p7, bcache-f1le: an 8 MB budget gives 1 MiB
     segments; 3000 logs of about 6 KB fill the ring more than twice. *)
  let config = (temp_config ~caps) ~max_db_size_mb:8 () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  let total = 3000 in
  let storage, newest, oldest, kept =
    (with_store ~caps) config (fun store ->
        let ( let* ) = Result.bind in
        let* () = ingest_numbered_logs store ~first:0 ~count:total in
        let* storage = Store.storage store in
        let search text =
          Store.search_logs (log_search ~body:text ()) store |> Result.map page_items
        in
        let* newest = search (Printf.sprintf "log %06d " (total - 1)) in
        let* oldest = search "log 000000 " in
        let* stats = Store.stats store in
        Result.ok (storage, newest, oldest, stats.Model.logs))
  in
  Alcotest.(check int) "the newest log is kept (bcache-r1ng)" 1 (List.length newest);
  Alcotest.(check int) "the oldest log is gone (bcache-r1ng)" 0 (List.length oldest);
  Alcotest.(check bool) "some logs went with whole segments (bcache-f1le)" true
    (kept > 0 && kept < total);
  Alcotest.(check int) "every slot holds data after the ring wrapped"
    Store.segment_count (List.length storage.Model.segments);
  Alcotest.(check bool)
    (Printf.sprintf "the store stays near its budget (bcache-c4p7): %d of %d bytes"
       storage.used_bytes storage.max_bytes)
    true
    (storage.used_bytes <= storage.max_bytes + (storage.max_bytes / 10));
  Alcotest.(check int) "no failed batch" 0 storage.ingest_failures;
  (* The data survives a restart, and the ring continues where it stopped. *)
  let reopened, newest_after_reopen =
    (with_store ~caps) config (fun store ->
        let ( let* ) = Result.bind in
        let* () = ingest_numbered_logs store ~first:total ~count:10 in
        let* storage = Store.storage store in
        let* newest =
          Store.search_logs
            (log_search ~body:(Printf.sprintf "log %06d " (total + 9)) ())
            store
          |> Result.map page_items
        in
        Result.ok (storage, newest))
  in
  Alcotest.(check int) "a write after reopen is found" 1
    (List.length newest_after_reopen);
  let max_sequence segments =
    List.fold_left
      (fun acc (segment : Model.segment_stats) -> max acc segment.sequence)
      0 segments
  in
  Alcotest.(check bool) "the ring keeps its order across a restart" true
    (max_sequence reopened.Model.segments >= max_sequence storage.segments)

let test_trace_across_segments ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* bcache-f1le: the reader combines the parts of one trace from two
     segments into one summary and one tree. *)
  let config = (temp_config ~caps) ~max_db_size_mb:8 () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  let trace_id = "abababababababababababababababab" in
  let root = test_span ~trace_id ~span_id:"1000000000000001" ~operation_name:"root" () in
  let child =
    test_span ~trace_id ~span_id:"1000000000000002"
      ~parent_span_id:(Some "1000000000000001") ~service_name:"worker"
      ~operation_name:"child" ~status:"error" ~timestamp_ms:(base_time + 5) ()
  in
  let summary, trace, before, after, by_service =
    (with_store ~caps) config (fun store ->
        let ( let* ) = Result.bind in
        let* _ = Store.ingest_traces store [ root ] in
        let* before = Store.storage store in
        let* () = ingest_numbered_logs store ~first:0 ~count:300 in
        let* after = Store.storage store in
        let* _ = Store.ingest_traces store [ child ] in
        let* page = Store.list_trace_summaries ~window:all_window ~limit:10 store in
        let* by_service =
          Store.list_trace_summaries ~service:"worker" ~window:all_window ~limit:10 store
        in
        let* trace = Store.get_trace store trace_id in
        Result.ok (page_items page, trace, before, after, page_items by_service))
  in
  let active (storage : Model.storage_stats) =
    List.find (fun (segment : Model.segment_stats) -> segment.active) storage.segments
  in
  Alcotest.(check bool) "the logs moved the writer to another segment" true
    ((active before).slot <> (active after).slot);
  (match summary with
  | [ summary ] ->
      Alcotest.(check int) "one summary counts both parts" 2 summary.Model.span_count;
      Alcotest.(check int) "errors from the second part" 1 summary.error_count;
      Alcotest.(check string) "the root comes from the first part" "root"
        summary.root_operation_name
  | summaries -> Alcotest.failf "expected one trace summary, got %d" (List.length summaries));
  Alcotest.(check int) "a child service finds the trace" 1 (List.length by_service);
  match trace with
  | Some trace ->
      Alcotest.(check (list string)) "the tree joins both segments"
        [ "root"; "child" ]
        (List.map (fun (node : Model.span_node) -> node.span.operation_name) trace.spans);
      Alcotest.(check (list string)) "the detail has no warning" [] trace.warnings
  | None -> Alcotest.fail "the trace was not found"

let test_ingest_limits ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* bcache-t8nc, bcache-a1x1, bcache-s5kc. *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  let large = String.make 5000 'u' in
  let span =
    test_span ~trace_id:"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" ~span_id:"2000000000000001"
      ~attributes:[ ("universe", large); ("session", "s-1") ] ()
  in
  let log = test_log ~body:(String.make 20_000 'b') () in
  let busy_trace = "efefefefefefefefefefefefefefefef" in
  let busy_spans =
    List.init (Store.max_trace_spans_per_segment + 10) (fun index ->
        test_span ~trace_id:busy_trace ~span_id:(Printf.sprintf "%016x" (index + 1))
          ~timestamp_ms:(base_time + index) ())
  in
  let rec batches = function
    | [] -> []
    | spans ->
        let rec take count acc = function
          | rest when count = 0 -> (List.rev acc, rest)
          | [] -> (List.rev acc, [])
          | span :: rest -> take (count - 1) (span :: acc) rest
        in
        let batch, rest = take 1000 [] spans in
        batch :: batches rest
  in
  let stored_span, stored_log, by_short, by_long, busy, kept =
    (with_store ~caps) config (fun store ->
        let ( let* ) = Result.bind in
        let* _ = Store.ingest_traces store [ span ] in
        let* _ = Store.ingest_logs store [ log ] in
        let* kept =
          List.fold_left
            (fun total batch ->
              let* total = total in
              let* count = Store.ingest_traces store batch in
              Result.ok (total + count))
            (Result.ok 0) (batches busy_spans)
        in
        let* stored_span = Store.get_span store span.span_id in
        let* logs = Store.search_logs (log_search ()) store in
        let search attrs : Store.span_search_filter =
          { service = None; trace_id = None; operation = None; parent_operation = None;
            status = None; attrs; window = all_window; cursor = None; limit = 10 }
        in
        let* by_short = Store.search_spans (search [ ("session", "s-1") ]) store in
        let* by_long =
          Store.search_spans
            (search [ ("universe", String.make Ingest_limits.max_attribute_bytes 'u') ])
            store
        in
        let* busy = Store.get_trace store busy_trace in
        Result.ok (stored_span, page_items logs, page_items by_short, page_items by_long, busy, kept))
  in
  (match stored_span with
  | Some stored ->
      Alcotest.(check (option int)) "a long attribute is cut to 1 KB (bcache-t8nc)"
        (Some Ingest_limits.max_attribute_bytes)
        (match List.assoc_opt "universe" stored.Model.attributes with
        | Some (`String value) -> Some (String.length value)
        | _ -> None);
      Alcotest.(check bool) "the span is marked (bcache-t8nc)" true
        (List.assoc_opt Ingest_limits.truncated_key stored.attributes = Some (`Bool true))
  | None -> Alcotest.fail "the span was not stored");
  (match stored_log with
  | [ log ] ->
      Alcotest.(check int) "a long body is cut to 8 KB (bcache-t8nc)"
        Ingest_limits.max_text_bytes (String.length log.Model.body);
      Alcotest.(check bool) "the log is marked (bcache-t8nc)" true
        (List.assoc_opt Ingest_limits.truncated_key log.attributes = Some (`Bool true))
  | logs -> Alcotest.failf "expected one log, got %d" (List.length logs));
  Alcotest.(check int) "a short value is searchable (bcache-a1x1)" 1 (List.length by_short);
  Alcotest.(check int) "a long value is not indexed (bcache-a1x1)" 0 (List.length by_long);
  Alcotest.(check int) "the span cap keeps 5000 spans of one trace (bcache-s5kc)"
    Store.max_trace_spans_per_segment kept;
  match busy with
  | Some trace ->
      Alcotest.(check int) "the summary counts the kept spans"
        Store.max_trace_spans_per_segment trace.Model.summary.span_count;
      Alcotest.(check int) "the summary counts the dropped spans (bcache-s5kc)" 10
        trace.summary.dropped_span_count
  | None -> Alcotest.fail "the busy trace was not found"

let test_server_handler_ingests_and_queries_services ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw config) in
  Fun.protect
    ~finally:(fun () -> run_store (fun _sw -> Store.close store))
    (fun () ->
      let ingest =
        run_server_effect
          (Inn.Server.handler config store
             (request ~method_:"POST" ~target:"/v1/traces" ~body:trace_fixture ()))
      in
      Alcotest.(check int)
        "ingest status" 200 (Ox_http.Server.Response.status ingest);
      Alcotest.(check string)
        "ingest body" "{}\n" (response_body_string ingest);
      let ingest_ai =
        run_server_effect
          (Inn.Server.handler config store
             (request ~method_:"POST" ~target:"/v1/traces" ~body:ai_trace_fixture ()))
      in
      Alcotest.(check int)
        "ingest ai status" 200 (Ox_http.Server.Response.status ingest_ai);
      let ingest_logs =
        run_server_effect
          (Inn.Server.handler config store
             (request ~method_:"POST" ~target:"/v1/logs" ~body:log_fixture ()))
      in
      Alcotest.(check int)
        "ingest logs status" 200 (Ox_http.Server.Response.status ingest_logs);
      let services =
        run_server_effect
          (Inn.Server.handler config store (request ~target:"/services" ()))
      in
      Alcotest.(check int)
        "services status" 200 (Ox_http.Server.Response.status services);
      Alcotest.(check int)
        "services length" 1 (services |> response_json |> json_list_length "services");
      Alcotest.(check string)
        "services meta lookback (win-3ghy)" "all"
        (services |> response_json
        |> fun json -> Yojson.Safe.Util.(json |> member "meta" |> member "lookback" |> to_string));
      let span =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/spans/bbbbbbbbbbbbbbbb" ()))
      in
      Alcotest.(check int)
        "span status" 200 (Ox_http.Server.Response.status span);
      Alcotest.(check string)
        "span id" "bbbbbbbbbbbbbbbb"
        (span |> response_json |> json_string_field "spanId");
      let trace_spans =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:
                  "/traces/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/spans?lookback=all" ()))
      in
      Alcotest.(check int)
        "trace spans status" 200 (Ox_http.Server.Response.status trace_spans);
      Alcotest.(check int)
        "trace spans length" 1
        (trace_spans |> response_json |> json_list_length "spans");
      let trace_logs =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:
                  "/api/traces/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/logs?lookback=all" ()))
      in
      Alcotest.(check int)
        "trace logs status" 200 (Ox_http.Server.Response.status trace_logs);
      Alcotest.(check int)
        "trace logs length" 1
        (trace_logs |> response_json |> json_list_length "logs");
      let span_logs =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/spans/bbbbbbbbbbbbbbbb/logs?lookback=all" ()))
      in
      Alcotest.(check int)
        "span logs status" 200 (Ox_http.Server.Response.status span_logs);
      Alcotest.(check int)
        "span logs length" 1
        (span_logs |> response_json |> json_list_length "logs");
      let searched_spans =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:
                  "/spans/search?service=svc&operation=root&status=error&attr.route=%2Fusers&lookback=all"
                ()))
      in
      Alcotest.(check int)
        "search spans status" 200
        (Ox_http.Server.Response.status searched_spans);
      Alcotest.(check int)
        "search spans length" 1
        (searched_spans |> response_json |> json_list_length "spans");
      let searched_traces =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:
                  "/traces/search?service=svc&operation=root&status=error&attr.route=%2Fusers&lookback=all"
                ()))
      in
      Alcotest.(check int)
        "search traces status" 200
        (Ox_http.Server.Response.status searched_traces);
      Alcotest.(check int)
        "search traces length" 1
        (searched_traces |> response_json |> json_list_length "traces");
      let searched_logs =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:
                  "/logs/search?service=svc&body=fail&severity=ERROR&attr.route=%2Fusers&lookback=all"
                ()))
      in
      Alcotest.(check int)
        "search logs status" 200
        (Ox_http.Server.Response.status searched_logs);
      Alcotest.(check int)
        "search logs length" 1
        (searched_logs |> response_json |> json_list_length "logs");
      let trace_stats =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:
                  "/traces/stats?groupBy=operation&agg=count&service=svc&status=error&lookback=all"
                ()))
      in
      Alcotest.(check int)
        "trace stats status" 200 (Ox_http.Server.Response.status trace_stats);
      Alcotest.(check int)
        "trace stats length" 1
        (trace_stats |> response_json |> json_list_length "stats");
      let log_stats =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/logs/stats?groupBy=severity&service=svc&lookback=all" ()))
      in
      Alcotest.(check int)
        "log stats status" 200 (Ox_http.Server.Response.status log_stats);
      Alcotest.(check int)
        "log stats length" 1
        (log_stats |> response_json |> json_list_length "stats");
      let facets =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:
                  "/facets?type=traces&field=attribute_keys&service=svc&lookback=all" ()))
      in
      Alcotest.(check int)
        "facets status" 200 (Ox_http.Server.Response.status facets);
      Alcotest.(check int)
        "facets length" 7
        (facets |> response_json |> json_list_length "facets");
      let endpoints =
        run_server_effect
          (Inn.Server.handler config store (request ~target:"/api/endpoints" ()))
      in
      Alcotest.(check int)
        "endpoints status" 200 (Ox_http.Server.Response.status endpoints);
      Alcotest.(check int)
        "endpoint inventory is present" (List.length Inn.Endpoint.all)
        (endpoints |> response_json |> json_list_length "endpoints");
      let stats =
        run_server_effect
          (Inn.Server.handler config store (request ~target:"/stats" ()))
      in
      Alcotest.(check int)
        "stats status" 200 (Ox_http.Server.Response.status stats);
      Alcotest.(check bool)
        "stats body carries the storage section (bcache-s7at)" true
        (Yojson.Safe.Util.member "storage" (response_json stats) <> `Null);
      let status =
        run_server_effect
          (Inn.Server.handler config store (request ~target:"/status" ()))
      in
      Alcotest.(check int)
        "status status" 200 (Ox_http.Server.Response.status status);
      Alcotest.(check bool)
        "status carries the storage section (bcache-s7at)" true
        (Yojson.Safe.Util.member "storage" (response_json status) <> `Null);
      let instructions =
        run_server_effect
          (Inn.Server.handler config store (request ~target:"/instructions" ()))
      in
      Alcotest.(check int)
        "instructions status" 200
        (Ox_http.Server.Response.status instructions);
      Alcotest.(check bool)
        "instructions body" true
        (String.length (response_body_string instructions) > 0);
      let openapi =
        run_server_effect
          (Inn.Server.handler config store (request ~target:"/openapi.json" ()))
      in
      Alcotest.(check int)
        "openapi status" 200 (Ox_http.Server.Response.status openapi);
      Alcotest.(check string)
        "openapi version" "3.1.0"
        (openapi |> response_json |> json_string_field "openapi"))

(* OTLP/HTTP JSON conformance regression cases. *)
let member field = function
  | `Assoc fields -> Option.value (List.assoc_opt field fields) ~default:`Null
  | _ -> `Null

let test_otlp_conformance_decoder () =
  let payload =
    {|{"resourceSpans":[{"scopeSpans":[{"spans":[{"traceId":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","spanId":"BBBBBBBBBBBBBBBB","name":"short","kind":"SPAN_KIND_CLIENT","startTimeUnixNano":"1000000001","endTimeUnixNano":"1000000501","status":{"code":"STATUS_CODE_OK"},"attributes":[{"key":"count","value":{"intValue":"7"}},{"key":"enabled","value":{"boolValue":true}},{"key":"arr","value":{"arrayValue":{"values":[{"stringValue":"a"},{"intValue":"2"}]}}},{"key":"object","value":{"kvlistValue":{"values":[{"key":"x","value":{"doubleValue":1.25}}]}}}],"links":[{"traceId":"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC","spanId":"DDDDDDDDDDDDDDDD","attributes":[{"key":"weight","value":{"intValue":"3"}}]}]},{"traceId":"00000000000000000000000000000000","spanId":"bbbbbbbbbbbbbbbb"},{"traceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","spanId":"bad"}]}]}]}|}
  in
  let decoded = match Otlp.decode_traces_json payload with
    | Ok result -> result | Error message -> Alcotest.fail message in
  Alcotest.(check int) "bad IDs rejected separately (otlp-r73z)" 2 decoded.rejected;
  Alcotest.(check int) "good span retained" 1 (List.length decoded.items);
  let span = List.hd decoded.items in
  Alcotest.(check string) "lowercase ID (otlp-hb7r)"
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" span.Model.trace_id;
  Alcotest.(check string) "Effect kind (otlp-5oj4)" "client"
    (Option.fold ~none:"" ~some:Model.span_kind_to_string span.kind);
  Alcotest.(check string) "explicit OK (otlp-a16d)" "ok"
    (Model.span_status_to_string span.status);
  Alcotest.(check (float 0.00000001)) "500ns duration (otlp-6ul3)"
    0.0005 span.duration_ms;
  Alcotest.(check int) "link (otlp-l0be)" 1 (List.length span.links);
  let attrs = Model.attrs_to_json span.attributes in
  Alcotest.(check bool) "numeric typed (otlp-8avj)" true (member "count" attrs = `Int 7);
  Alcotest.(check bool) "boolean typed" true (member "enabled" attrs = `Bool true);
  Alcotest.(check bool) "array typed" true (member "arr" attrs = `List [`String "a"; `Int 2]);
  Alcotest.(check bool) "object typed" true (member "object" attrs = `Assoc ["x", `Float 1.25]);
  let log_payload = {|{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"timeUnixNano":"0","observedTimeUnixNano":"1234567899","traceId":"","attributes":[{"key":"trace_id","value":{"stringValue":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}},{"key":"spanId","value":{"stringValue":"BBBBBBBBBBBBBBBB"}}]}]}]}]}|} in
  let logs = match Otlp.decode_logs_json log_payload with
    | Ok result -> result.items | Error message -> Alcotest.fail message in
  let log = List.hd logs in
  Alcotest.(check int) "observed fallback (otlp-e9t0)" 1234567899 log.timestamp_ns;
  Alcotest.(check (option string)) "attribute trace (otlp-beaj)"
    (Some "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") log.trace_id;
  Alcotest.(check (option string)) "attribute span (otlp-beaj)"
    (Some "bbbbbbbbbbbbbbbb") log.span_id

let test_otlp_conformance_handler ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw config) in
  let post ?(headers = Ox_http.Header.empty) path body =
    run_server_effect (Inn.Server.handler config store
      (request ~method_:"POST" ~target:path ~body ~headers ())) in
  let get path = run_server_effect
    (Inn.Server.handler config store (request ~target:path ())) |> response_json in
  Fun.protect ~finally:(fun () -> run_store (fun _sw -> Store.close store)) @@ fun () ->
  List.iter (fun path ->
    let response = post path "" in
    Alcotest.(check int) "empty status (otlp-dtfh)" 200 (Ox_http.Server.Response.status response);
    Alcotest.(check bool) "OTLP empty response (otlp-2k5g)" true
      (response_json response = `Assoc [])) ["/v1/traces"; "/v1/logs"; "/v1/metrics"];
  let invalid = post "/v1/traces" "{" in
  Alcotest.(check int) "bad JSON (otlp-qso2)" 400 (Ox_http.Server.Response.status invalid);
  Alcotest.(check bool) "INVALID_ARGUMENT body" true (member "code" (response_json invalid) = `Int 3);
  let headers = Ox_http.Header.unsafe_of_list ["content-type", "application/x-protobuf"] in
  let unsupported = post ~headers "/v1/traces" "{}" in
  Alcotest.(check int) "protobuf rejected (otlp-ohmj)" 415 (Ox_http.Server.Response.status unsupported);
  let oversized = post "/v1/traces" (String.make (32 * 1024 * 1024 + 1) ' ') in
  Alcotest.(check int) "body cap (otlp-ohmj)" 413 (Ox_http.Server.Response.status oversized);
  let payload = {|{"resourceSpans":[{"scopeSpans":[{"spans":[{"traceId":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","spanId":"BBBBBBBBBBBBBBBB","name":"short","kind":2,"startTimeUnixNano":"1000000001","endTimeUnixNano":"1000000501","attributes":[{"key":"count","value":{"intValue":"7"}},{"key":"ai.model.id","value":{"stringValue":"example"}}],"events":[{"name":"instant","timeUnixNano":"1000000002"}],"links":[{"traceId":"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC","spanId":"DDDDDDDDDDDDDDDD","attributes":[{"key":"weight","value":{"intValue":"3"}}]}]},{"traceId":"oops","spanId":"bbbbbbbbbbbbbbbb"}]}]}]}|} in
  let ingested = post "/v1/traces" payload in
  Alcotest.(check int) "partial status (otlp-2k5g)" 200 (Ox_http.Server.Response.status ingested);
  Alcotest.(check bool) "rejectedSpans (otlp-r73z)" true
    (member "rejectedSpans" (member "partialSuccess" (response_json ingested)) = `Int 1);
  let span = get "/api/spans/bbbbbbbbbbbbbbbb" in
  Alcotest.(check bool) "ns output (otlp-l754)" true
    (member "startTimeUnixNano" span = `String "1000000001");
  Alcotest.(check bool) "fractional ms output (otlp-l754)" true
    (member "startTimeMs" span = `Float 1000.000001);
  Alcotest.(check bool) "kind output (otlp-5oj4)" true (member "kind" span = `String "server");
  Alcotest.(check bool) "event ns round trip" true
    (match member "events" span with `List (event :: _) ->
      member "timestampUnixNano" event = `String "1000000002" | _ -> false);
  Alcotest.(check bool) "link typed attrs round trip (otlp-l0be)" true
    (match member "links" span with `List (link :: _) ->
      member "weight" (member "attributes" link) = `Int 3 | _ -> false);
  let found = get "/api/spans/search?status=ok&attr.count=7&lookback=all" in
  Alcotest.(check int) "unset matches ok and numeric attr (otlp-u6rw, otlp-zc8b)"
    1 (json_list_length "spans" found);
  Alcotest.(check int) "trace status ok includes unset (otlp-u6rw)" 1
    (json_list_length "traces" (get "/api/traces/search?status=ok&lookback=all"));
  Alcotest.(check int) "stats status ok includes unset (otlp-u6rw)" 1
    (json_list_length "stats"
      (get "/api/traces/stats?groupBy=operation&agg=count&status=ok&lookback=all"));
  let logs = post "/v1/logs"
    {|{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"timeUnixNano":"0","observedTimeUnixNano":"1000000501","body":{"stringValue":"hello"}}]}]}]}|} in
  Alcotest.(check int) "log ingested" 200 (Ox_http.Server.Response.status logs);
  let logs_json = get "/api/logs?limit=10&lookback=all" in
  let rows = member "logs" logs_json in
  let log = match rows with `List (head :: _) -> head | _ -> Alcotest.fail "missing log" in
  Alcotest.(check bool) "log ns output (otlp-e9t0, otlp-l754)" true
    (member "timestampUnixNano" log = `String "1000000501");
  Alcotest.(check bool) "fractional log ms (otlp-l754)" true
    (member "timestampMs" log = `Float 1000.000501);
  Alcotest.(check bool) "observed log timestamp persisted (otlp-e9t0)" true
    (member "observedTimestampUnixNano" log = `String "1000000501");
  let _ = post "/v1/logs"
    {|{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"ingest fallback"}}]}]}]}|} in
  let fallback = get "/api/logs/search?body=ingest%20fallback&lookback=all" in
  let row = match member "logs" fallback with
    | `List (first :: _) -> first | _ -> Alcotest.fail "missing fallback log" in
  Alcotest.(check bool) "missing log time uses ingest clock (otlp-e9t0)" true
    (match member "timestampUnixNano" row with
     | `String text -> Option.value (int_of_string_opt text) ~default:0 > 0
     | _ -> false);
  let _ = post "/v1/traces"
    {|{"resourceSpans":[{"scopeSpans":[{"spans":[{"traceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","spanId":"eeeeeeeeeeeeeeee","name":"explicit-ok","startTimeUnixNano":"1000000502","endTimeUnixNano":"1000000503","status":{"code":1}}]}]}]}|} in
  let explicit = get "/api/spans/eeeeeeeeeeeeeeee" in
  Alcotest.(check bool) "explicit OK survives storage (otlp-a16d)" true
    (member "status" explicit = `String "ok");
  Alcotest.(check bool) "unspecified kind stays null (otlp-5oj4)" true
    (member "kind" explicit = `Null);
  Alcotest.(check int) "OK filter includes OK and UNSET (otlp-u6rw)" 2
    (json_list_length "spans" (get "/api/spans/search?status=ok&lookback=all"))

let test_otlp_store_retry ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw config) in
  run_store (fun _sw -> Store.close store);
  let response = run_server_effect
    (Inn.Server.handler config store
      (request ~method_:"POST" ~target:"/v1/traces" ~body:trace_fixture ())) in
  Alcotest.(check int) "closed store returns retryable (otlp-2wg5)" 503
    (Ox_http.Server.Response.status response);
  Alcotest.(check bool) "OTLP UNAVAILABLE" true
    (member "code" (response_json response) = `Int 14);
  Alcotest.(check (option string)) "Retry-After" (Some "1")
    (Ox_http.Header.get "retry-after"
      (Ox_http.Server.Response.headers response))

(* Query windows and cursors --------------------------------------------- *)

let json_member name json = Yojson.Safe.Util.member name json

let json_field_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let server_get config store path =
  run_server_effect (Inn.Server.handler config store (request ~target:path ()))

let server_json config store path = server_get config store path |> response_json

let check_invalid_query label response fragment =
  Alcotest.(check int)
    (label ^ " status") 400
    (Ox_http.Server.Response.status response);
  let json = response_json response in
  Alcotest.(check string)
    (label ^ " code") "invalid_query" (json_string_field "error" json);
  let message = json_string_field "message" json in
  Alcotest.(check bool)
    (label ^ " explains " ^ fragment) true (contains message fragment)

let test_list_policy_lookback () =
  (* win-nzur, win-e7k8, win-m4ld, win-xl30 *)
  let check_ok text ms =
    match List_policy.parse_lookback text with
    | Ok lookback ->
        Alcotest.(check (option int)) text ms lookback.List_policy.ms
    | Error message -> Alcotest.failf "%s: %s" text message
  in
  check_ok "15m" (Some (15 * 60_000));
  check_ok "2h" (Some (2 * 3_600_000));
  check_ok "1d" (Some (24 * 3_600_000));
  check_ok " all " None;
  List.iter
    (fun text ->
      match List_policy.parse_lookback text with
      | Ok _ -> Alcotest.failf "%S must be rejected (win-xl30)" text
      | Error message ->
          Alcotest.(check bool)
            (Printf.sprintf "%S names the grammar" text) true
            (contains message "lookback"))
    [
      "";
      "15";
      "m";
      "0m";
      "-5m";
      "1w";
      "1h30m";
      "1.5h";
      "15 m";
      "alll";
      "999999999999999999999h";
    ];
  (match List_policy.parse_lookback "1h" with
  | Ok lookback ->
      let window = List_policy.resolve ~now_ms:base_time lookback in
      Alcotest.(check (option int))
        "window start (win-nzur)" (Some (base_time - hour_ms))
        window.Model.start_ms
  | Error message -> Alcotest.fail message);
  (match List_policy.parse_lookback "all" with
  | Ok lookback ->
      let window = List_policy.resolve ~now_ms:base_time lookback in
      Alcotest.(check (option int))
        "all is the whole history (win-m4ld)" None window.Model.start_ms
  | Error message -> Alcotest.fail message)

let test_list_policy_limit_and_defaults () =
  (* win-e7k8, win-jee9, win-3ghy, win-xl30 *)
  (match
     List_policy.list_request ~kind:List_policy.Trace ~now_ms:base_time
       [ ("limit", "10") ]
   with
  | Ok policy ->
      Alcotest.(check int) "limit" 10 policy.List_policy.limit;
      Alcotest.(check string)
        "lists default to one hour (win-e7k8)" "1h" policy.List_policy.lookback;
      Alcotest.(check (option int))
        "default window start" (Some (base_time - hour_ms))
        policy.window.Model.start_ms
  | Error message -> Alcotest.fail message);
  (match List_policy.summary_request ~now_ms:base_time [] with
  | Ok policy ->
      Alcotest.(check string)
        "stats default to the whole history (win-jee9)" "all"
        policy.List_policy.lookback;
      Alcotest.(check int) "stats limit default" 20 policy.limit;
      Alcotest.(check (option int))
        "stats window is unbounded" None policy.window.Model.start_ms
  | Error message -> Alcotest.fail message);
  (match List_policy.resolve_lookback ~now_ms:base_time [] with
  | Ok (window, lookback) ->
      Alcotest.(check string)
        "services default to the whole history (win-3ghy)" "all" lookback;
      Alcotest.(check (option int)) "services window" None window.Model.start_ms
  | Error message -> Alcotest.fail message);
  List.iter
    (fun value ->
      match
        List_policy.list_request ~kind:List_policy.Log ~now_ms:base_time
          [ ("limit", value) ]
      with
      | Ok _ -> Alcotest.failf "limit %S must be rejected" value
      | Error message ->
          Alcotest.(check bool)
            (Printf.sprintf "limit %S names the range" value) true
            (contains message "limit"))
    [ "0"; "-1"; "10001"; "many"; "" ];
  (match
     List_policy.list_request ~kind:List_policy.Trace ~now_ms:base_time
       [ ("lookback", "1w") ]
   with
  | Ok _ -> Alcotest.fail "lookback=1w must be rejected (win-xl30)"
  | Error message ->
      Alcotest.(check bool)
        "invalid lookback is explained (win-xl30)" true
        (contains message "lookback"))

let test_list_policy_cursor () =
  (* win-edze, win-7xet, win-xl30 *)
  let position = { Model.sort_key_ns = 1234; tie_breaker = "log-1" } in
  let window = Model.window_lookback ~now_ms:base_time ~ms:hour_ms in
  let token =
    List_policy.encode_cursor ~kind:List_policy.Log ~window ~lookback:"1h"
      position
  in
  Alcotest.(check bool)
    "the token is opaque" true
    (not (String.contains token (Char.chr 123))
    && not (String.contains token (Char.chr 61)));
  (match List_policy.decode_cursor ~kind:List_policy.Log token with
  | Ok cursor ->
      Alcotest.(check string) "kind" "log"
        (List_policy.kind_to_string cursor.List_policy.cursor_kind);
      Alcotest.(check int)
        "sort key" 1234 cursor.cursor_position.Model.sort_key_ns;
      Alcotest.(check string)
        "tie breaker" "log-1" cursor.cursor_position.Model.tie_breaker;
      Alcotest.(check string) "lookback label" "1h" cursor.cursor_lookback;
      Alcotest.(check (option int))
        "window start" (Some (base_time - hour_ms))
        cursor.cursor_window.Model.start_ms
  | Error message -> Alcotest.fail message);
  (match List_policy.decode_cursor ~kind:List_policy.Trace token with
  | Ok _ -> Alcotest.fail "a log cursor is not a trace cursor (win-xl30)"
  | Error message ->
      Alcotest.(check bool)
        "the wrong-kind error names both kinds (win-xl30)" true
        (contains message "log" && contains message "trace"));
  List.iter
    (fun garbage ->
      match List_policy.decode_cursor ~kind:List_policy.Log garbage with
      | Ok _ -> Alcotest.failf "%S must be rejected (win-xl30)" garbage
      | Error message ->
          Alcotest.(check bool)
            (Printf.sprintf "%S is explained" garbage) true
            (contains message "cursor"))
    [ "not-a-cursor"; "AAAA"; "eyJ4IjoxfQ"; ""; "!!!!"; "="; "abc" ];
  (* A cursor pins the page-one window, so later pages cannot drift. *)
  (match
     List_policy.list_request ~kind:List_policy.Log
       ~now_ms:(base_time + (10 * hour_ms))
       [ ("cursor", token); ("lookback", "5m") ]
   with
  | Ok policy ->
      Alcotest.(check (option int))
        "later pages reuse the page-one window (win-edze)"
        (Some (base_time - hour_ms)) policy.List_policy.window.Model.start_ms;
      Alcotest.(check string)
        "meta lookback follows the cursor" "1h" policy.lookback;
      Alcotest.(check (option int))
        "cursor position" (Some 1234)
        (Option.map (fun position -> position.Model.sort_key_ns) policy.cursor)
  | Error message -> Alcotest.fail message)

let test_query_windows ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* win-nzur, win-e7k8, win-m4ld, win-jee9, win-3ghy, win-xl30 *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw ~now_ms:(fun () -> base_time) config) in
  Fun.protect
    ~finally:(fun () -> run_store (fun _sw -> Store.close store))
    (fun () ->
      let ages = [ ("now", 0); ("30m", 30); ("2h", 120); ("3d", 3 * 24 * 60) ] in
      let spans =
        List.mapi
          (fun index (label, minutes) ->
            test_span
              ~trace_id:(Printf.sprintf "%032x" (index + 1))
              ~span_id:(Printf.sprintf "%016x" (index + 1))
              ~service_name:("span-" ^ label)
              ~timestamp_ms:(base_time - (minutes * 60_000)) ())
          ages
      in
      let logs =
        List.map
          (fun (label, minutes) ->
            test_log ~service_name:("log-" ^ label) ~body:("body-" ^ label)
              ~timestamp_ms:(base_time - (minutes * 60_000)) ())
          ages
      in
      let metrics =
        List.map
          (fun (label, minutes) ->
            test_metric ~service_name:("metric-" ^ label)
              ~timestamp_ms:(base_time - (minutes * 60_000)) ())
          ages
      in
      ignore
        (run_store
           (fun _sw -> let ( let* ) = Result.bind in
            let* _ = Store.ingest_traces store spans in
            let* _ = Store.ingest_logs store logs in
            let* _ = Store.ingest_metrics store metrics in
            Result.ok ()));
      let count path name =
        json_list_length name (server_json config store path)
      in
      Alcotest.(check int)
        "lists default to one hour (win-e7k8)" 2 (count "/traces" "traces");
      Alcotest.(check int)
        "lookback=15m narrows the window (win-nzur)" 1
        (count "/traces?lookback=15m" "traces");
      Alcotest.(check int)
        "lookback=2h widens the window (win-nzur)" 3
        (count "/traces?lookback=2h" "traces");
      Alcotest.(check int)
        "lookback=1d covers three days (win-nzur)" 3
        (count "/traces?lookback=1d" "traces");
      Alcotest.(check int)
        "lookback=all is the whole retained history (win-m4ld)" 4
        (count "/traces?lookback=all" "traces");
      Alcotest.(check int)
        "logs default to one hour (win-e7k8)" 2 (count "/logs" "logs");
      Alcotest.(check int)
        "logs honour lookback=all (win-m4ld)" 4
        (count "/logs?lookback=all" "logs");
      Alcotest.(check int)
        "metrics default to one hour (win-e7k8)" 2 (count "/metrics" "metrics");
      Alcotest.(check int)
        "metrics honour lookback=all (win-m4ld)" 4
        (count "/metrics?lookback=all" "metrics");
      Alcotest.(check int)
        "services default to the whole history (win-3ghy, acc-itfo)" 8
        (count "/services" "services");
      Alcotest.(check int)
        "services accept a window (win-3ghy, acc-itfo)" 4
        (count "/services?lookback=1h" "services");
      Alcotest.(check int)
        "facet queries default to the whole history (win-jee9)" 4
        (count "/facets?type=logs&field=service" "facets");
      Alcotest.(check int)
        "facet queries accept a window (win-jee9)" 2
        (count "/facets?type=logs&field=service&lookback=1h" "facets");
      Alcotest.(check int)
        "stats queries default to the whole history (win-jee9)" 4
        (count "/logs/stats?groupBy=service" "stats");
      Alcotest.(check int)
        "stats queries accept a window (win-jee9)" 2
        (count "/logs/stats?groupBy=service&lookback=1h" "stats");
      Alcotest.(check int)
        "trace stats default to the whole history (win-jee9)" 4
        (count "/traces/stats?groupBy=service&agg=count" "stats");
      (match server_json config store "/stats" with
      | json ->
          Alcotest.(check bool)
            "store stats count the whole history (win-jee9)" true
            (json_member "logs" json = `Int 4);
          Alcotest.(check string)
            "store stats report the effective lookback" "all"
            (match json_member "lookback" (json_member "meta" json) with
            | `String value -> value
            | _ -> ""));
      (match server_json config store "/stats?lookback=1h" with
      | json ->
          Alcotest.(check bool)
            "store stats narrow with a lookback (win-jee9)" true
            (json_member "logs" json = `Int 2));
      check_invalid_query "invalid lookback"
        (server_get config store "/traces?lookback=1w") "lookback";
      check_invalid_query "empty lookback"
        (server_get config store "/logs?lookback=") "lookback";
      check_invalid_query "invalid cursor"
        (server_get config store "/traces?cursor=not-a-cursor") "cursor";
      check_invalid_query "invalid limit"
        (server_get config store "/traces?limit=0") "limit")

let json_list name json =
  match json_member name json with
  | `List items -> items
  | _ -> Alcotest.failf "%s is missing" name

let next_cursor json =
  match json_field_opt "nextCursor" (json_member "meta" json) with
  | Some (`String cursor) -> cursor
  | Some _ -> Alcotest.fail "nextCursor is not a string"
  | None -> Alcotest.fail "expected another page"

let walk_list ~config ~store ~name path =
  let rec loop cursor pages acc =
    let target =
      match cursor with
      | None -> path
      | Some cursor ->
          path
          ^ (if String.contains path (Char.chr 63) then "&" else "?")
          ^ "cursor=" ^ cursor
    in
    let json = server_json config store target in
    let items = json_list name json in
    let meta = json_member "meta" json in
    Alcotest.(check int)
      (target ^ " meta returned") (List.length items)
      (match json_member "returned" meta with `Int value -> value | _ -> -1);
    let next = json_field_opt "nextCursor" meta in
    Alcotest.(check bool)
      (target ^ " meta truncated matches nextCursor (win-fl8w)") true
      ((match json_member "truncated" meta with
        | `Bool value -> value
        | _ -> false)
      = Option.is_some next);
    let acc = acc @ items in
    let pages = (items, meta) :: pages in
    match next with
    | Some (`String next) -> loop (Some next) pages acc
    | Some _ -> Alcotest.failf "%s has a non-string nextCursor" target
    | None -> (List.rev pages, acc)
  in
  loop None [] []

(* Walk one endpoint in small pages and prove there are no duplicates, no
   gaps, and no cursor on the last page (win-edze, win-7xet, win-5hgv). *)
let check_walk ~config ~store ~name ~key ~limit path =
  let target = path ^ "&limit=" ^ string_of_int limit in
  let full =
    json_list_length name (server_json config store (path ^ "&limit=1000"))
  in
  let pages, items = walk_list ~config ~store ~name target in
  let keys = List.map key items in
  Alcotest.(check int)
    (path ^ " pages repeat nothing (win-edze)") (List.length keys)
    (List.length (List.sort_uniq String.compare keys));
  Alcotest.(check int)
    (path ^ " pages skip nothing (win-edze)") full (List.length items);
  Alcotest.(check bool)
    (path ^ " walks more than one page (win-5hgv)") true
    (List.length pages > 1);
  (match List.rev pages with
  | (_, last_meta) :: _ ->
      Alcotest.(check bool)
        (path ^ " last page has no cursor (win-7xet)") true
        (json_field_opt "nextCursor" last_meta = None)
  | [] -> Alcotest.fail "expected at least one page");
  items

let test_pagination_walk_logs ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* win-edze, win-7xet, win-fl8w, win-xi3q, win-xpfn *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw ~now_ms:(fun () -> base_time) config) in
  Fun.protect
    ~finally:(fun () -> run_store (fun _sw -> Store.close store))
    (fun () ->
      let walk_body index = Printf.sprintf "walk-%03d" index in
      let logs =
        List.init 250 (fun index ->
            test_log ~service_name:"walk" ~body:(walk_body index)
              ~timestamp_ms:(base_time - (index * 60_000)) ())
      in
      ignore (run_store (fun _sw -> Store.ingest_logs store logs));
      let bodies json =
        List.map
          (fun item ->
            match json_member "body" item with `String body -> body | _ -> "")
          (json_list "logs" json)
      in
      let page1 = server_json config store "/logs?limit=100&lookback=all" in
      Alcotest.(check int)
        "the first page is full (win-fl8w)" 100 (List.length (bodies page1));
      Alcotest.(check bool)
        "the first page reports truncation (win-fl8w)" true
        (json_member "truncated" (json_member "meta" page1) = `Bool true);
      Alcotest.(check string)
        "meta carries the effective window (win-fl8w)" "all"
        (match json_member "lookback" (json_member "meta" page1) with
        | `String value -> value
        | _ -> "");
      Alcotest.(check int)
        "meta carries the effective limit (win-fl8w)" 100
        (match json_member "limit" (json_member "meta" page1) with
        | `Int value -> value
        | _ -> -1);
      let cursor1 = next_cursor page1 in
      ignore
        (run_store
           (fun _sw -> Store.ingest_logs store
              (List.init 5 (fun index ->
                   test_log ~service_name:"walk"
                     ~body:(Printf.sprintf "late-%d" index)
                     ~timestamp_ms:(base_time + ((index + 1) * 60_000)) ()))));
      let page2 =
        server_json config store
          ("/logs?limit=100&lookback=all&cursor=" ^ cursor1)
      in
      let cursor2 = next_cursor page2 in
      let page3 =
        server_json config store
          ("/logs?limit=100&lookback=all&cursor=" ^ cursor2)
      in
      Alcotest.(check (list int))
        "page sizes honour the limit (win-fl8w)"
        [ 100; 100; 50 ]
        [
          List.length (bodies page1);
          List.length (bodies page2);
          List.length (bodies page3);
        ];
      Alcotest.(check (list string))
        "newest first with a stable tie-breaker (win-xi3q)"
        (List.init 250 walk_body)
        (bodies page1 @ bodies page2 @ bodies page3);
      Alcotest.(check bool)
        "the last page has no cursor (win-7xet)" true
        (json_field_opt "nextCursor" (json_member "meta" page3) = None);
      Alcotest.(check bool)
        "the last page is not truncated (win-fl8w)" true
        (json_member "truncated" (json_member "meta" page3) = `Bool false);
      Alcotest.(check bool)
        "rows that arrived between pages are not mixed in (win-edze)" true
        (not
           (List.exists
              (fun body ->
                String.length body >= 5 && String.equal (String.sub body 0 5) "late-")
              (bodies page1 @ bodies page2 @ bodies page3)));
      Alcotest.(check string)
        "a fresh query sees rows that arrived between pages (win-edze)" "late-4"
        (match bodies (server_json config store "/logs?limit=1&lookback=all") with
        | first :: _ -> first
        | [] -> "");
      let ids =
        List.map
          (fun item -> match json_member "id" item with `String id -> id | _ -> "")
          (json_list "logs" page1)
      in
      Alcotest.(check bool)
        "every log row carries its stable id (win-xpfn)" true
        (List.for_all (fun id -> String.length id > 0) ids);
      Alcotest.(check int)
        "log ids are unique (win-xpfn)" 100
        (List.length (List.sort_uniq String.compare ids)))

let test_pagination_endpoints ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* win-5hgv, win-ggl7, win-7xet, win-xl30 *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw ~now_ms:(fun () -> base_time) config) in
  Fun.protect
    ~finally:(fun () -> run_store (fun _sw -> Store.close store))
    (fun () ->
      let trace_id index = Printf.sprintf "%032x" (index + 1) in
      let span_id index = Printf.sprintf "%016x" (index + 1) in
      let trace_one = trace_id 0 in
      let span_one = span_id 0 in
      let spans =
        List.init 5 (fun index ->
            test_span ~trace_id:trace_one ~span_id:(span_id index)
              ~service_name:"page"
              ~timestamp_ms:(base_time - (index * 60_000)) ())
        @ List.init 4 (fun index ->
              test_span ~trace_id:(trace_id (index + 1))
                ~span_id:(span_id index) ~service_name:"page"
                ~timestamp_ms:(base_time - ((index + 1) * 60_000)) ())
        @ List.init 5 (fun index ->
              test_span ~trace_id:(trace_id 5) ~span_id:(span_id index)
                ~service_name:"ai" ~attributes:[ ("ai.model.id", "gpt-page") ]
                ~timestamp_ms:(base_time - (index * 30_000)) ())
      in
      let logs =
        List.init 5 (fun index ->
            let log =
              test_log ~service_name:"page" ~body:(Printf.sprintf "log-%d" index)
                ~timestamp_ms:(base_time - (index * 60_000)) ()
            in
            { log with Model.trace_id = Some trace_one; span_id = Some span_one })
      in
      let metrics =
        List.init 5 (fun index ->
            test_metric ~service_name:"page" ~name:"page.metric"
              ~timestamp_ms:(base_time - (index * 60_000)) ())
      in
      ignore
        (run_store
           (fun _sw -> let ( let* ) = Result.bind in
            let* _ = Store.ingest_traces store spans in
            let* _ = Store.ingest_logs store logs in
            let* _ = Store.ingest_metrics store metrics in
            Result.ok ()));
      let string_field name json =
        match json_member name json with `String value -> value | _ -> ""
      in
      let trace_key json = string_field "traceId" json in
      let span_key json = trace_key json ^ ":" ^ string_field "spanId" json in
      let log_key json = string_field "id" json in
      let metric_key json = string_field "timestampUnixNano" json in
      ignore
        (check_walk ~config ~store ~name:"traces" ~key:trace_key ~limit:2
           "/traces?lookback=all");
      ignore
        (check_walk ~config ~store ~name:"spans" ~key:span_key ~limit:2
           "/spans/search?lookback=all");
      ignore
        (check_walk ~config ~store ~name:"spans" ~key:span_key ~limit:2
           ("/traces/" ^ trace_one ^ "/spans?lookback=all"));
      ignore
        (check_walk ~config ~store ~name:"logs" ~key:log_key ~limit:2
           ("/traces/" ^ trace_one ^ "/logs?lookback=all"));
      ignore
        (check_walk ~config ~store ~name:"logs" ~key:log_key ~limit:2
           ("/spans/" ^ span_one ^ "/logs?lookback=all"));
      ignore
        (check_walk ~config ~store ~name:"metrics" ~key:metric_key ~limit:2
           "/metrics?lookback=all");
      let log_page = server_json config store "/logs?limit=1&lookback=all" in
      let log_cursor = next_cursor log_page in
      let wrong_kind = server_get config store ("/traces?lookback=all&cursor=" ^ log_cursor) in
      check_invalid_query "a log cursor on traces" wrong_kind "cursor";
      Alcotest.(check bool)
        "the wrong-kind error names both kinds (win-xl30)" true
        (let message = json_string_field "message" (response_json wrong_kind) in
         contains message "log" && contains message "trace");
      let trace_page = server_json config store "/traces?limit=1&lookback=all" in
      let trace_cursor = next_cursor trace_page in
      check_invalid_query "a trace cursor on logs"
        (server_get config store ("/logs?lookback=all&cursor=" ^ trace_cursor))
        "cursor")

let test_exact_queries_above_old_caps ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* acc-879n, acc-laac, acc-whoa, acc-gkoz, acc-efzp. *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw ~now_ms:(fun () -> base_time) config) in
  Fun.protect ~finally:(fun () -> run_store (fun _sw -> Store.close store)) @@ fun () ->
  let span_count = 12_050 and log_count = 188_025 in
  let spans = List.init span_count (fun i ->
    let ai = i <= 100 in
    let span = test_span ~trace_id:(Printf.sprintf "%032x" (i + 1))
      ~span_id:(Printf.sprintf "%016x" (i + 1))
      ~timestamp_ms:(base_time - 20_000 + i)
      ~operation_name:(if ai then "generateText" else "work")
      ~attributes:(["http.method", "GET";
         "partition", Printf.sprintf "bucket-%03d" (i mod 200)] @
        if i = 0 then ["ai.model", "old-model"; "ai.prompt", "needle-old-call"]
        else if ai then ["ai.model", "wide-model"] else []) () in
    let duration = if ai then i + 1 else 1 in
    { span with duration_ms = float_of_int duration;
      end_time_ns = span.start_time_ns + duration * 1_000_000 }) in
  let logs = List.init log_count (fun i ->
    test_log ~timestamp_ms:(base_time - 60_000 + i)
      ~body:(Printf.sprintf "row %d" i)
      ~attributes:["http.method", "GET"] ()) in
  let rec batches size rows =
    let rec take n acc = function
      | rest when n = 0 -> List.rev acc, rest
      | [] -> List.rev acc, []
      | head :: tail -> take (n - 1) (head :: acc) tail in
    match rows with [] -> [] | _ ->
      let batch, rest = take size [] rows in
      batch :: batches size rest in
  List.iter (fun batch -> ignore (run_store (fun _sw -> Store.ingest_traces store batch)))
    (batches 500 spans);
  List.iter (fun batch -> ignore (run_store (fun _sw -> Store.ingest_logs store batch)))
    (batches 1_000 logs);
  let response path field = json_list field (server_json config store path) in
  let count_group rows group expected =
    Alcotest.(check bool) (group ^ " exact count") true
      (List.exists (fun row -> json_member "group" row = `String group
        && json_member "count" row = `Int expected) rows) in
  let count_facet rows value expected =
    Alcotest.(check bool) (value ^ " exact facet count") true
      (List.exists (fun row -> json_member "value" row = `String value
        && json_member "count" row = `Int expected) rows) in
  (* acc-1ccu: 200,075 rows. Time bounded SQL queries, not fixture ingest.
     Thirty seconds leaves ample room for slower CI hosts. *)
  let query_started = mono_now () in
  Alcotest.(check int) "acc-879n old trace beyond 10k spans" 1
    (List.length (response
      "/traces/search?lookback=all&attr.ai.prompt=needle-old-call&attr.http.method=GET"
      "traces"));
  count_group (response "/traces/stats?lookback=all&groupBy=service&agg=count"
    "stats") "svc" span_count;
  let partition_stats = response
    "/traces/stats?lookback=all&groupBy=attr.partition&agg=count&limit=200" "stats" in
  Alcotest.(check int) "acc-1ccu single SQL grouping for 200 attribute values"
    200 (List.length partition_stats);
  count_group partition_stats "bucket-000" 61;
  Alcotest.(check int) "acc-whoa 188k matching log attributes avoid SQL variables"
    1 (List.length (response
      "/logs/search?lookback=all&attr.http.method=GET&limit=1" "logs"));
  count_group (response "/logs/stats?lookback=all&groupBy=service"
    "stats") "svc" log_count;
  count_facet (response "/facets?lookback=all&type=traces&field=service"
    "facets") "svc" span_count;
  count_facet (response
    "/facets?lookback=all&type=traces&field=attribute_values&key=http.method"
    "facets") "GET" span_count;
  count_facet (response "/facets?lookback=all&type=logs&field=service"
    "facets") "svc" log_count;
  count_facet (response
    "/facets?lookback=all&type=logs&field=attribute_values&key=http.method"
    "facets") "GET" log_count;
  Alcotest.(check bool) "acc-1ccu 200k-row queries finish within 30 seconds"
    true (elapsed_seconds query_started < 30.)

let test_search_filters_and_exact_stats ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* sf-*, acc-*: literal filters, typed joins, complete aggregates. *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw ~now_ms:(fun () -> base_time) config) in
  Fun.protect ~finally:(fun () -> run_store (fun _sw -> Store.close store)) @@ fun () ->
  let trace_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" in
  let trace_b = "cccccccccccccccccccccccccccccccc" in
  let root = test_span ~trace_id:trace_a ~span_id:"1111111111111111"
    ~service_name:"backend" ~operation_name:"root"
    ~attributes:["tag", "A%_\\B"] () in
  let root = { root with end_time_ns = root.start_time_ns + 20_000_000;
    duration_ms = 20. } in
  let child = test_span ~trace_id:trace_a ~span_id:"2222222222222222"
    ~parent_span_id:(Some root.span_id) ~service_name:"frontend"
    ~operation_name:"query" ~status:"error"
    ~attributes:["tag", "A%_\\B";
      "ai.model", "model-x"; "ai.prompt", "Special%_\\Text";
      "ai.response", "ResponseContent"; "ai.tool.output", "ToolContent";
      "ai.usage.inputTokens", "7"] () in
  let child = { child with duration_ms = 10.;
    end_time_ns = child.start_time_ns + 10_000_000 } in
  let other = test_span ~trace_id:trace_b ~span_id:"3333333333333333"
    ~service_name:"backend" ~operation_name:"query"
    ~attributes:["tag", "ordinary"; "ai.model", "model-y"] () in
  let log_a = { (test_log ~attributes:["tag", "A%_\\B"] ()) with
    trace_id = Some trace_a; span_id = Some child.span_id } in
  let log_b = { (test_log ~body:"other" ()) with
    trace_id = Some trace_b; severity_text = "INFO"; severity_number = Some 9 } in
  let log_c = { (test_log ~body:"100%_\\Case" ()) with
    severity_text = "wArN"; severity_number = None } in
  let log_d = { (test_log ~body:"case fourth" ()) with
    severity_text = "error"; severity_number = Some 17 } in
  ignore (run_store (fun _sw -> let ( let* ) = Result.bind in
    let* _ = Store.ingest_traces store [root; child; other] in
    let* _ = Store.ingest_logs store [log_a; log_b; log_c; log_d] in
    Result.ok ()));
  let n path field = List.length (json_list field (server_json config store path)) in
  Alcotest.(check int) "sf literal wildcards in spans" 2
    (n "/spans/search?lookback=all&attrContains.tag=%25_%5CB" "spans");
  Alcotest.(check int) "srch-k254 error is trace health" 1
    (n "/traces/search?lookback=all&status=error" "traces");
  Alcotest.(check int) "srch-k254 ok excludes mixed-status trace" 1
    (n "/traces/search?lookback=all&status=ok" "traces");
  Alcotest.(check int) "acc-km90 trace search includes participating child service" 1
    (n "/traces/search?lookback=all&service=frontend" "traces");
  Alcotest.(check int) "acc-km90 trace list includes participating child service" 1
    (n "/traces?lookback=all&service=frontend" "traces");
  Alcotest.(check int) "sf parent operation joins spans" 1
    (n "/spans/search?lookback=all&parentOperation=root" "spans");
  Alcotest.(check int) "sf duration applies in SQL" 2
    (n "/spans/search?lookback=all&minDurationMs=5" "spans");
  Alcotest.(check int) "sf log severity cutoff" 2
    (n "/logs/search?lookback=all&minSeverity=ERROR" "logs");
  Alcotest.(check int) "srch-odnn log list attribute substring" 1
    (n "/logs?lookback=all&attrContains.tag=%25_%5CB" "logs");
  (* Every route is exercised rather than merely listing the filter in a schema. *)
  let check story expected path field =
    Alcotest.(check int) story expected (n path field) in
  check "srch-sjbi operation substring case fold on spans" 2
    "/spans/search?lookback=all&operation=QuErY" "spans";
  check "srch-sjbi operation substring reaches child traces" 2
    "/traces/search?lookback=all&operation=QuErY" "traces";
  check "srch-ypr2 actual parent operation case fold" 1
    "/spans/search?lookback=all&parentOperation=ROot" "spans";
  check "srch-ypr2 no parent from other trace" 0
    "/spans/search?lookback=all&parentOperation=QuErY" "spans";
  check "srch-zjff body matches literal wildcards" 1
    "/logs/search?lookback=all&body=100%25_%5Ccase" "logs";
  check "srch-zjff contains aliases body" 1
    "/logs?lookback=all&contains=100%25_%5Ccase" "logs";
  List.iter (fun (route, field, expected) ->
    check "srch-odnn attrContains route" expected route field)
    [ "/traces/search?lookback=all&attrContains.tag=%25_%5C", "traces", 1;
      "/spans/search?lookback=all&attrContains.tag=%25_%5C", "spans", 2;
      "/logs/search?lookback=all&attrContains.tag=%25_%5C", "logs", 1;
      "/traces/" ^ trace_a ^ "/logs?lookback=all&attrContains.tag=%25_%5C", "logs", 1;
      "/spans/" ^ child.span_id ^ "/logs?lookback=all&attrContains.tag=%25_%5C", "logs", 1 ];
  check "srch-ynd1 exact and substring on same trace" 1
    "/traces/search?lookback=all&attr.tag=A%25_%5CB&attrContains.ai.prompt=special" "traces";
  check "srch-ynd1 exact and substring reject mismatched trace" 0
    "/spans/search?lookback=all&attr.tag=ordinary&attrContains.ai.prompt=special" "spans";
  check "srch-ynd1 several substring keys combine with AND" 1
    "/spans/search?lookback=all&attrContains.tag=%25&attrContains.ai.prompt=Special" "spans";
  check "srch-ynd1 repeated exact keys are AND" 0
    "/spans/search?lookback=all&attr.tag=ordinary&attr.tag=A%25_%5CB" "spans";
  check "srch-w4sn duration trace search" 1
    "/traces/search?lookback=all&minDurationMs=5" "traces";
  check "srch-sh8y ok excludes error span" 2
    "/spans/search?lookback=all&status=ok" "spans";
  check "srch-sh8y error is individual span" 1
    "/spans/search?lookback=all&status=error" "spans";
  check "srch-pxq5 severity ignores case" 2
    "/logs/search?lookback=all&severity=ErRoR" "logs";
  check "srch-qplh warn uses number or fallback text" 3
    "/logs?lookback=all&minSeverity=warn" "logs";
  check "srch-qplh stats threshold by severity" 1
    "/logs/stats?lookback=all&groupBy=service&minSeverity=warn" "stats";
  let stat story path expected_group expected_count expected_value =
    let rows = json_list "stats" (server_json config store path) in
    Alcotest.(check bool) story true (List.exists (fun row ->
      json_member "group" row = `String expected_group
      && json_member "count" row = `Int expected_count
      && json_member "value" row = `Float expected_value) rows) in
  let grouped_traces = json_list "stats" (server_json config store
    "/traces/stats?groupBy=attr.tag&agg=count&lookback=all") in
  Alcotest.(check int) "sf trace attr groups" 2 (List.length grouped_traces);
  Alcotest.(check bool) "acc-lh84 same value on two spans counts one trace"
    true (List.exists (fun row -> json_member "group" row =
      `String "A%_\\B" && json_member "count" row = `Int 1) grouped_traces);
  stat "srch-k254 trace stats error uses whole trace health"
    "/traces/stats?groupBy=service&agg=count&lookback=all&status=error"
    "backend" 1 1.;
  stat "srch-odnn attrContains trace stats"
    "/traces/stats?groupBy=service&agg=count&lookback=all&attrContains.tag=%25_%5C"
    "backend" 1 1.;
  stat "srch-odnn attrContains log stats"
    "/logs/stats?groupBy=service&lookback=all&attrContains.tag=%25_%5C"
    "svc" 1 1.;
  stat "srch-w4sn minDuration trace stats"
    "/traces/stats?groupBy=service&agg=count&lookback=all&minDurationMs=5"
    "backend" 1 1.;
  stat "srch-qplh minSeverity fallback counted"
    "/logs/stats?groupBy=service&lookback=all&minSeverity=warn"
    "svc" 3 3.;
  stat "acc-1ccu grouped trace attribute error rate"
    "/traces/stats?groupBy=attr.tag&agg=error_rate&lookback=all"
    "A%_\\B" 1 1.;
  stat "acc-1ccu grouped trace attribute average"
    "/traces/stats?groupBy=attr.tag&agg=avg_duration&lookback=all"
    "A%_\\B" 1 20.;
  stat "acc-1ccu grouped trace attribute p95"
    "/traces/stats?groupBy=attr.tag&agg=p95_duration&lookback=all"
    "A%_\\B" 1 20.;
  let facets = json_list "facets" (server_json config store
    "/facets?type=traces&field=attribute_values&key=tag") in
  Alcotest.(check bool) "acc-lh84 duplicate span attributes count one trace" true
    (List.exists (fun facet -> json_member "value" facet = `String "A%_\\B"
      && json_member "count" facet = `Int 1) facets);
  let facet story field value expected =
    let items = json_list "facets" (server_json config store
      ("/facets?type=traces&field=" ^ field)) in
    Alcotest.(check bool) story true (List.exists (fun item ->
      json_member "value" item = `String value
      && json_member "count" item = `Int expected) items) in
  facet "acc-jjlo root service facet counts distinct traces"
    "service" "backend" 2;
  facet "acc-jjlo root operation excludes child operation"
    "operation" "root" 1;
  facet "acc-jjlo trace health facet error" "status" "error" 1;
  facet "acc-jjlo trace health facet ok" "status" "ok" 1;
  check_invalid_query "srch-jk2v nonnumeric duration" (server_get config store
    "/spans/search?minDurationMs=abc") "minDurationMs";
  check_invalid_query "srch-jk2v negative duration" (server_get config store
    "/spans/search?minDurationMs=-1") "minDurationMs";
  check_invalid_query "srch-jk2v unknown severity" (server_get config store
    "/logs/search?minSeverity=BOGUS") "minSeverity";
  List.iter (fun path ->
    let meta = json_member "meta" (server_json config store path) in
    Alcotest.(check bool) "acc-g6qx no approximate flag without a safety cap"
      true (json_member "approximate" meta = `Null))
    [ "/traces/stats?groupBy=service&agg=count";
      "/logs/stats?groupBy=service";
      "/facets?type=traces&field=service" ];
  let inventory = json_list "endpoints" (server_json config store "/endpoints") in
  let trace_route = List.find_opt (fun endpoint ->
    json_member "path" endpoint = `String "/traces/search") inventory in
  let route = match trace_route with Some route -> route
    | None -> Alcotest.fail "trace search missing from inventory" in
  let filters = json_list "filters" route in
  Alcotest.(check bool) "srch-z5cu inventory exposes filters" true
    (List.mem (`String "attrContains.<key>") filters);
  let api = server_json config store "/openapi.json" in
  let operation = json_member "get"
    (json_member "/traces/search" (json_member "paths" api)) in
  let params = json_list "parameters" operation in
  Alcotest.(check bool) "srch-z5cu OpenAPI exposes typed duration" true
    (List.exists (fun param ->
      json_member "name" param = `String "minDurationMs"
      && json_member "type" (json_member "schema" param) = `String "number") params);
  Alcotest.(check bool) "srch-z5cu OpenAPI exposes dynamic keys" true
    (List.mem (`String "attrContains.<key>")
      (json_list "x-inn-query-prefixes" operation))



(* Trace tree ------------------------------------------------------------ *)

let tree_span ?(trace_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    ?(span_id = "b000000000000001") ?(parent_span_id = None)
    ?(service_name = "svc") ?(operation_name = "op") ?(status = "ok")
    ?(start_ms = base_time) ?(duration_ms = 1.) ?(running = false)
    ?(attributes = []) () =
  let start_time_ns = start_ms * 1_000_000 in
  let span =
    test_span ~trace_id ~span_id ~parent_span_id ~service_name ~operation_name
      ~status ~attributes ~timestamp_ms:start_ms ()
  in
  {
    span with
    Model.end_time_ns =
      (if running then 0
       else start_time_ns + int_of_float (duration_ms *. 1_000_000.));
    duration_ms;
  }

let node_ids (tree : Trace_tree.t) =
  List.map (fun (node : Model.span_node) -> node.span.span_id) tree.nodes

let node_depths (tree : Trace_tree.t) =
  List.map (fun (node : Model.span_node) -> node.depth) tree.nodes

let find_node (tree : Trace_tree.t) span_id =
  match
    List.find_opt
      (fun (node : Model.span_node) -> String.equal node.span.span_id span_id)
      tree.nodes
  with
  | Some node -> node
  | None -> Alcotest.failf "span %s is missing from the tree" span_id

let json_span_order json =
  json_list "spans" json
  |> List.map (fun span ->
         (json_string_field "spanId" span, json_member "depth" span))

let test_trace_tree_assembly () =
  (* tree-tflv, tree-3w92, tree-sih1, tree-78hm, tree-ap92 *)
  let root =
    tree_span ~span_id:"root" ~operation_name:"GET /" ~service_name:"api"
      ~start_ms:(base_time - 5_000) ()
  in
  let slow =
    tree_span ~span_id:"slow" ~parent_span_id:(Some "root") ~operation_name:"db"
      ~start_ms:(base_time - 3_000) ()
  in
  let fast =
    tree_span ~span_id:"fast" ~parent_span_id:(Some "root")
      ~operation_name:"cache" ~start_ms:(base_time - 4_000) ()
  in
  let leaf =
    tree_span ~span_id:"leaf" ~parent_span_id:(Some "slow")
      ~operation_name:"select" ~start_ms:(base_time - 2_000) ()
  in
  let unrelated =
    tree_span ~span_id:"other" ~operation_name:"job"
      ~start_ms:(base_time - 1_000) ()
  in
  let tree = Trace_tree.assemble [ leaf; slow; unrelated; root; fast ] in
  Alcotest.(check (list string))
    "tree-tflv depth-first from the roots, siblings by start time"
    [ "root"; "fast"; "slow"; "leaf"; "other" ]
    (node_ids tree);
  Alcotest.(check (list int)) "tree-3w92 depth counts from zero at the roots"
    [ 0; 1; 1; 2; 0 ] (node_depths tree);
  Alcotest.(check (option string)) "tree-sih1 a root has no parent operation"
    None (find_node tree "root").parent_operation_name;
  Alcotest.(check (option string))
    "tree-sih1 a child carries its parent's operation" (Some "GET /")
    (find_node tree "fast").parent_operation_name;
  List.iter
    (fun id ->
      Alcotest.(check string)
        ("tree-sih1 root operation of " ^ id) "GET /"
        (find_node tree id).root_operation_name)
    [ "root"; "fast"; "slow"; "leaf" ];
  Alcotest.(check string) "tree-sih1 a second root is its own root operation"
    "job" (find_node tree "other").root_operation_name;
  Alcotest.(check bool) "tree-ap92 two roots are reported" true
    (List.exists (fun warning -> contains warning "2 roots") tree.warnings);
  Alcotest.(check bool) "tree-78hm a finished trace is not running" false
    tree.is_running;
  let running =
    tree_span ~span_id:"running" ~operation_name:"llm"
      ~start_ms:(base_time - 500) ~running:true ()
  in
  let running_tree = Trace_tree.assemble [ root; running ] in
  Alcotest.(check bool) "tree-78hm one unfinished span runs the trace" true
    running_tree.is_running;
  let node = find_node running_tree "running" in
  Alcotest.(check bool) "tree-78hm the span is marked running" true
    node.is_running;
  let json = Model.span_node_to_json node in
  Alcotest.(check bool) "tree-78hm a running span has a null duration" true
    (json_member "durationMs" json = `Null);
  Alcotest.(check bool) "tree-3w92 the JSON node carries its depth" true
    (json_member "depth" json = `Int 0);
  Alcotest.(check bool) "tree-sih1 the JSON node carries the root operation" true
    (json_member "rootOperationName" json = `String "llm");
  Alcotest.(check bool) "tree-78hm an end before the start is running" true
    (Trace_tree.is_running_span { running with Model.end_time_ns = 1 })

let test_trace_tree_warnings () =
  (* tree-ffmn, tree-ap92 *)
  let root =
    tree_span ~span_id:"root" ~operation_name:"root"
      ~start_ms:(base_time - 3_000) ()
  in
  let orphan =
    tree_span ~span_id:"orphan" ~parent_span_id:(Some "gone")
      ~operation_name:"orphan" ~start_ms:(base_time - 2_000) ()
  in
  let tree = Trace_tree.assemble [ root; orphan ] in
  Alcotest.(check (list string)) "tree-ffmn a missing parent is a root"
    [ "root"; "orphan" ] (node_ids tree);
  Alcotest.(check (list int)) "tree-ffmn a missing parent sits at depth zero"
    [ 0; 0 ] (node_depths tree);
  let node = find_node tree "orphan" in
  Alcotest.(check (option string))
    "tree-ffmn a missing parent has no known operation" None
    node.parent_operation_name;
  Alcotest.(check int) "tree-ffmn the span carries one warning" 1
    (List.length node.warnings);
  Alcotest.(check bool) "tree-ffmn the span warning names the missing parent"
    true
    (List.exists (fun warning -> contains warning "gone") node.warnings);
  Alcotest.(check bool) "tree-ffmn the trace carries the same warning" true
    (List.exists (fun warning -> contains warning "gone") tree.warnings);
  Alcotest.(check bool) "tree-ap92 the extra root is still a warning" true
    (List.exists (fun warning -> contains warning "2 roots") tree.warnings);
  let left =
    tree_span ~span_id:"left" ~parent_span_id:(Some "right")
      ~operation_name:"left" ()
  in
  let right =
    tree_span ~span_id:"right" ~parent_span_id:(Some "left")
      ~operation_name:"right" ()
  in
  let cycle = Trace_tree.assemble [ left; right ] in
  Alcotest.(check int) "tree-ffmn a parent cycle terminates" 2
    (List.length cycle.nodes);
  Alcotest.(check (list string)) "tree-ffmn a cycled span is emitted once"
    [ "left"; "right" ] (node_ids cycle);
  Alcotest.(check bool) "tree-ffmn the cycle is reported" true
    (List.exists (fun warning -> contains warning "cycle") cycle.warnings)

(* Test-only probe: the store never leaves a trace without its trace part, so
   the 404 rule needs one deleted by hand (tree-ddll). *)
module Test_trace_summaries = struct
  module T = Ox_sql.Table.Make (struct
    let name = "trace_parts"
  end)

  include T

  let trace_id = column "trace_id" Ox_sql.text
end

let delete_trace_summary ~(caps : < Ox_caps.Cap.time ; .. >) path trace_id =
  (run_test_db ~caps) path (fun pool ->
      let ( let* ) = Result.bind in
      let delete =
        Ox_sql.Delete.(
          from Test_trace_summaries.table
          |> where Ox_sql.Expr.(eq Test_trace_summaries.trace_id trace_id)
          |> compile)
      in
      let* _ = Ox_sql.Pool.Typed.execute_compiled pool delete in
      Result.ok ())

let test_trace_tree_handlers ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* tree-o79f, tree-uv04, tree-ddll, tree-6vac, tree-3w92, tree-sih1 *)
  let config = (temp_config ~caps) () in
  Fun.protect
    ~finally:(fun () -> (cleanup_config ~caps) config)
    (fun () ->
      run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw ~now_ms:(fun () -> base_time) config) in
      Fun.protect
        ~finally:(fun () -> run_store (fun _sw -> Store.close store))
        (fun () ->
          let trace_id = "dddddddddddddddddddddddddddddddd" in
          let root_id = "d000000000000001"
          and child_id = "d000000000000002"
          and running_id = "d000000000000003" in
          let root =
            tree_span ~trace_id ~span_id:root_id ~operation_name:"root"
              ~service_name:"api" ~start_ms:(base_time - 4_000) ()
          in
          let child =
            tree_span ~trace_id ~span_id:child_id
              ~parent_span_id:(Some root_id) ~operation_name:"child"
              ~service_name:"api" ~start_ms:(base_time - 3_000) ()
          in
          let running =
            tree_span ~trace_id ~span_id:running_id
              ~parent_span_id:(Some root_id) ~operation_name:"running"
              ~service_name:"api" ~start_ms:(base_time - 2_000) ~running:true ()
          in
          ignore
            (run_store
               (fun _sw -> let ( let* ) = Result.bind in
                let* _ = Store.ingest_traces store [ root; child; running ] in
                Result.ok ()));
          let detail = server_json config store ("/traces/" ^ trace_id) in
          let spans = json_list "spans" detail in
          Alcotest.(check (list string))
            "tree-uv04 the trace detail is in tree order"
            [ root_id; child_id; running_id ]
            (List.map (fun span -> json_string_field "spanId" span) spans);
          Alcotest.(check (list int)) "tree-3w92 the trace detail depths"
            [ 0; 1; 1 ]
            (List.map
               (fun span ->
                 match json_member "depth" span with
                 | `Int value -> value
                 | _ -> -1)
               spans);
          Alcotest.(check (option string))
            "tree-sih1 the detail carries the parent operation"
            (Some "root")
            (match json_member "parentOperationName" (List.nth spans 1) with
            | `String value -> Some value
            | _ -> None);
          Alcotest.(check string)
            "tree-sih1 the detail carries the root operation" "root"
            (json_string_field "rootOperationName" (List.nth spans 1));
          Alcotest.(check bool) "tree-78hm the detail marks the running span"
            true
            (json_member "isRunning" (List.nth spans 2) = `Bool true);
          Alcotest.(check bool)
            "tree-78hm the running span has a null duration" true
            (json_member "durationMs" (List.nth spans 2) = `Null);
          Alcotest.(check (list string)) "tree-ffmn a clean trace has no warnings" []
            (List.map (function `String value -> value | json -> Yojson.Safe.to_string json) (json_list "warnings" detail));
          let summary = json_member "summary" detail in
          Alcotest.(check bool) "tree-78hm the trace summary is running" true
            (json_member "isRunning" summary = `Bool true);
          Alcotest.(check int) "tree-ffmn the summary warning count" 0
            (match json_member "warningCount" summary with
            | `Int value -> value
            | _ -> -1);
          let listed =
            server_json config store
              ("/traces/" ^ trace_id ^ "/spans?lookback=all")
          in
          Alcotest.(check (list (pair string string)))
            "tree-uv04 the trace spans list agrees with the detail"
            (List.map
               (fun (id, depth) -> (id, Yojson.Safe.to_string depth))
               (json_span_order detail))
            (List.map
               (fun (id, depth) -> (id, Yojson.Safe.to_string depth))
               (json_span_order listed));
          let node = server_json config store ("/spans/" ^ child_id) in
          Alcotest.(check bool) "tree-o79f the span detail carries its depth"
            true (json_member "depth" node = `Int 1);
          Alcotest.(check bool)
            "tree-o79f the span detail carries the parent operation" true
            (json_member "parentOperationName" node = `String "root");
          Alcotest.(check bool)
            "tree-o79f the span detail carries the root operation" true
            (json_member "rootOperationName" node = `String "root");
          let summaries =
            json_list "traces" (server_json config store "/traces?lookback=all")
          in
          let listed_summary = List.hd summaries in
          Alcotest.(check bool)
            "tree-6vac the summary list marks running traces" true
            (json_member "isRunning" listed_summary = `Bool true);
          Alcotest.(check bool)
            "tree-6vac the summary list carries the warning count" true
            (match json_member "warningCount" listed_summary with
            | `Int _ -> true
            | _ -> false);
          (delete_trace_summary ~caps) (segment_file config 0) trace_id;
          let still = server_get config store ("/traces/" ^ trace_id) in
          Alcotest.(check int)
            "tree-ddll a trace without its summary row still answers" 200
            (Ox_http.Server.Response.status still);
          Alcotest.(check int) "tree-ddll and still has all its spans" 3
            (List.length (json_list "spans" (response_json still)));
          let missing =
            server_get config store
              "/traces/00000000000000000000000000000000"
          in
          Alcotest.(check int)
            "tree-ddll a trace with no span at all is a 404" 404
            (Ox_http.Server.Response.status missing)))

let read_repository_file ~(caps : < Ox_caps.Cap.fs_read ; .. >) names =
  match List.find_opt Sys.file_exists names with
  | Some path -> Ox_caps.Cap_stdlib.In_channel.with_open_bin ~caps path In_channel.input_all
  | None -> Alcotest.failf "none of %s exists" (String.concat ", " names)

(* Self-description ---------------------------------------------------- *)

let endpoint_declarations = Inn.Endpoint.all

let replace_once ~pattern ~with_ text =
  let pattern_length = String.length pattern in
  let rec search index =
    if index + pattern_length > String.length text then None
    else if String.equal (String.sub text index pattern_length) pattern then
      Some index
    else search (index + 1)
  in
  match search 0 with
  | None -> text
  | Some index ->
      String.sub text 0 index ^ with_
      ^ String.sub text (index + pattern_length)
          (String.length text - index - pattern_length)

(* The concrete request target of a declaration, with placeholder ids. *)
let concrete_path (endpoint : Inn.Endpoint.t) =
  List.fold_left
    (fun path (pattern, value) -> replace_once ~pattern ~with_:value path)
    endpoint.path
    [
      ("{traceId}", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
      ("{spanId}", "bbbbbbbbbbbbbbbb");
      ("{name}", "debug");
    ]

let declared_request config store (endpoint : Inn.Endpoint.t) target =
  run_server_effect
    (Inn.Server.handler config store
       (request ~method_:(Inn.Endpoint.method_to_string endpoint.method_)
          ~target ()))

let json_scalar_string = function
  | `String value -> value
  | `Int value -> string_of_int value
  | `Float value -> string_of_float value
  | `Bool value -> string_of_bool value
  | json -> Yojson.Safe.to_string json

let location_string (endpoint : Inn.Endpoint.t) (param : Inn.Endpoint.param) =
  match param.location with
  | Inn.Endpoint.Query -> "query"
  | Inn.Endpoint.Path -> "path"

let required_parameter param =
  param.Inn.Endpoint.name ^ "="
  ^ (match param.Inn.Endpoint.allowed with
    | value :: _ -> value
    | [] -> "required")

let response_content_type (response : Inn.Endpoint.response) =
  response.Inn.Endpoint.content_type

let response_status (response : Inn.Endpoint.response) =
  response.Inn.Endpoint.status

let response_schema (response : Inn.Endpoint.response) =
  response.Inn.Endpoint.schema

let declared_response (endpoint : Inn.Endpoint.t) status =
  List.find_opt
    (fun (response : Inn.Endpoint.response) -> response_status response = status)
    endpoint.Inn.Endpoint.responses

let test_declarations_drive_the_router ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* desc-iduq, desc-de6o: one declaration list is the router, the /endpoints
     inventory, and the OpenAPI document. *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw config) in
  Fun.protect ~finally:(fun () -> run_store (fun _sw -> Store.close store)) @@ fun () ->
  let inventory =
    json_list "endpoints" (server_json config store "/endpoints")
  in
  let openapi = server_json config store "/openapi.json" in
  let paths = json_member "paths" openapi in
  Alcotest.(check int)
    "every declaration is in the inventory"
    (List.length endpoint_declarations)
    (List.length inventory);
  List.iter
    (fun (endpoint : Inn.Endpoint.t) ->
      let method_ = Inn.Endpoint.method_to_string endpoint.method_ in
      let method_key = Inn.Endpoint.method_to_lowercase endpoint.method_ in
      let entry =
        match
          List.find_opt
            (fun item ->
              json_string_field "method" item = method_
              && json_string_field "path" item = endpoint.path)
            inventory
        with
        | Some entry -> entry
        | None ->
            Alcotest.failf "%s %s is missing from /endpoints" method_ endpoint.path
      in
      let declared_query =
        List.map
          (fun (param : Inn.Endpoint.param) -> param.name)
          (Inn.Endpoint.query_params endpoint)
      in
      Alcotest.(check (list string))
        (endpoint.path ^ " filters")
        declared_query
        (List.map json_scalar_string (json_list "filters" entry));
      let all_names =
        List.map
          (fun (param : Inn.Endpoint.param) -> param.name)
          endpoint.params
      in
      let inventory_params = json_list "parameters" entry in
      Alcotest.(check (list string))
        (endpoint.path ^ " inventory parameters")
        all_names
        (List.map (fun item -> json_string_field "name" item) inventory_params);
      let operation = json_member method_key (json_member endpoint.path paths) in
      Alcotest.(check bool)
        (method_ ^ " " ^ endpoint.path ^ " is in OpenAPI")
        true
        (operation <> `Null);
      let openapi_params = json_list "parameters" operation in
      Alcotest.(check (list string))
        (endpoint.path ^ " OpenAPI parameters")
        all_names
        (List.map (fun item -> json_string_field "name" item) openapi_params);
      List.iter
        (fun (param : Inn.Endpoint.param) ->
          let label = endpoint.path ^ " " ^ param.name in
          let inventory_param =
            match
              List.find_opt
                (fun item -> json_string_field "name" item = param.name)
                inventory_params
            with
            | Some item -> item
            | None -> Alcotest.failf "%s is missing from the inventory" label
          in
          let openapi_param =
            match
              List.find_opt
                (fun item -> json_string_field "name" item = param.name)
                openapi_params
            with
            | Some item -> item
            | None -> Alcotest.failf "%s is missing from OpenAPI" label
          in
          Alcotest.(check string)
            (label ^ " location")
            (location_string endpoint param)
            (json_string_field "in" inventory_param);
          Alcotest.(check string)
            (label ^ " location in OpenAPI")
            (location_string endpoint param)
            (json_string_field "in" openapi_param);
          Alcotest.(check bool)
            (label ^ " required")
            param.required
            (json_member "required" inventory_param = `Bool true);
          Alcotest.(check string)
            (label ^ " type")
            (Inn.Endpoint.kind_to_string param.kind)
            (json_string_field "type" inventory_param);
          let schema = json_member "schema" openapi_param in
          Alcotest.(check string)
            (label ^ " type in OpenAPI")
            (Inn.Endpoint.kind_to_string param.kind)
            (json_string_field "type" schema);
          (match param.default with
          | None ->
              Alcotest.(check bool)
                (label ^ " has no default")
                true
                (json_member "default" inventory_param = `Null);
              Alcotest.(check bool)
                (label ^ " has no default in OpenAPI")
                true
                (json_member "default" schema = `Null)
          | Some value ->
              Alcotest.(check string)
                (label ^ " default")
                value
                (json_scalar_string (json_member "default" inventory_param));
              Alcotest.(check string)
                (label ^ " default in OpenAPI")
                value
                (json_scalar_string (json_member "default" schema)));
          Alcotest.(check (list string))
            (label ^ " allowed values")
            param.allowed
            (List.map json_scalar_string (json_list "allowed" inventory_param));
          Alcotest.(check (list string))
            (label ^ " allowed values in OpenAPI")
            param.allowed
            (match json_member "enum" schema with
            | `List values -> List.map json_scalar_string values
            | _ -> []))
        endpoint.params;
      let responses = json_member "responses" operation in
      List.iter
        (fun (response : Inn.Endpoint.response) ->
          let declared =
            json_member (string_of_int (response_status response)) responses
          in
          let label = endpoint.path ^ " " ^ string_of_int (response_status response) in
          Alcotest.(check bool) (label ^ " is described") true (declared <> `Null);
          Alcotest.(check bool)
            (label ^ " documents " ^ response_content_type response)
            true
            (json_member (response_content_type response)
               (json_member "content" declared)
            <> `Null))
        endpoint.responses;
      Alcotest.(check string)
        (endpoint.path ^ " alias")
        (Inn.Endpoint.alias_path endpoint)
        (json_string_field "alias" entry);
      Alcotest.(check bool)
        (endpoint.path ^ " alias path is in OpenAPI")
        true
        (json_member (Inn.Endpoint.alias_path endpoint) paths <> `Null);
      (* The router really serves the declaration: the endpoint-not-found
         body and a 405 are the two ways a declaration could be missing. *)
      let target = concrete_path endpoint in
      let response = declared_request config store endpoint target in
      Alcotest.(check bool)
        (method_ ^ " " ^ target ^ " is registered")
        true
        (Ox_http.Server.Response.status response <> 405);
      (match
         Ox_http.Header.get "content-type"
           (Ox_http.Server.Response.headers response)
       with
      | Some content_type when contains content_type "application/json" ->
          Alcotest.(check bool)
            (method_ ^ " " ^ target ^ " is routed")
            true
            (json_member "error" (response_json response) <> `String "not_found")
      | _ -> ()))
    endpoint_declarations

let test_declared_responses_match_handlers ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* desc-iduq: the declared response schema covers what the handler returns,
     and an undeclared query parameter is rejected with the supported list. *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw config) in
  Fun.protect ~finally:(fun () -> run_store (fun _sw -> Store.close store)) @@ fun () ->
  List.iter
    (fun (endpoint : Inn.Endpoint.t) ->
      let required =
        List.filter_map
          (fun (param : Inn.Endpoint.param) ->
            if param.required then Some (required_parameter param) else None)
          (Inn.Endpoint.query_params endpoint)
      in
      let target =
        concrete_path endpoint
        ^ (if required = [] then "" else "?" ^ String.concat "&" required)
      in
      let response = declared_request config store endpoint target in
      let status = Ox_http.Server.Response.status response in
      match declared_response endpoint status with
      | None ->
          Alcotest.failf "%s %s answered %d, which the declaration does not carry"
            (Inn.Endpoint.method_to_string endpoint.method_)
            target status
      | Some declared ->
          if
            String.equal (response_content_type declared) "application/json"
          then begin
            let body = response_json response in
            (match json_member "properties" (response_schema declared) with
            | `Assoc properties ->
                let keys =
                  match body with `Assoc fields -> List.map fst fields | _ -> []
                in
                List.iter
                  (fun key ->
                    Alcotest.(check bool)
                      (target ^ " documents " ^ key)
                      true
                      (List.mem_assoc key properties))
                  keys
            | _ -> ())
          end
          else
            Alcotest.(check bool)
              (target ^ " returns a " ^ response_content_type declared ^ " body")
              true
              (String.length (response_body_string response) > 0))
    endpoint_declarations;
  (* The declared parameter set is the enforced one (desc-de6o). *)
  let undeclared = server_get config store "/traces?nope=1" in
  check_invalid_query "an undeclared parameter" undeclared "nope";
  Alcotest.(check bool)
    "the error lists the supported parameters" true
    (contains
       (json_string_field "message" (response_json undeclared))
       "lookback");
  let typed = server_get config store "/traces?limit=abc" in
  check_invalid_query "a wrongly typed parameter" typed "limit must be an integer"

let test_hidden_routes_are_documented ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* desc-dmuw: nothing the server serves stays out of the inventory. *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw config) in
  Fun.protect ~finally:(fun () -> run_store (fun _sw -> Store.close store)) @@ fun () ->
  let inventory =
    json_list "endpoints" (server_json config store "/endpoints")
  in
  let openapi = server_json config store "/openapi.json" in
  let paths = json_member "paths" openapi in
  let documented method_ path =
    (List.exists
       (fun item ->
         json_string_field "method" item = method_
         && json_string_field "path" item = path)
       inventory)
    && json_member (String.lowercase_ascii method_)
         (json_member path paths)
       <> `Null
  in
  List.iter
    (fun (method_, path) ->
      Alcotest.(check bool) (method_ ^ " " ^ path ^ " is documented") true
        (documented method_ path))
    [ ("POST", "/v1/metrics"); ("GET", "/healthz"); ("GET", "/ready") ];
  Alcotest.(check string)
    "the inventory publishes the alias policy" "/api"
    (json_string_field "prefix" (json_member "aliasPolicy"
       (server_json config store "/endpoints")));
  Alcotest.(check string)
    "OpenAPI publishes the alias policy" "/api"
    (json_string_field "prefix" (json_member "x-inn-alias-policy" openapi));
  List.iter
    (fun path ->
      Alcotest.(check int) ("the " ^ path ^ " alias answers") 200
        (Ox_http.Server.Response.status (server_get config store path)))
    [ "/api/healthz"; "/api/ready"; "/api/docs" ];
  Alcotest.(check int) "the /api ingest alias answers" 200
    (Ox_http.Server.Response.status
       (run_server_effect
          (Inn.Server.handler config store
             (request ~method_:"POST" ~target:"/api/v1/metrics" ()))))

let test_docs_endpoints ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* desc-bqwh, desc-7wwz *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw config) in
  Fun.protect ~finally:(fun () -> run_store (fun _sw -> Store.close store)) @@ fun () ->
  let guides = json_list "guides" (server_json config store "/docs") in
  Alcotest.(check int)
    "the index lists every guide" (List.length Inn.Docs.guides)
    (List.length guides);
  List.iter
    (fun (guide : Inn.Docs.guide) ->
      let entry =
        match
          List.find_opt
            (fun item -> json_string_field "name" item = guide.name)
            guides
        with
        | Some entry -> entry
        | None -> Alcotest.failf "guide %s is not listed" guide.name
      in
      Alcotest.(check string)
        (guide.name ^ " title") guide.title
        (json_string_field "title" entry);
      Alcotest.(check string)
        (guide.name ^ " path") ("/docs/" ^ guide.name)
        (json_string_field "path" entry);
      let response = server_get config store ("/docs/" ^ guide.name) in
      Alcotest.(check int)
        (guide.name ^ " status") 200
        (Ox_http.Server.Response.status response);
      Alcotest.(check bool)
        (guide.name ^ " is served as Markdown")
        true
        (match
           Ox_http.Header.get "content-type"
             (Ox_http.Server.Response.headers response)
         with
        | Some value -> contains value "text/markdown"
        | None -> false);
      Alcotest.(check string)
        (guide.name ^ " content") guide.content
        (response_body_string response))
    Inn.Docs.guides;
  let unknown = server_get config store "/docs/nope" in
  Alcotest.(check int)
    "an unknown guide is a 404" 404
    (Ox_http.Server.Response.status unknown);
  let body = response_json unknown in
  Alcotest.(check string)
    "the unknown guide code" "doc_not_found" (json_string_field "error" body);
  Alcotest.(check (list string))
    "the 404 lists the available names"
    (List.map (fun (guide : Inn.Docs.guide) -> guide.name) Inn.Docs.guides)
    (List.map json_scalar_string (json_list "available" body));
  List.iter
    (fun path ->
      Alcotest.(check int)
        (path ^ " alias") 200
        (Ox_http.Server.Response.status (server_get config store path)))
    [ "/api/docs"; "/api/docs/debug" ]

let test_guide_content () =
  (* desc-wy48, desc-od3y, desc-62du: the guides are substantive and name the
     configuration they describe. *)
  let guide name =
    match Inn.Docs.find name with
    | Some guide -> guide
    | None -> Alcotest.failf "the %s guide is missing" name
  in
  let check (guide : Inn.Docs.guide) fragments =
    Alcotest.(check bool)
      (guide.name ^ " is substantive") true
      (String.length guide.content > 3000);
    List.iter
      (fun fragment ->
        Alcotest.(check bool)
          (guide.name ^ " mentions " ^ fragment)
          true
          (contains guide.content fragment))
      fragments
  in
  check (guide "debug")
    [
      "lookback"; "cursor"; "attr."; "attrContains."; "minDurationMs";
      "minSeverity"; "/services"; "/traces/search"; "/spans/search";
      "/logs/search"; "/traces/{traceId}"; "depth"; "warnings";
      "isRunning";
      "/traces/stats"; "/logs/stats"; "/facets"; "/stats";
      "/docs"; "/docs/debug"; "/openapi.json"; "/endpoints";
      "inn_docs_index"; "inn_get_doc"; "inn_search_traces"; "inn_get_trace";
      "inn trace"; "inn docs";
    ];
  check (guide "effect")
    [
      "effect/unstable/observability"; "OtlpTracer.layer"; "OtlpLogger.layer";
      "OtlpMetrics.layer"; "OtlpSerialization.layerJson"; "FetchHttpClient.layer";
      "serviceName"; "/v1/traces"; "/v1/logs"; "/v1/metrics";
      "application/json";
    ];
  check (guide "ox")
    [
      "Ox_otel.create"; "Ox_http.Client.create";
      "Ox_observability.Logger.span"; "Ox_otel.reporter";
      "Ox_otel.span_ids"; "Ox_otel.shutdown"; "~endpoint"; "ox_otel";
      "/v1/traces"; "/v1/logs"; "/v1/metrics";
    ]

(* The first fenced block of the given language, including the newline that
   ends its last line. *)
let fenced_block language text =
  let fence = "```" ^ language in
  let rec find = function
    | [] -> None
    | line :: rest when String.equal (String.trim line) fence -> collect [] rest
    | _ :: rest -> find rest
  and collect acc = function
    | [] -> None
    | line :: rest when String.equal (String.trim line) "```" ->
        Some (String.concat "\n" (List.rev acc) ^ "\n")
    | line :: rest -> collect (line :: acc) rest
  in
  find (String.split_on_char '\n' text)

(* docs/guides/ox.md documents the exporter with one OCaml snippet, and
   test/ox_guide_snippet.ml is that same snippet compiled against the real Ox
   API (the stanza is enabled on the local-Ox build path). Keeping the two
   texts identical is what stops the guide from drifting away from an API it
   does not compile against. *)
let test_eta_guide_snippet_is_compiled ~(caps : < Ox_caps.Cap.fs_read ; .. >) () =
  let guide =
    (read_repository_file ~caps) [ "../docs/guides/ox.md"; "docs/guides/ox.md" ]
  in
  let source =
    (read_repository_file ~caps)
      [ "ox_guide_snippet.ml"; "../test/ox_guide_snippet.ml" ]
  in
  match fenced_block "ocaml" guide with
  | None -> Alcotest.fail "docs/guides/ox.md has no ocaml snippet"
  | Some block ->
      Alcotest.(check string)
        "the guide's Ox snippet is test/ox_guide_snippet.ml verbatim" source
        block

let test_health_identity ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* desc-8syr: version, an ISO 8601 start time, and an uptime.
     desc-lqpr: the same real version everywhere. *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw config) in
  Fun.protect ~finally:(fun () -> run_store (fun _sw -> Store.close store)) @@ fun () ->
  Inn.Server.mark_started ~caps ();
  let health = server_json config store "/health" in
  let healthz = server_json config store "/healthz" in
  let started_at = json_string_field "startedAt" health in
  Alcotest.(check int) "startedAt is ISO 8601" 24 (String.length started_at);
  Alcotest.(check bool)
    "startedAt is a UTC timestamp" true
    (started_at.[4] = '-' && started_at.[7] = '-' && started_at.[10] = 'T'
    && started_at.[13] = ':' && started_at.[16] = ':' && started_at.[19] = '.'
    && started_at.[23] = 'Z');
  let number start length = int_of_string (String.sub started_at start length) in
  Alcotest.(check bool)
    "startedAt is a real calendar time" true
    (number 0 4 >= 2020 && number 0 4 <= 2100 && number 5 2 >= 1
    && number 5 2 <= 12 && number 8 2 >= 1 && number 8 2 <= 31
    && number 11 2 <= 23 && number 14 2 <= 59 && number 17 2 <= 60
    && number 20 3 <= 999);
  Alcotest.(check string)
    "health reports the build version" Inn.Version.value
    (json_string_field "version" health);
  Alcotest.(check bool)
    "the version is real, not a placeholder" true
    ((not (String.equal Inn.Version.value "dev"))
    && String.length Inn.Version.value > 0);
  Alcotest.(check string)
    "healthz reports the same version" Inn.Version.value
    (json_string_field "version" healthz);
  Alcotest.(check string)
    "healthz reports the same start time" started_at
    (json_string_field "startedAt" healthz);
  Alcotest.(check int)
    "health reports this process" (Unix.getpid ())
    (match json_member "pid" health with `Int pid -> pid | _ -> -1);
  let uptime json =
    match json_member "uptimeSeconds" json with
    | `Float value -> value
    | `Int value -> float_of_int value
    | _ -> -1.
  in
  let first = uptime health in
  Alcotest.(check bool)
    "uptime is a nonnegative number of seconds" true
    (first >= 0. && first < 86_400.);
  Unix.sleepf 0.02;
  let later = server_json config store "/health" in
  Alcotest.(check string)
    "the start time does not move" started_at
    (json_string_field "startedAt" later);
  Alcotest.(check bool)
    "uptime does not go backwards" true (uptime later >= first);
  Alcotest.(check string)
    "OpenAPI reports the same version" Inn.Version.value
    (json_string_field "version" (json_member "info" (server_json config store "/openapi.json")));
  let ready = server_json config store "/ready" in
  Alcotest.(check bool)
    "ready reports readiness" true (json_member "ready" ready = `Bool true);
  Alcotest.(check string)
    "ready reports the store" "ok" (json_string_field "store" ready)

let test_instructions_point_at_the_docs ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* desc-qv27 *)
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw config) in
  Fun.protect ~finally:(fun () -> run_store (fun _sw -> Store.close store)) @@ fun () ->
  let body = response_body_string (server_get config store "/instructions") in
  List.iter
    (fun fragment ->
      Alcotest.(check bool)
        ("instructions link " ^ fragment) true
        (contains body fragment))
    [
      "/docs"; "/docs/debug"; "/docs/effect"; "/docs/ox"; "/openapi.json";
      "/endpoints"; "/v1/traces"; "/v1/logs"; "/v1/metrics";
    ]
let () =
  let caps = Ox_test.powerbox () in
  Alcotest.run "inn"
    [
      ( "config",
        [
          Alcotest.test_case "defaults are user-level" `Quick
            (test_config_defaults_are_user_level ~caps);
          Alcotest.test_case "environment overrides are explicit" `Quick
            (test_config_env_overrides ~caps);
          Alcotest.test_case "removed settings are refused (bcache-c4p7)" `Quick
            (test_config_rejects_removed_settings ~caps);
          Alcotest.test_case "invalid values are rejected" `Quick
            (test_config_rejects_invalid_values ~caps);
        ] );
      ( "schema",
        [
          Alcotest.test_case "fingerprint matches the version (schm-hnis)"
            `Quick test_schema_fingerprint_matches_version;
          Alcotest.test_case "reopen keeps data (schm-ld81)" `Quick
            (test_schema_reopen_keeps_data ~caps);
          Alcotest.test_case "an unusable segment is recreated (schm-s13e, schm-s52b, bcache-f1le)"
            `Quick (test_schema_mismatch_recreates_database ~caps);
        ] );
      ( "otlp",
        [
          Alcotest.test_case "decodes traces, logs, and metrics" `Quick
            test_otlp_decodes_traces_logs_and_metrics;
          Alcotest.test_case "decoder contracts (otlp-r73z, otlp-6ul3, otlp-8avj, otlp-l0be, otlp-e9t0, otlp-beaj)" `Quick test_otlp_conformance_decoder;
          Alcotest.test_case "HTTP contracts (otlp-dtfh, otlp-2k5g, otlp-ohmj, otlp-qso2, otlp-l754, otlp-zc8b, otlp-u6rw)" `Quick (test_otlp_conformance_handler ~caps);
          Alcotest.test_case "store unavailable retries (otlp-2wg5)" `Quick
            (test_otlp_store_retry ~caps);
        ] );
      ( "store",
        [
          Alcotest.test_case "ingests and queries all signals" `Quick
            (test_store_ingests_and_queries_all_signals ~caps);
        ] );
      ( "segments",
        [
          Alcotest.test_case "the newest data fits the budget (bcache-r1ng, bcache-c4p7, bcache-f1le)"
            `Quick (test_segments_keep_the_newest ~caps);
          Alcotest.test_case "a trace across two segments (bcache-f1le)" `Quick
            (test_trace_across_segments ~caps);
          Alcotest.test_case "ingest limits (bcache-t8nc, bcache-a1x1, bcache-s5kc)"
            `Quick (test_ingest_limits ~caps);
        ] );
      ( "windows",
        [
          Alcotest.test_case "lookback grammar resolves windows (win-nzur, win-e7k8, win-m4ld)"
            `Quick test_list_policy_lookback;
          Alcotest.test_case "defaults and the limit range (win-jee9, win-3ghy, win-xl30)"
            `Quick test_list_policy_limit_and_defaults;
          Alcotest.test_case "cursor round trips and rejects garbage (win-edze, win-xl30)"
            `Quick test_list_policy_cursor;
          Alcotest.test_case "list, stats, facet, service, and store windows (win-nzur, win-e7k8, win-m4ld, win-jee9, win-3ghy)"
            `Quick (test_query_windows ~caps);
        ] );
      ( "pagination",
        [
          Alcotest.test_case "walk 250 logs in pages of 100 (win-edze, win-7xet, win-fl8w, win-xi3q, win-xpfn)"
            `Quick (test_pagination_walk_logs ~caps);
          Alcotest.test_case "cursor pagination on every long list (win-5hgv, win-ggl7, win-7xet, win-xl30)"
            `Quick (test_pagination_endpoints ~caps);
        ] );
      ( "search",
        [ Alcotest.test_case "literal filters and SQL aggregates (sf-*, acc-*)"
            `Quick (test_search_filters_and_exact_stats ~caps);
          Alcotest.test_case "complete 12k spans and 188k logs (acc-*)"
            `Slow (test_exact_queries_above_old_caps ~caps) ] );
      ( "server",
        [
          Alcotest.test_case "handler ingests and queries services" `Quick
            (test_server_handler_ingests_and_queries_services ~caps);
        ] );
      ( "tree",
        [
          Alcotest.test_case
            "assembly order, depth, and running state (tree-tflv, tree-3w92, tree-sih1, tree-78hm, tree-ap92)"
            `Quick test_trace_tree_assembly;
          Alcotest.test_case "missing parents and cycles (tree-ffmn, tree-ap92)"
            `Quick test_trace_tree_warnings;
          Alcotest.test_case
            "trace, span, and summary handlers (tree-o79f, tree-uv04, tree-ddll, tree-6vac)"
            `Quick (test_trace_tree_handlers ~caps);
        ] );
      ( "self-description",
        [
          Alcotest.test_case
            "declarations drive the router, the inventory, and OpenAPI (desc-iduq, desc-de6o)"
            `Quick (test_declarations_drive_the_router ~caps);
          Alcotest.test_case
            "declared responses cover handler output (desc-iduq)" `Quick
            (test_declared_responses_match_handlers ~caps);
          Alcotest.test_case "hidden routes and aliases are documented (desc-dmuw)"
            `Quick (test_hidden_routes_are_documented ~caps);
          Alcotest.test_case
            "docs index, guide content, and the 404 (desc-bqwh, desc-7wwz)"
            `Quick (test_docs_endpoints ~caps);
          Alcotest.test_case "guide instructions (desc-wy48, desc-od3y, desc-62du)"
            `Quick test_guide_content;
          Alcotest.test_case
            "the Ox guide snippet is the compiled source (guide-ox-snippet)"
            `Quick (test_eta_guide_snippet_is_compiled ~caps);
          Alcotest.test_case "health identity (desc-8syr, desc-lqpr)" `Quick
            (test_health_identity ~caps);
          Alcotest.test_case
            "instructions link the guides and the OpenAPI document (desc-qv27)"
            `Quick (test_instructions_point_at_the_docs ~caps);
        ] );
    ]
