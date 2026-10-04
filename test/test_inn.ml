open Inn

let env pairs key = List.assoc_opt key pairs

let hour_ms = 60 * 60 * 1000

(* A fixed ingestion-clock base: retention tests drive the store clock, so no
   test depends on wall-clock time. *)
let base_time = 1_700_000_000_000

let wall_now_ms ~(caps : < Ox_caps.Cap.time ; .. >) () = int_of_float (Ox_caps.Cap_unix.gettimeofday ~caps () *. 1000.)

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
        "db path" "/home/alice/.local/state/inn/telemetry.sqlite"
        config.db_path;
      Alcotest.(check string) "host" "127.0.0.1" config.host;
      Alcotest.(check int) "port" 27687 config.port;
      Alcotest.(check int)
        "logs ttl (ret-mvsc)" 24 config.logs_retention_hours;
      Alcotest.(check int)
        "traces ttl (ret-57b8)" 48 config.traces_retention_hours;
      Alcotest.(check int)
        "metrics ttl (ret-ggir)" 48 config.metrics_retention_hours;
      Alcotest.(check int)
        "prune interval (ret-qd9f)" 300 config.prune_interval_seconds;
      Alcotest.(check int) "max db size" 1024 config.max_db_size_mb

let test_config_env_overrides ~(caps : < Ox_caps.Cap.env ; .. >) () =
  let env =
    env
      [
        ("XDG_STATE_HOME", "/state");
        ("INN_STATE_DIR", "/custom/state");
        ("INN_DB_PATH", "/custom/inn.sqlite");
        ("INN_HOST", "0.0.0.0");
        ("INN_PORT", "39000");
        ("INN_BASE_URL", "http://127.0.0.1:39000");
        ("INN_TRACES_RETENTION_HOURS", "72");
        ("INN_LOGS_RETENTION_HOURS", "6");
        ("INN_METRICS_RETENTION_HOURS", "12");
        ("INN_PRUNE_INTERVAL_SECONDS", "45");
        ("INN_MAX_DB_SIZE_MB", "2048");
      ]
  in
  match Config.resolve ~caps ~env ~home:"/home/alice" () with
  | Error message -> Alcotest.fail message
  | Ok config ->
      Alcotest.(check string) "state dir" "/custom/state" config.state_dir;
      Alcotest.(check string) "db path" "/custom/inn.sqlite" config.db_path;
      Alcotest.(check string) "host" "0.0.0.0" config.host;
      Alcotest.(check int) "port" 39000 config.port;
      Alcotest.(check string)
        "base url" "http://127.0.0.1:39000" config.base_url;
      Alcotest.(check int)
        "traces ttl override (ret-6pix)" 72 config.traces_retention_hours;
      Alcotest.(check int)
        "logs ttl override (ret-6pix)" 6 config.logs_retention_hours;
      Alcotest.(check int)
        "metrics ttl override (ret-6pix)" 12 config.metrics_retention_hours;
      Alcotest.(check int)
        "prune interval override (ret-qd9f)" 45 config.prune_interval_seconds;
      Alcotest.(check int) "max db" 2048 config.max_db_size_mb

let test_config_rejects_legacy_retention ~(caps : < Ox_caps.Cap.env ; .. >) () =
  let env = env [ ("INN_RETENTION_HOURS", "72") ] in
  match Config.resolve ~caps ~env ~home:"/home/alice" () with
  | Ok _ -> Alcotest.fail "INN_RETENTION_HOURS must be rejected"
  | Error message ->
      Alcotest.(check bool)
        "names the traces setting (ret-f1oo)" true
        (contains message "INN_TRACES_RETENTION_HOURS");
      Alcotest.(check bool)
        "names the logs setting (ret-f1oo)" true
        (contains message "INN_LOGS_RETENTION_HOURS");
      Alcotest.(check bool)
        "names the metrics setting (ret-f1oo)" true
        (contains message "INN_METRICS_RETENTION_HOURS")

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
  check_invalid "INN_LOGS_RETENTION_HOURS" "0";
  check_invalid "INN_TRACES_RETENTION_HOURS" "-3";
  check_invalid "INN_METRICS_RETENTION_HOURS" "many";
  check_invalid "INN_PRUNE_INTERVAL_SECONDS" "0";
  check_invalid "INN_MAX_DB_SIZE_MB" "huge"

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

let temp_db_path ~(caps : < Ox_caps.Cap.fs_write ; Ox_caps.Cap.tmp ; .. >) () =
  let db_path = Ox_caps.Cap_stdlib.Filename.temp_file ~caps "inn-test-" ".sqlite" in
  Ox_caps.Cap_sys.remove ~caps db_path;
  db_path

let test_config ?(port = Config.default_port) ?(traces_retention_hours = 48)
    ?(logs_retention_hours = 24) ?(metrics_retention_hours = 48)
    ?(prune_interval_seconds = 300) ?(max_db_size_mb = 1024) db_path =
  {
    Config.state_dir = Filename.dirname db_path;
    db_path;
    host = "127.0.0.1";
    port;
    base_url = Printf.sprintf "http://127.0.0.1:%d" port;
    traces_retention_hours;
    logs_retention_hours;
    metrics_retention_hours;
    prune_interval_seconds;
    max_db_size_mb;
  }

let temp_config ~(caps : < Ox_caps.Cap.fs_write ; Ox_caps.Cap.tmp ; .. >) ?port ?traces_retention_hours ?logs_retention_hours
    ?metrics_retention_hours ?prune_interval_seconds ?max_db_size_mb () =
  test_config ?port ?traces_retention_hours ?logs_retention_hours
    ?metrics_retention_hours ?prune_interval_seconds ?max_db_size_mb
    ((temp_db_path ~caps) ())

let cleanup_config ~(caps : < Ox_caps.Cap.fs_write ; .. >) config =
  List.iter
    (fun path -> if Sys.file_exists path then Ox_caps.Cap_sys.remove ~caps path)
    [ config.Config.db_path; config.db_path ^ "-wal"; config.db_path ^ "-shm" ]

let active_store_switch = ref None

let run_store_scope f =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let previous = !active_store_switch in
  active_store_switch := Some sw;
  Fun.protect ~finally:(fun () -> active_store_switch := previous) f

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

module Test_foreign = struct
  module T = Ox_sql.Table.Make (struct
    let name = "other_app"
  end)

  include T

  let id = column "id" Ox_sql.text
end

module Test_spans = struct
  module T = Ox_sql.Table.Make (struct
    let name = "spans"
  end)

  include T

  let id = column "id" Ox_sql.text
end

module Test_span_attributes = struct
  module T = Ox_sql.Table.Make (struct
    let name = "span_attributes"
  end)

  include T

  let owner_id = column "owner_id" Ox_sql.text
end

module Test_logs = struct
  module T = Ox_sql.Table.Make (struct
    let name = "logs"
  end)

  include T

  let id = column "id" Ox_sql.text
end

module Test_log_attributes = struct
  module T = Ox_sql.Table.Make (struct
    let name = "log_attributes"
  end)

  include T

  let owner_id = column "owner_id" Ox_sql.text
end

module Test_metric_points = struct
  module T = Ox_sql.Table.Make (struct
    let name = "metric_points"
  end)

  include T

  let id = column "id" Ox_sql.text
end

module Test_metric_attributes = struct
  module T = Ox_sql.Table.Make (struct
    let name = "metric_attributes"
  end)

  include T

  let owner_id = column "owner_id" Ox_sql.text
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

let create_foreign_database ~(caps : < Ox_caps.Cap.time ; .. >) path =
  (run_test_db ~caps) path (fun pool ->
      let ( let* ) = Result.bind in
      let schema =
        Ox_sql.Ox_schema.(
          compile
            (create_table Test_foreign.table
               [ column ~primary_key:true Test_foreign.id ]))
      in
      let* () = Ox_sql.Pool.Typed.run_schema pool schema in
      let insert =
        Ox_sql.Insert.(
          into Test_foreign.table
          |> value Test_foreign.id "row-1"
          |> compile)
      in
      let* _ = Ox_sql.Pool.Typed.execute_compiled pool insert in
      Result.ok ())

let foreign_rows ~(caps : < Ox_caps.Cap.time ; .. >) path =
  (run_test_db ~caps) path (fun pool ->
      Ox_sql.Pool.Typed.select pool
        (Ox_sql.Select.compile
           Ox_sql.Select.(
             from Test_foreign.table (Ox_sql.Projection.one Test_foreign.id))))

(* Attribute rows whose owner row is gone (ret-hy7e). *)
let orphan_attribute_rows ~(caps : < Ox_caps.Cap.time ; .. >) path =
  (run_test_db ~caps) path (fun pool ->
      let ( let* ) = Result.bind in
      let owners table owner_id =
        Ox_sql.Pool.Typed.select pool
          (Ox_sql.Select.compile
             Ox_sql.Select.(from table (Ox_sql.Projection.one owner_id)))
      in
      let ids table id =
        Ox_sql.Pool.Typed.select pool
          (Ox_sql.Select.compile
             Ox_sql.Select.(from table (Ox_sql.Projection.one id)))
      in
      let count_orphans owners ids =
        let ids = List.sort_uniq String.compare ids in
        List.fold_left
          (fun total owner -> if List.mem owner ids then total else total + 1)
          0 owners
      in
      let* span_owners = owners Test_span_attributes.table Test_span_attributes.owner_id in
      let* span_ids = ids Test_spans.table Test_spans.id in
      let* log_owners = owners Test_log_attributes.table Test_log_attributes.owner_id in
      let* log_ids = ids Test_logs.table Test_logs.id in
      let* metric_owners =
        owners Test_metric_attributes.table Test_metric_attributes.owner_id
      in
      let* metric_ids = ids Test_metric_points.table Test_metric_points.id in
      Result.ok
        (count_orphans span_owners span_ids + count_orphans log_owners log_ids
       + count_orphans metric_owners metric_ids))

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

let free_port ~(caps : < Ox_caps.Cap.network ; .. >) () =
  let socket = Ox_caps.Cap_unix.socket ~caps Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX _ -> Alcotest.fail "expected an inet socket")

let http_get_opt ~sw:_ ~net:_ ~clock:_ client url =
  match Ox_http.Client.request client ~method_:"GET" ~url () with
  | Ok response -> Some (response.status, Bytes.to_string response.body)
  | Error _ -> None

let http_get ~sw ~net ~clock client url =
  match http_get_opt ~sw ~net ~clock client url with
  | Some value -> value
  | None -> Alcotest.failf "GET %s failed" url

let wait_until ~(caps : < Ox_caps.Cap.time ; .. >) ~clock ~timeout_seconds predicate =
  let deadline = Ox_caps.Cap_unix.gettimeofday ~caps () +. timeout_seconds in
  let rec loop () =
    if predicate () then true
    else if Ox_caps.Cap_unix.gettimeofday ~caps () > deadline then false
    else (
      Eio.Time.sleep clock 0.05;
      loop ())
  in
  loop ()

(* Schema ---------------------------------------------------------------- *)

(* Recorded together with [Store.schema_version]: change one and you must
   change the other (schm-hnis). *)
let recorded_schema_fingerprint = "01081774dc377e7be68d0b468b43ce6c"

let test_schema_fingerprint_matches_version () =
  Alcotest.(check int) "schema version" 5 Store.schema_version;
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
  (write_schema_version ~caps) config.Config.db_path "0";
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
  (match List.rev !messages with
  | [ message ] ->
      Alcotest.(check bool)
        "warning names the old version (schm-s52b)" true
        (contains message "schema version 0");
      Alcotest.(check bool)
        "warning names the new version (schm-s52b)" true
        (contains message (string_of_int Store.schema_version));
      Alcotest.(check bool)
        "warning names the database path (schm-s52b)" true
        (contains message config.Config.db_path)
  | messages ->
      Alcotest.failf "expected one schema warning, got %d" (List.length messages))

let test_schema_refuses_foreign_database ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  (create_foreign_database ~caps) config.Config.db_path;
  (match run_store_error (fun sw -> Store.open_ ~caps ~sw config) with
  | Some message ->
      Alcotest.(check bool)
        "error names the missing metadata table (schm-xkk2)" true
        (contains message "inn_meta")
  | None -> Alcotest.fail "expected the store to refuse a foreign database");
  Alcotest.(check bool)
    "the foreign file is still there (schm-xkk2)" true
    (Sys.file_exists config.db_path);
  Alcotest.(check (list string))
    "the foreign file still holds its data (schm-xkk2)" [ "row-1" ]
    ((foreign_rows ~caps) config.Config.db_path);
  (* A file that is not SQLite at all is refused for the same reason. *)
  let other = test_config ((temp_db_path ~caps) ()) in
  Fun.protect
    ~finally:(fun () -> (cleanup_config ~caps) other)
    (fun () ->
      let contents = "not a database\n" in
      let channel = Ox_caps.Cap_stdlib.open_out_bin ~caps other.Config.db_path in
      output_string channel contents;
      close_out channel;
      (match run_store_error (fun sw -> Store.open_ ~caps ~sw other) with
      | Some message ->
          Alcotest.(check bool)
            "error says the file is not a database (schm-xkk2)" true
            (contains message "not an SQLite database")
      | None -> Alcotest.fail "expected the store to refuse a non-SQLite file");
      let channel = Ox_caps.Cap_stdlib.open_in_bin ~caps other.Config.db_path in
      let read = really_input_string channel (in_channel_length channel) in
      close_in channel;
      Alcotest.(check string)
        "the non-SQLite file is untouched (schm-xkk2)" contents read)

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
    "stats expose the configured log ttl (ret-eeb1)" 24
    stats.retention.logs_ttl_hours;
  Alcotest.(check int)
    "stats expose the configured trace ttl (ret-eeb1)" 48
    stats.retention.traces_ttl_hours;
  Alcotest.(check int)
    "stats expose the configured metric ttl (ret-eeb1)" 48
    stats.retention.metrics_ttl_hours;
  Alcotest.(check int)
    "stats expose the prune interval (ret-eeb1)" 300
    stats.retention.prune_interval_seconds;
  Alcotest.(check int)
    "stats expose the size cap (ret-eeb1)" 1024 stats.retention.max_db_size_mb;
  Alcotest.(check bool)
    "stats expose live bytes (ret-eeb1)" true (stats.retention.live_bytes > 0);
  Alcotest.(check bool)
    "no prune report before the first prune (ret-eeb1)" true
    (Option.is_none stats.retention.last_prune)

(* Retention ------------------------------------------------------------- *)

let test_prune_per_signal_ttl ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  let clock = ref base_time in
  let after_logs, after_traces, stats_after_logs, stats_after_traces =
    (with_store ~caps) ~now_ms:(fun () -> !clock) config (fun store ->
        let ( let* ) = Result.bind in
        let* _ = Store.ingest_traces store [ test_span () ] in
        let* _ = Store.ingest_logs store [ test_log () ] in
        let* _ = Store.ingest_metrics store [ test_metric () ] in
        let* after_logs = Store.prune ~now_ms:(base_time + (25 * hour_ms)) store in
        let* stats_after_logs = Store.stats store in
        let* after_traces =
          Store.prune ~now_ms:(base_time + (49 * hour_ms)) store
        in
        let* stats_after_traces = Store.stats store in
        Result.ok
          (after_logs, after_traces, stats_after_logs, stats_after_traces))
  in
  Alcotest.(check int)
    "logs expire after 24h (ret-mvsc)" 1 after_logs.Model.logs;
  Alcotest.(check int)
    "traces survive 24h (ret-57b8)" 0 after_logs.Model.traces;
  Alcotest.(check int)
    "metrics survive 24h (ret-ggir)" 0 after_logs.Model.metric_points;
  Alcotest.(check int) "logs left after 24h" 0 stats_after_logs.Model.logs;
  Alcotest.(check int) "traces left after 24h" 1 stats_after_logs.Model.traces;
  Alcotest.(check int)
    "metrics left after 24h" 1 stats_after_logs.Model.metric_points;
  Alcotest.(check int)
    "traces expire after 48h (ret-57b8)" 1 after_traces.Model.traces;
  Alcotest.(check int) "spans go with their trace" 1 after_traces.Model.spans;
  Alcotest.(check int)
    "metrics expire after 48h (ret-ggir)" 1 after_traces.Model.metric_points;
  Alcotest.(check int) "traces left after 48h" 0 stats_after_traces.Model.traces;
  Alcotest.(check int) "spans left after 48h" 0 stats_after_traces.Model.spans;
  Alcotest.(check int)
    "metrics left after 48h" 0 stats_after_traces.Model.metric_points

let test_prune_uses_ingestion_time ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  let clock = ref base_time in
  let early, late, left =
    (with_store ~caps) ~now_ms:(fun () -> !clock) config (fun store ->
        let ( let* ) = Result.bind in
        let* _ =
          Store.ingest_logs store
            [
              test_log ~timestamp_ms:0 ~body:"client epoch" ();
              test_log
                ~timestamp_ms:(base_time + (1000 * hour_ms))
                ~body:"client future" ();
            ]
        in
        let* early = Store.prune ~now_ms:(base_time + (1 * hour_ms)) store in
        let* late = Store.prune ~now_ms:(base_time + (25 * hour_ms)) store in
        let* left = Store.stats store in
        Result.ok (early, late, left))
  in
  Alcotest.(check int)
    "client timestamps do not expire data early (ret-ovry)" 0 early.Model.logs;
  Alcotest.(check int)
    "both rows expire on ingestion time (ret-ovry)" 2 late.Model.logs;
  Alcotest.(check int) "no logs left (ret-ovry)" 0 left.Model.logs

let test_prune_keeps_trace_with_fresh_span ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  let clock = ref base_time in
  let kept_trace = "cccccccccccccccccccccccccccccccc" in
  let stale_trace = "dddddddddddddddddddddddddddddddd" in
  let report, stats, kept, gone, attr_spans, attr_traces =
    (with_store ~caps) ~now_ms:(fun () -> !clock) config (fun store ->
        let ( let* ) = Result.bind in
        let* _ =
          Store.ingest_traces store
            [
              test_span ~trace_id:kept_trace ~span_id:"1111111111111111"
                ~attributes:[ ("route", "/kept") ] ();
            ]
        in
        let* _ =
          Store.ingest_traces store
            [
              test_span ~trace_id:stale_trace ~span_id:"2222222222222222"
                ~attributes:[ ("route", "/gone") ] ();
            ]
        in
        clock := base_time + (47 * hour_ms);
        let* _ =
          Store.ingest_traces store
            [
              test_span ~trace_id:kept_trace ~span_id:"3333333333333333"
                ~attributes:[ ("route", "/kept") ] ();
            ]
        in
        let* report = Store.prune ~now_ms:(base_time + (49 * hour_ms)) store in
        let* stats = Store.stats store in
        let* kept = Store.get_trace store kept_trace in
        let* gone = Store.get_trace store stale_trace in
        let* attr_spans =
          Store.search_spans
            {
              service = None;
              trace_id = None;
              operation = None;
              parent_operation = None;
              status = None;
              attrs = [ ("route", "/gone") ];
              window = all_window;
              cursor = None;
              limit = 10;
            }
            store
          |> Result.map page_items
        in
        let* attr_traces =
          Store.search_traces
            {
              service = None;
              operation = None;
              status = None;
              attrs = [ ("route", "/gone") ];
              window = all_window;
              cursor = None;
              limit = 10;
            }
            store
          |> Result.map page_items
        in
        Result.ok (report, stats, kept, gone, attr_spans, attr_traces))
  in
  Alcotest.(check int)
    "only the stale trace is deleted (ret-4hhb)" 1 report.Model.traces;
  Alcotest.(check int) "stale spans are deleted" 1 report.Model.spans;
  Alcotest.(check int) "the fresh-span trace survives" 1 stats.Model.traces;
  Alcotest.(check int) "its spans survive" 2 stats.Model.spans;
  Alcotest.(check bool) "fresh-span trace is readable" true (Option.is_some kept);
  Alcotest.(check bool) "stale trace is gone" true (Option.is_none gone);
  Alcotest.(check int)
    "attribute search does not return the deleted trace (ret-hy7e)" 0
    (List.length attr_spans);
  Alcotest.(check int)
    "trace search does not return the deleted trace (ret-hy7e)" 0
    (List.length attr_traces);
  Alcotest.(check int)
    "no orphaned attribute rows (ret-hy7e)" 0
    ((orphan_attribute_rows ~caps) config.Config.db_path)

let test_prune_batches_large_backlog ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  let clock = ref base_time in
  let bulk_logs = 5_000 in
  let report, stats =
    (with_store ~caps) ~now_ms:(fun () -> !clock) config (fun store ->
        let ( let* ) = Result.bind in
        let logs =
          List.init bulk_logs (fun index ->
              test_log ~body:(Printf.sprintf "bulk-%d" index) ~attributes:[]
                ~resource:[] ())
        in
        let* _ = Store.ingest_logs store logs in
        let* report = Store.prune ~now_ms:(base_time + (25 * hour_ms)) store in
        let* stats = Store.stats store in
        Result.ok (report, stats))
  in
  Alcotest.(check int)
    "a multi-batch backlog is fully pruned (ret-xbij)" bulk_logs
    report.Model.logs;
  Alcotest.(check int) "no logs left (ret-xbij)" 0 stats.Model.logs

let test_ingest_does_not_prune ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config = (temp_config ~caps) () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  let clock = ref base_time in
  let after_ingest, report, after_prune =
    (with_store ~caps) ~now_ms:(fun () -> !clock) config (fun store ->
        let ( let* ) = Result.bind in
        let* _ = Store.ingest_logs store [ test_log ~body:"first" () ] in
        clock := base_time + (25 * hour_ms);
        let* _ = Store.ingest_logs store [ test_log ~body:"second" () ] in
        let* after_ingest = Store.stats store in
        let* report = Store.prune ~now_ms:(base_time + (25 * hour_ms)) store in
        let* after_prune = Store.stats store in
        Result.ok (after_ingest, report, after_prune))
  in
  Alcotest.(check int)
    "expired data stays until the pruner runs (ret-rkrf)" 2
    after_ingest.Model.logs;
  Alcotest.(check int)
    "the pruner deletes the expired row (ret-rkrf)" 1 report.Model.logs;
  Alcotest.(check int) "the fresh row stays (ret-rkrf)" 1 after_prune.Model.logs

let test_prune_size_cap_removes_only_oldest ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let max_db_size_mb = 1 in
  let config = (temp_config ~caps) ~max_db_size_mb () in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  let clock = ref base_time in
  let old_logs = 150 and new_logs = 20 in
  let body = String.make (8 * 1024) 'x' in
  let report, second_report, stats, new_left, old_left =
    (with_store ~caps) ~now_ms:(fun () -> !clock) config (fun store ->
        let ( let* ) = Result.bind in
        let old =
          List.init old_logs (fun index ->
              test_log ~service_name:"old"
                ~body:(Printf.sprintf "old-%d-%s" index body)
                ~attributes:[] ~resource:[] ())
        in
        let* _ = Store.ingest_logs store old in
        clock := base_time + (1 * hour_ms);
        let fresh =
          List.init new_logs (fun index ->
              test_log ~service_name:"new"
                ~body:(Printf.sprintf "new-%d-%s" index body)
                ~attributes:[] ~resource:[] ())
        in
        let* _ = Store.ingest_logs store fresh in
        let* before = Store.stats store in
        if before.Model.retention.live_bytes <= max_db_size_mb * 1024 * 1024 then
          Alcotest.failf
            "test setup: live bytes %d are not over the cap"
            before.retention.live_bytes;
        let* report = Store.prune ~now_ms:(base_time + (1 * hour_ms)) store in
        let* second_report =
          Store.prune ~now_ms:(base_time + (1 * hour_ms)) store
        in
        let* stats = Store.stats store in
        let* new_left =
          Store.list_logs
            {
              service = Some "new";
              severity = None;
              contains = None;
              window = all_window;
              cursor = None;
              limit = 1000;
            }
            store
          |> Result.map page_items
        in
        let* old_left =
          Store.list_logs
            {
              service = Some "old";
              severity = None;
              contains = None;
              window = all_window;
              cursor = None;
              limit = 1000;
            }
            store
          |> Result.map page_items
        in
        Result.ok (report, second_report, stats, new_left, old_left))
  in
  Alcotest.(check bool)
    "the size cap triggers (ret-zjzs)" true report.Model.size_cap_triggered;
  Alcotest.(check bool)
    "the size cap deletes rows (ret-bizv)" true (report.Model.logs > 0);
  Alcotest.(check bool)
    "the size cap does not delete everything (ret-bizv)" true
    (report.Model.logs < old_logs + new_logs);
  Alcotest.(check int)
    "the newest logs survive (ret-bizv)" new_logs (List.length new_left);
  Alcotest.(check bool)
    "the oldest logs are the ones deleted (ret-bizv)" true
    (List.length old_left < old_logs);
  Alcotest.(check bool)
    "live data is under the cap (ret-zjzs)" true
    (stats.Model.retention.live_bytes <= max_db_size_mb * 1024 * 1024);
  Alcotest.(check int)
    "a second prune with nothing to do deletes nothing (ret-zjzs)" 0
    (second_report.Model.logs + second_report.traces
   + second_report.metric_points + second_report.spans);
  Alcotest.(check bool)
    "a second prune does not trigger the size cap (ret-zjzs)" false
    second_report.Model.size_cap_triggered

let test_stats_reports_retention ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let config =
    (temp_config ~caps) ~traces_retention_hours:12 ~logs_retention_hours:6
      ~metrics_retention_hours:18 ~prune_interval_seconds:60
      ~max_db_size_mb:512 ()
  in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  let clock = ref base_time in
  let stats =
    (with_store ~caps) ~now_ms:(fun () -> !clock) config (fun store ->
        let ( let* ) = Result.bind in
        let* _ = Store.ingest_logs store [ test_log () ] in
        let* _ = Store.prune ~now_ms:(base_time + (7 * hour_ms)) store in
        Store.stats store)
  in
  let retention = stats.Model.retention in
  Alcotest.(check int)
    "stats ttl traces (ret-eeb1)" 12 retention.Model.traces_ttl_hours;
  Alcotest.(check int)
    "stats ttl logs (ret-eeb1)" 6 retention.Model.logs_ttl_hours;
  Alcotest.(check int)
    "stats ttl metrics (ret-eeb1)" 18 retention.Model.metrics_ttl_hours;
  Alcotest.(check int)
    "stats prune interval (ret-eeb1)" 60 retention.Model.prune_interval_seconds;
  Alcotest.(check int)
    "stats size cap (ret-eeb1)" 512 retention.Model.max_db_size_mb;
  Alcotest.(check bool)
    "stats live bytes (ret-eeb1)" true (retention.Model.live_bytes > 0);
  (match retention.Model.last_prune with
  | None -> Alcotest.fail "expected a last prune report (ret-eeb1)"
  | Some report ->
      Alcotest.(check int)
        "report time (ret-eeb1)" (base_time + (7 * hour_ms))
        report.Model.pruned_at_ms;
      Alcotest.(check int) "report log rows (ret-eeb1)" 1 report.Model.logs;
      Alcotest.(check bool)
        "report size cap flag (ret-eeb1)" false report.Model.size_cap_triggered);
  let json = Model.stats_to_json stats in
  let retention_json = Yojson.Safe.Util.member "retention" json in
  Alcotest.(check int)
    "json log ttl (ret-eeb1)" 6
    Yojson.Safe.Util.(member "logsTtlHours" retention_json |> to_int);
  Alcotest.(check bool)
    "json last prune (ret-eeb1)" true
    (Yojson.Safe.Util.member "lastPrune" retention_json <> `Null)

(* Server ---------------------------------------------------------------- *)

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
      let ai_calls =
        run_server_effect
          (Inn.Server.handler config store
             (request
                ~target:"/ai/calls?model=gpt-test&provider=openai&lookback=all" ()))
      in
      Alcotest.(check int)
        "ai calls status" 200 (Ox_http.Server.Response.status ai_calls);
      Alcotest.(check int)
        "ai calls length" 1
        (ai_calls |> response_json |> json_list_length "calls");
      let ai_call =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/ai/calls/dddddddddddddddd" ()))
      in
      Alcotest.(check int)
        "ai call status" 200 (Ox_http.Server.Response.status ai_call);
      let ai_stats =
        run_server_effect
          (Inn.Server.handler config store
             (request ~target:"/ai/stats?groupBy=model&agg=count&lookback=all" ()))
      in
      Alcotest.(check int)
        "ai stats status" 200 (Ox_http.Server.Response.status ai_stats);
      Alcotest.(check int)
        "ai stats length" 1
        (ai_stats |> response_json |> json_list_length "stats");
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
        "stats body carries the retention section (ret-eeb1)" true
        (Yojson.Safe.Util.member "retention" (response_json stats) <> `Null);
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

let test_server_pruner_prunes_without_ingest ~(caps : < Ox_caps.Cap.env ; Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.network ; Ox_caps.Cap.signal ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  let port = (free_port ~caps) () in
  let config =
    (temp_config ~caps) ~port ~traces_retention_hours:1 ~logs_retention_hours:1
      ~metrics_retention_hours:1 ~prune_interval_seconds:1 ()
  in
  Fun.protect ~finally:(fun () -> (cleanup_config ~caps) config) @@ fun () ->
  (* Telemetry that expired while the server was not running (ret-sbgj). *)
  (with_store ~caps)
    ~now_ms:(fun () -> (wall_now_ms ~caps) () - (2 * hour_ms))
    config
    (fun store ->
      let ( let* ) = Result.bind in
      let* _ =
        Store.ingest_logs store [ test_log ~body:"expired while stopped" () ]
      in
      Result.ok ());
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.first
    (fun () -> Inn.Server.run ~caps ~sw ~env config)
    (fun () ->
      let client = Ox_http.Client.create ~sw ~net ~clock () in
      let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
      let stats_json () =
        let status, body = http_get ~sw ~net ~clock client (base_url ^ "/stats") in
        Alcotest.(check int) "stats status" 200 status;
        Yojson.Safe.from_string body
      in
      let log_count () =
        Yojson.Safe.Util.(member "logs" (stats_json ()) |> to_int)
      in
      Alcotest.(check bool)
        "server is up" true
        ((wait_until ~caps) ~clock ~timeout_seconds:10.0 (fun () ->
             match http_get_opt ~sw ~net ~clock client (base_url ^ "/health") with
             | Some (status, _) -> status = 200
             | None -> false));
      Alcotest.(check bool)
        "the startup pass prunes without ingest (ret-sj15, ret-sbgj)" true
        ((wait_until ~caps) ~clock ~timeout_seconds:10.0 (fun () -> log_count () = 0));
      let retention =
        Yojson.Safe.Util.member "retention" (stats_json ())
      in
      Alcotest.(check int)
        "stats expose the active log ttl (ret-eeb1)" 1
        Yojson.Safe.Util.(member "logsTtlHours" retention |> to_int);
      Alcotest.(check bool)
        "stats expose the last prune (ret-eeb1)" true
        (Yojson.Safe.Util.member "lastPrune" retention <> `Null);
      (* A later interval pass prunes data that arrives while the server keeps
         running without any ingest request (ret-sj15). *)
      run_store_in ~sw ~clock
        (fun sw -> Store.with_db ~caps ~sw
           ~now_ms:(fun () -> (wall_now_ms ~caps) () - (2 * hour_ms))
           config
           (fun store ->
             let ( let* ) = Result.bind in
             let* _ =
               Store.ingest_logs store [ test_log ~body:"expired later" () ]
             in
             Result.ok ()));
      Alcotest.(check bool)
        "the expired row becomes visible" true
        ((wait_until ~caps) ~clock ~timeout_seconds:5.0 (fun () -> log_count () = 1));
      Alcotest.(check bool)
        "the interval pass prunes it (ret-sj15)" true
        ((wait_until ~caps) ~clock ~timeout_seconds:10.0 (fun () -> log_count () = 0)))

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
  Alcotest.(check int) "AI status ok includes unset (otlp-u6rw)" 1
    (json_list_length "calls" (get "/api/ai/calls?status=ok&lookback=all"));
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
      ignore
        (check_walk ~config ~store ~name:"calls" ~key:span_key ~limit:2
           "/ai/calls?lookback=all");
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
  let query_started = Ox_caps.Cap_unix.gettimeofday ~caps () in
  Alcotest.(check int) "acc-gkoz old AI call beyond 10k newer spans" 1
    (List.length (response "/ai/calls?lookback=all&model=old-model" "calls"));
  Alcotest.(check int) "acc-879n old trace beyond 10k spans" 1
    (List.length (response
      "/traces/search?lookback=all&text=needle-old-call&attr.http.method=GET"
      "traces"));
  count_group (response "/traces/stats?lookback=all&groupBy=service&agg=count"
    "stats") "svc" span_count;
  let partition_stats = response
    "/traces/stats?lookback=all&groupBy=attr.partition&agg=count&limit=200" "stats" in
  Alcotest.(check int) "acc-1ccu single SQL grouping for 200 attribute values"
    200 (List.length partition_stats);
  count_group partition_stats "bucket-000" 61;
  let ai_stats = response
    "/ai/stats?lookback=all&groupBy=status&agg=p95_duration" "stats" in
  Alcotest.(check bool) "acc-7kkc nearest-rank of 101 AI durations" true
    (List.exists (fun row -> json_member "group" row = `String "ok"
      && json_member "count" row = `Int 101
      && json_member "value" row = `Float 96.) ai_stats);
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
    true (Ox_caps.Cap_unix.gettimeofday ~caps () -. query_started < 30.)

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
  check "srch-w4sn duration AI call search" 1
    "/ai/calls?lookback=all&minDurationMs=5" "calls";
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
  Alcotest.(check int) "acc AI prompt literal substring" 1
    (n "/ai/calls?lookback=all&text=%25_%5C" "calls");
  Alcotest.(check int) "srch-oylo text excludes model metadata" 0
    (n "/traces/search?lookback=all&text=model-x" "traces");
  Alcotest.(check int) "srch-oylo trace text finds child AI prompt" 1
    (n "/traces/search?lookback=all&text=Special%25_%5C" "traces");
  check "srch-oylo text finds AI response" 1
    "/traces/search?lookback=all&text=responsecontent" "traces";
  check "srch-oylo text finds AI tool result" 1
    "/traces/search?lookback=all&text=TOOLCONTENT" "traces";
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
  stat "srch-w4sn minDuration AI stats"
    "/ai/stats?groupBy=model&agg=count&lookback=all&minDurationMs=5"
    "model-x" 1 1.;
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
  let ai_stats = json_list "stats" (server_json config store
    "/ai/stats?groupBy=model&agg=p95_duration&lookback=all") in
  Alcotest.(check bool) "acc-7kkc exact nearest-rank p95" true
    (List.exists (fun row -> json_member "group" row = `String "model-x"
      && json_member "value" row = `Float 10.) ai_stats);
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
      "/ai/stats?groupBy=model&agg=count";
      "/facets?type=traces&field=service" ];
  let inventory = json_list "endpoints" (server_json config store "/endpoints") in
  let trace_route = List.find_opt (fun endpoint ->
    json_member "path" endpoint = `String "/traces/search") inventory in
  let route = match trace_route with Some route -> route
    | None -> Alcotest.fail "trace search missing from inventory" in
  let filters = json_list "filters" route in
  Alcotest.(check bool) "srch-z5cu inventory exposes filters" true
    (List.mem (`String "attrContains.<key>") filters
      && List.mem (`String "text") filters);
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

(* Test-only probe: the store never leaves a trace without its summary row, so
   the 404 rule needs one deleted by hand (tree-ddll). *)
module Test_trace_summaries = struct
  module T = Ox_sql.Table.Make (struct
    let name = "trace_summaries"
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
          (delete_trace_summary ~caps) config.Config.db_path trace_id;
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

(* AI calls -------------------------------------------------------------- *)

let ai_attrs pairs = List.map (fun (key, value) -> (key, `String value)) pairs

let ai_span ?(trace_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    ?(span_id = "b000000000000001") ?(parent_span_id = None)
    ?(service_name = "ai-app") ?(operation_name = "chat") ?(status = "ok")
    ?(start_ms = base_time) ?(duration_ms = 10.) ?(running = false)
    ?(attributes : Model.attrs = []) () =
  let start_time_ns = start_ms * 1_000_000 in
  let span =
    test_span ~trace_id ~span_id ~parent_span_id ~service_name ~operation_name
      ~status ~timestamp_ms:start_ms ()
  in
  {
    span with
    Model.end_time_ns =
      (if running then 0
       else start_time_ns + int_of_float (duration_ms *. 1_000_000.));
    duration_ms;
    attributes;
  }

(* An Ox gen_ai chat span: what ox_ai emits through provider_telemetry.ml. *)
let ox_chat_span ?(trace_id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
    ?(span_id = "e000000000000001") ?(parent_span_id = None) () =
  ai_span ~trace_id ~span_id ~parent_span_id ~service_name:"ox-app"
    ~operation_name:"chat gpt-4o" ~duration_ms:5_000.
    ~attributes:
      (ai_attrs
         [
           ("gen_ai.operation.name", "chat");
           ("gen_ai.provider.name", "openai");
           ("gen_ai.request.model", "gpt-4o");
           ("gen_ai.response.model", "gpt-4o-2024-08-06");
           ("gen_ai.response.finish_reasons", "stop");
           ("gen_ai.response.time_to_first_chunk", "0.250");
           ("gen_ai.usage.input_tokens", "120");
           ("gen_ai.usage.output_tokens", "48");
           ( "gen_ai.input.messages",
             {|[{"role":"user","content":"book a flight"}]|} );
           ( "gen_ai.output.messages",
             {|[{"role":"assistant","content":[{"type":"text","text":"booked"}]}]|}
           );
           ("ai.telemetry.functionId", "trip.plan");
           ("ai.telemetry.metadata.sessionId", "session-3");
           ("gen_ai.user.id", "user-7");
         ])
    ()

let ox_tool_span ?(trace_id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
    ?(span_id = "e000000000000002") ?(parent_span_id = Some "e000000000000001")
    () =
  ai_span ~trace_id ~span_id ~parent_span_id ~service_name:"ox-app"
    ~operation_name:"execute_tool get_weather" ~duration_ms:5.
    ~attributes:
      (ai_attrs
         [
           ("gen_ai.operation.name", "execute_tool");
           ("gen_ai.tool.name", "get_weather");
           ("gen_ai.tool.call.arguments", {|{"city":"Paris"}|});
           ("gen_ai.tool.call.result", "sunny");
         ])
    ()

let kind_of spans span =
  match
    List.find_opt (fun (candidate, _) -> candidate == span) (Ai.classify_spans spans)
  with
  | Some (_, kind) -> Ai.classification_to_string kind
  | None -> Alcotest.fail "span is not in the classified list"

let test_ai_classification () =
  (* aic-cw6h, aic-jupv, aic-qs41 *)
  let ox = ox_chat_span () in
  Alcotest.(check string)
    "aic-cw6h a GenAI chat span is an AI call" "call"
    (kind_of [ ox ] ox);
  let effect_chat =
    ai_span ~trace_id:"ffffffffffffffffffffffffffffffff"
      ~span_id:"f000000000000001" ~service_name:"effect-app"
      ~operation_name:"openai.chat"
      ~attributes:
        (ai_attrs
           [ ("gen_ai.operation.name", "chat"); ("gen_ai.system", "openai") ])
      ()
  in
  let tool =
    ai_span ~trace_id:"ffffffffffffffffffffffffffffffff"
      ~span_id:"f000000000000002" ~parent_span_id:(Some "f000000000000001")
      ~service_name:"effect-app" ~operation_name:"execute_tool get_weather"
      ~attributes:
        (ai_attrs
           [
             ("gen_ai.operation.name", "execute_tool");
             ("gen_ai.tool.name", "get_weather");
           ])
      ()
  in
  Alcotest.(check string)
    "aic-qs41 gen_ai execute_tool is a tool execution, not a call" "tool"
    (kind_of [ effect_chat; tool ] tool);
  Alcotest.(check string) "aic-cw6h its parent GenAI span is still the call"
    "call" (kind_of [ effect_chat; tool ] effect_chat);
  Alcotest.(check bool) "aic-qs41 a tool span is not AI-detected" false
    (Ai.is_ai_span tool);
  Alcotest.(check int) "aic-q5qt the tool call is counted on the call" 1
    (Ai.call_of_span ~children:[ tool ] effect_chat).tool_call_count;
  let vercel =
    ai_span ~trace_id:"abababababababababababababababab"
      ~span_id:"a000000000000001" ~service_name:"vercel-app"
      ~operation_name:"ai.generateText"
      ~attributes:
        (ai_attrs
           [
             ("ai.operationId", "ai.generateText");
             ("ai.model.id", "gpt-4o-mini");
             ("ai.model.provider", "openai");
           ])
      ()
  in
  let do_generate =
    ai_span ~trace_id:"abababababababababababababababab"
      ~span_id:"a000000000000002" ~parent_span_id:(Some "a000000000000001")
      ~service_name:"vercel-app" ~operation_name:"ai.generateText.doGenerate"
      ~attributes:
        (ai_attrs
           [
             ("ai.operationId", "ai.generateText.doGenerate");
             ("ai.model.id", "gpt-4o-mini");
           ])
      ()
  in
  let vercel_tool =
    ai_span ~trace_id:"abababababababababababababababab"
      ~span_id:"a000000000000003" ~parent_span_id:(Some "a000000000000001")
      ~service_name:"vercel-app" ~operation_name:"ai.toolCall"
      ~attributes:
        (ai_attrs
           [
             ("ai.operationId", "ai.toolCall");
             ("ai.toolCall.name", "weather");
           ])
      ()
  in
  let vercel_spans = [ vercel; do_generate; vercel_tool ] in
  Alcotest.(check string)
    "aic-cw6h the Vercel top-level span is an AI call" "call"
    (kind_of vercel_spans vercel);
  Alcotest.(check string)
    "aic-jupv doGenerate under an AI call is a nested provider span" "nested"
    (kind_of vercel_spans do_generate);
  Alcotest.(check string) "aic-qs41 ai.toolCall is a tool execution" "tool"
    (kind_of vercel_spans vercel_tool);
  Alcotest.(check string)
    "aic-jupv without its parent the provider span is the call" "call"
    (kind_of [ do_generate ] do_generate);
  Alcotest.(check int) "aic-jupv only the top-level span is listed" 1
    (List.length
       (List.filter
          (fun (_, kind) -> kind = Ai.Ai_call)
          (Ai.classify_spans vercel_spans)))

let test_ai_extraction () =
  (* aic-q5qt, aic-kqhv, aic-fy0u, aic-gywl, aic-cw6h *)
  let ox = ox_chat_span () in
  let tool = ox_tool_span () in
  let children = [ tool ] in
  let call = Ai.call_of_span ~children ox in
  Alcotest.(check string) "aic-q5qt operation comes from the GenAI convention"
    "chat" call.operation;
  Alcotest.(check string) "aic-q5qt service" "ox-app" call.service_name;
  Alcotest.(check (option string)) "aic-q5qt provider" (Some "openai")
    call.provider;
  Alcotest.(check (option string)) "aic-q5qt model" (Some "gpt-4o") call.model;
  Alcotest.(check string) "aic-q5qt status" "ok" call.status;
  Alcotest.(check bool) "aic-q5qt start time" true
    (call.start_time_ns = base_time * 1_000_000);
  Alcotest.(check (option (float 0.001))) "aic-q5qt duration" (Some 5_000.)
    call.duration_ms;
  Alcotest.(check (option string)) "aic-q5qt finish reason" (Some "stop")
    call.finish_reason;
  Alcotest.(check (option string)) "aic-q5qt session id" (Some "session-3")
    call.session_id;
  Alcotest.(check (option string)) "aic-q5qt function id" (Some "trip.plan")
    call.function_id;
  Alcotest.(check (option string)) "aic-q5qt user id" (Some "user-7")
    call.user_id;
  Alcotest.(check int) "aic-q5qt tool call count" 1 call.tool_call_count;
  Alcotest.(check (option int)) "aic-q5qt input tokens" (Some 120)
    call.usage.input_tokens;
  Alcotest.(check (option int)) "aic-q5qt output tokens" (Some 48)
    call.usage.output_tokens;
  Alcotest.(check (option int)) "aic-q5qt total tokens are derived" (Some 168)
    call.usage.total_tokens;
  Alcotest.(check (option string)) "aic-kqhv the prompt preview is text"
    (Some "book a flight") call.prompt_preview;
  Alcotest.(check (option string)) "aic-kqhv the response preview is text"
    (Some "booked") call.response_preview;
  let long_prompt = String.make 500 'x' in
  let long =
    ai_span ~trace_id:"ffffffffffffffffffffffffffffffff"
      ~span_id:"f000000000000009" ~service_name:"effect-app"
      ~operation_name:"generateText"
      ~attributes:
        (ai_attrs
           [ ("ai.prompt", long_prompt); ("ai.response.text", long_prompt) ])
      ()
  in
  let long_call = Ai.call_of_span ~children:[] long in
  Alcotest.(check (option int)) "aic-kqhv previews stop at 200 characters"
    (Some 200)
    (Option.map String.length long_call.prompt_preview);
  Alcotest.(check (option int)) "aic-kqhv response previews stop at 200 too"
    (Some 200)
    (Option.map String.length long_call.response_preview);
  let detail = Ai.detail_of_span ~children ox in
  Alcotest.(check int) "aic-fy0u the parsed prompt messages" 1
    (List.length detail.prompt.messages);
  Alcotest.(check (option string)) "aic-fy0u the raw prompt is kept"
    (Some {|[{"role":"user","content":"book a flight"}]|})
    detail.prompt.raw;
  Alcotest.(check (option string)) "aic-fy0u the full response text"
    (Some "booked") detail.response_text;
  Alcotest.(check int) "aic-fy0u the tool call is listed" 1
    (List.length detail.tool_calls);
  let tool_call = List.hd detail.tool_calls in
  Alcotest.(check string) "aic-fy0u the tool call name" "get_weather"
    tool_call.tool_name;
  Alcotest.(check (option string)) "aic-fy0u the tool call span id"
    (Some "e000000000000002") tool_call.tool_span_id;
  Alcotest.(check (option string)) "aic-fy0u the tool call arguments"
    (Some {|{"city":"Paris"}|}) tool_call.tool_arguments;
  Alcotest.(check (option string)) "aic-fy0u the tool call result"
    (Some "sunny") tool_call.tool_result;
  Alcotest.(check (option (float 0.001))) "aic-fy0u time to first chunk in ms"
    (Some 250.) detail.timing.time_to_first_chunk_ms;
  Alcotest.(check (option (float 0.001))) "aic-fy0u time to finish in ms"
    (Some 4_750.) detail.timing.time_to_finish_ms;
  Alcotest.(check (option (float 0.001))) "aic-fy0u output tokens per second"
    (Some (48. /. 4.75)) detail.timing.output_tokens_per_second;
  let vercel =
    ai_span ~trace_id:"abababababababababababababababab"
      ~span_id:"a000000000000001" ~service_name:"vercel-app"
      ~operation_name:"ai.generateText" ~duration_ms:1_000.
      ~attributes:
        (ai_attrs
           [
             ("ai.operationId", "ai.generateText");
             ("ai.model.id", "gpt-4o-mini");
             ("ai.prompt.messages", {|[{"role":"user","content":"hi"}]|});
             ("ai.prompt.tools", {|[{"name":"weather"}]|});
             ("ai.response.text", "hello there");
             ("ai.response.finishReason", "stop");
             ("ai.response.msToFirstChunk", "80");
             ("ai.response.providerMetadata", {|{"openai":{"serviceTier":"default"}}|});
             ("ai.usage.outputTokens", "20");
             ("ai.response.toolCalls",
              {|[{"toolName":"weather","input":{"city":"Paris"}}]|});
           ])
      ()
  in
  let vercel_detail = Ai.detail_of_span ~children:[] vercel in
  Alcotest.(check (option string)) "aic-fy0u the Vercel response text"
    (Some "hello there") vercel_detail.response_text;
  Alcotest.(check int) "aic-fy0u the available tools are parsed" 1
    (List.length vercel_detail.tools);
  Alcotest.(check bool) "aic-fy0u provider metadata is parsed" true
    (match vercel_detail.provider_metadata with
    | Some (`Assoc _) -> true
    | _ -> false);
  Alcotest.(check int) "aic-fy0u the response tool calls are listed" 1
    (List.length vercel_detail.tool_calls);
  Alcotest.(check (option (float 0.001))) "aic-fy0u msToFirstChunk stays in ms"
    (Some 80.) vercel_detail.timing.time_to_first_chunk_ms;
  Alcotest.(check (option (float 0.001))) "aic-fy0u msToFinish is the remainder"
    (Some 920.) vercel_detail.timing.time_to_finish_ms;
  Alcotest.(check (option (float 0.001))) "aic-fy0u Vercel tokens per second"
    (Some (20. /. 0.92)) vercel_detail.timing.output_tokens_per_second;
  (* Typed OTLP values are read as they were decoded, not re-parsed from text. *)
  let typed =
    ai_span ~trace_id:"ffffffffffffffffffffffffffffffff"
      ~span_id:"f00000000000000a" ~service_name:"effect-app"
      ~operation_name:"generateText"
      ~attributes:
        [
          ("gen_ai.operation.name", `String "chat");
          ("gen_ai.request.model", `String "typed-model");
          ("gen_ai.usage.input_tokens", `Int 12);
          ("gen_ai.usage.output_tokens", `Int 3);
        ]
      ()
  in
  let typed_call = Ai.call_of_span ~children:[] typed in
  Alcotest.(check (option int)) "aic-q5qt typed token counts are used directly"
    (Some 12) typed_call.usage.input_tokens;
  Alcotest.(check (option int)) "aic-q5qt typed totals are derived" (Some 15)
    typed_call.usage.total_tokens;
  (* GenAI content events are honored when no content attribute is present. *)
  let evented =
    {
      (ai_span ~trace_id:"ffffffffffffffffffffffffffffffff"
         ~span_id:"f00000000000000b" ~service_name:"ox-app"
         ~operation_name:"chat evented"
         ~attributes:(ai_attrs [ ("gen_ai.operation.name", "chat") ])
         ())
      with
      Model.events =
        [
          {
            Model.name = "gen_ai.content.prompt";
            timestamp_ns = base_time * 1_000_000;
            attributes =
              ai_attrs
                [ ("gen_ai.prompt", {|[{"role":"user","content":"evented"}]|}) ];
          };
        ];
    }
  in
  let evented_detail = Ai.detail_of_span ~children:[] evented in
  Alcotest.(check (option string)) "aic-kqhv a GenAI prompt event is read"
    (Some "evented") (Ai.call_of_span ~children:[] evented).prompt_preview;
  Alcotest.(check int) "aic-fy0u a GenAI prompt event parses into messages" 1
    (List.length evented_detail.prompt.messages);
  let search = Ai.search_text ~children ox in
  Alcotest.(check bool) "aic-gywl text covers the prompt" true
    (contains search "book a flight");
  Alcotest.(check bool) "aic-gywl text covers the response" true
    (contains search "booked");
  Alcotest.(check bool) "aic-gywl text covers tool arguments" true
    (contains search "Paris");
  Alcotest.(check bool) "aic-gywl text covers tool results" true
    (contains search "sunny")

let test_ai_call_store_and_handlers ~(caps : < Ox_caps.Cap.fs_read ; Ox_caps.Cap.fs_write ; Ox_caps.Cap.stderr ; Ox_caps.Cap.time ; Ox_caps.Cap.tmp ; .. >) () =
  (* aic-cw6h, aic-jupv, aic-qs41, aic-q5qt, aic-hjcg, aic-yfcd, aic-gywl,
     aic-qpv6, aic-e67r, aic-t8tl *)
  let config = (temp_config ~caps) () in
  Fun.protect
    ~finally:(fun () -> (cleanup_config ~caps) config)
    (fun () ->
      run_store_scope @@ fun () ->
  let store = run_store (fun sw -> Store.open_ ~caps ~sw ~now_ms:(fun () -> base_time) config) in
      Fun.protect
        ~finally:(fun () -> run_store (fun _sw -> Store.close store))
        (fun () ->
          let trace_id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" in
          let call_id = "e000000000000001"
          and tool_id = "e000000000000002"
          and nested_id = "e000000000000003" in
          let ox = ox_chat_span ~trace_id ~span_id:call_id () in
          let tool = ox_tool_span ~trace_id ~span_id:tool_id
              ~parent_span_id:(Some call_id) () in
          let nested =
            ai_span ~trace_id ~span_id:nested_id
              ~parent_span_id:(Some call_id) ~service_name:"ox-app"
              ~operation_name:"ai.generateText.doGenerate" ~duration_ms:30.
              ~attributes:
                (ai_attrs
                   [
                     ("ai.operationId", "ai.generateText.doGenerate");
                     ("ai.model.id", "gpt-4o");
                   ])
              ()
          in
          let failing_trace = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1" in
          let failing_id = "a100000000000001" in
          let failing =
            ai_span ~trace_id:failing_trace ~span_id:failing_id
              ~service_name:"other-app" ~operation_name:"completion"
              ~status:"error" ~duration_ms:100_000. ~start_ms:(base_time - (2 * hour_ms))
              ~attributes:
                (ai_attrs
                   [
                     ("gen_ai.operation.name", "text_completion");
                     ("gen_ai.provider.name", "anthropic");
                     ("gen_ai.request.model", "claude-3");
                     ("gen_ai.response.finish_reasons", "length");
                     ("gen_ai.usage.input_tokens", "10");
                     ("gen_ai.usage.output_tokens", "4");
                     ("gen_ai.input.messages",
                      {|[{"role":"user","content":"summarize"}]|});
                   ])
              ()
          in
          let log =
            {
              (test_log ~body:"tool finished"
                 ~attributes:[ ("ai.model.id", "gpt-4o") ] ())
              with
              Model.trace_id = Some trace_id;
              span_id = Some call_id;
            }
          in
          ignore
            (run_store
               (fun _sw -> let ( let* ) = Result.bind in
                let* _ = Store.ingest_traces store [ ox; tool; nested; failing ] in
                let* _ = Store.ingest_logs store [ log ] in
                Result.ok ()));
          let calls path = json_list "calls" (server_json config store path) in
          let all = calls "/ai/calls?lookback=all" in
          Alcotest.(check int)
            "aic-cw6h only classified AI calls are listed" 2 (List.length all);
          let call =
            List.find
              (fun json -> json_member "spanId" json = `String call_id)
              all
          in
          Alcotest.(check bool)
            "aic-jupv the nested provider span is not listed" true
            (not
               (List.exists
                  (fun json -> json_member "spanId" json = `String nested_id)
                  all));
          Alcotest.(check bool)
            "aic-qs41 the tool execution is not listed" true
            (not
               (List.exists
                  (fun json -> json_member "spanId" json = `String tool_id)
                  all));
          Alcotest.(check string) "aic-q5qt the summary operation" "chat"
            (json_string_field "operation" call);
          Alcotest.(check string) "aic-q5qt the summary service" "ox-app"
            (json_string_field "serviceName" call);
          Alcotest.(check string) "aic-q5qt the summary provider" "openai"
            (json_string_field "provider" call);
          Alcotest.(check string) "aic-q5qt the summary model" "gpt-4o"
            (json_string_field "model" call);
          Alcotest.(check string) "aic-q5qt the summary status" "ok"
            (json_string_field "status" call);
          Alcotest.(check string) "aic-q5qt the summary finish reason" "stop"
            (json_string_field "finishReason" call);
          Alcotest.(check string) "aic-q5qt the summary session id" "session-3"
            (json_string_field "sessionId" call);
          Alcotest.(check string) "aic-q5qt the summary function id" "trip.plan"
            (json_string_field "functionId" call);
          Alcotest.(check string) "aic-q5qt the summary user id" "user-7"
            (json_string_field "userId" call);
          Alcotest.(check bool) "aic-q5qt the summary start time" true
            (match json_member "startTimeMs" call with
            | `Float _ -> true
            | _ -> false);
          Alcotest.(check (float 0.001)) "aic-q5qt the summary duration" 5_000.
            (match json_member "durationMs" call with
            | `Float value -> value
            | _ -> -1.);
          Alcotest.(check bool) "aic-q5qt the summary tool call count" true
            (json_member "toolCallCount" call = `Int 1);
          let usage = json_member "usage" call in
          Alcotest.(check bool) "aic-q5qt nullable token counts" true
            (json_member "inputTokens" usage = `Int 120
            && json_member "outputTokens" usage = `Int 48
            && json_member "totalTokens" usage = `Int 168
            && json_member "cachedInputTokens" usage = `Null
            && json_member "reasoningTokens" usage = `Null);
          Alcotest.(check string) "aic-kqhv the summary prompt preview"
            "book a flight" (json_string_field "promptPreview" call);
          Alcotest.(check string) "aic-kqhv the summary response preview"
            "booked" (json_string_field "responsePreview" call);
          Alcotest.(check int) "aic-yfcd the model filter" 1
            (List.length (calls "/ai/calls?lookback=all&model=claude-3"));
          Alcotest.(check int) "aic-yfcd the provider filter" 1
            (List.length (calls "/ai/calls?lookback=all&provider=anthropic"));
          Alcotest.(check int) "aic-yfcd the operation filter is a substring" 1
            (List.length (calls "/ai/calls?lookback=all&operation=text_comp"));
          Alcotest.(check int) "aic-yfcd the finish reason filter" 1
            (List.length (calls "/ai/calls?lookback=all&finishReason=length"));
          Alcotest.(check int) "aic-yfcd the session filter" 1
            (List.length (calls "/ai/calls?lookback=all&sessionId=session-3"));
          Alcotest.(check int) "aic-yfcd the function filter" 1
            (List.length (calls "/ai/calls?lookback=all&functionId=trip.plan"));
          Alcotest.(check int) "aic-yfcd the status filter" 1
            (List.length (calls "/ai/calls?lookback=all&status=error"));
          Alcotest.(check int) "aic-yfcd the duration filter" 1
            (List.length (calls "/ai/calls?lookback=all&minDurationMs=50000"));
          Alcotest.(check int) "aic-yfcd the lookback filter" 1
            (List.length (calls "/ai/calls?lookback=1h"));
          Alcotest.(check int)
            "aic-gywl text matches the prompt, ignoring case" 1
            (List.length (calls "/ai/calls?lookback=all&text=BOOK%20A%20FLIGHT"));
          Alcotest.(check int) "aic-gywl text matches the response" 1
            (List.length (calls "/ai/calls?lookback=all&text=BOOKED"));
          Alcotest.(check int) "aic-gywl text matches tool arguments" 1
            (List.length (calls "/ai/calls?lookback=all&text=paris"));
          Alcotest.(check int) "aic-gywl text matches tool results" 1
            (List.length (calls "/ai/calls?lookback=all&text=SUNNY"));
          ignore
            (check_walk ~config ~store ~name:"calls"
               ~key:(fun json ->
                 json_string_field "traceId" json ^ ":"
                 ^ json_string_field "spanId" json)
               ~limit:1 "/ai/calls?lookback=all");
          let detail =
            server_json config store ("/ai/calls/" ^ call_id)
          in
          let detail_call = json_member "call" detail in
          Alcotest.(check string) "aic-fy0u the detail repeats the summary"
            call_id (json_string_field "spanId" detail_call);
          Alcotest.(check int) "aic-fy0u the detail parses the prompt messages" 1
            (List.length (json_list "messages" (json_member "prompt" detail)));
          Alcotest.(check string) "aic-fy0u the detail response text" "booked"
            (json_string_field "text" (json_member "response" detail));
          Alcotest.(check int) "aic-fy0u the detail lists tool calls" 1
            (List.length (json_list "toolCalls" detail));
          Alcotest.(check string) "aic-fy0u the tool call name" "get_weather"
            (json_string_field "name" (List.hd (json_list "toolCalls" detail)));
          Alcotest.(check bool) "aic-fy0u the detail carries timing" true
            (match json_member "timeToFirstChunkMs" (json_member "timing" detail) with
            | `Float _ -> true
            | _ -> false);
          Alcotest.(check bool) "aic-fy0u the detail carries the raw span" true
            (json_member "span" detail <> `Null);
          Alcotest.(check int) "aic-hjcg the detail carries correlated logs" 1
            (List.length (json_list "logs" detail));
          Alcotest.(check string) "aic-hjcg the detail links to the parent trace"
            ("http://127.0.0.1:" ^ string_of_int config.Config.port ^ "/traces/"
           ^ trace_id)
            (json_string_field "trace" (json_member "links" detail));
          let statements path = json_list "stats" (server_json config store path) in
          let group path name =
            let rows = statements path in
            match
              List.find_opt
                (fun row -> json_member "group" row = `String name)
                rows
            with
            | Some row -> row
            | None -> Alcotest.failf "%s has no group %s" path name
          in
          Alcotest.(check int) "aic-qpv6 group by provider" 2
            (List.length (statements "/ai/stats?lookback=all&groupBy=provider&agg=count"));
          Alcotest.(check bool) "aic-qpv6 provider counts are exact" true
            (json_member "count"
               (group "/ai/stats?lookback=all&groupBy=provider&agg=count" "openai")
            = `Int 1);
          Alcotest.(check bool) "aic-qpv6 group by model counts" true
            (json_member "count"
               (group "/ai/stats?lookback=all&groupBy=model&agg=count" "gpt-4o")
            = `Int 1);
          Alcotest.(check bool) "aic-qpv6 group by operation" true
            (json_member "count"
               (group "/ai/stats?lookback=all&groupBy=operation&agg=count" "chat")
            = `Int 1);
          Alcotest.(check bool) "aic-qpv6 group by finishReason" true
            (json_member "count"
               (group "/ai/stats?lookback=all&groupBy=finishReason&agg=count"
                  "length")
            = `Int 1);
          Alcotest.(check bool) "aic-qpv6 group by functionId reports unknown"
            true
            (json_member "count"
               (group "/ai/stats?lookback=all&groupBy=functionId&agg=count"
                  "unknown")
            = `Int 1);
          Alcotest.(check bool) "aic-qpv6 group by sessionId reports unknown"
            true
            (json_member "count"
               (group "/ai/stats?lookback=all&groupBy=sessionId&agg=count"
                  "unknown")
            = `Int 1);
          Alcotest.(check bool) "aic-qpv6 error rate is exact" true
            (match
               json_member "value"
                 (group "/ai/stats?lookback=all&groupBy=status&agg=error_rate"
                    "error")
             with
            | `Float value -> Float.abs (value -. 1.) < 0.0001
            | _ -> false);
          Alcotest.(check bool) "aic-qpv6 avg duration is exact" true
            (match
               json_member "value"
                 (group "/ai/stats?lookback=all&groupBy=model&agg=avg_duration"
                    "gpt-4o")
             with
            | `Float value -> Float.abs (value -. 5000.) < 0.0001
            | _ -> false);
          Alcotest.(check bool) "aic-qpv6 p95 duration is exact" true
            (match
               json_member "value"
                 (group "/ai/stats?lookback=all&groupBy=model&agg=p95_duration"
                    "gpt-4o")
             with
            | `Float value -> Float.abs (value -. 5000.) < 0.0001
            | _ -> false);
          Alcotest.(check bool) "aic-qpv6 total input tokens are exact" true
            (match
               json_member "value"
                 (group "/ai/stats?lookback=all&groupBy=model&agg=total_input_tokens"
                    "gpt-4o")
             with
            | `Float value -> Float.abs (value -. 120.) < 0.0001
            | _ -> false);
          Alcotest.(check bool) "aic-qpv6 total output tokens are exact" true
            (match
               json_member "value"
                 (group "/ai/stats?lookback=all&groupBy=model&agg=total_output_tokens"
                    "claude-3")
             with
            | `Float value -> Float.abs (value -. 4.) < 0.0001
            | _ -> false);
          Alcotest.(check bool) "aic-qpv6 total tokens are exact" true
            (match
               json_member "value"
                 (group "/ai/stats?lookback=all&groupBy=model&agg=total_tokens"
                    "claude-3")
             with
            | `Float value -> Float.abs (value -. 14.) < 0.0001
            | _ -> false);
          check_invalid_query "aic-e67r an unknown groupBy"
            (server_get config store
               "/ai/stats?lookback=all&groupBy=bogus&agg=count")
            "groupBy must be one of";
          let invalid_group =
            response_json
              (server_get config store
                 "/ai/stats?lookback=all&groupBy=bogus&agg=count")
          in
          Alcotest.(check bool) "aic-e67r it lists every allowed group" true
            (List.for_all
               (fun name -> contains (json_string_field "message" invalid_group) name)
               [ "provider"; "model"; "functionId"; "sessionId"; "status";
                 "operation"; "finishReason" ]);
          let invalid_agg =
            response_json
              (server_get config store
                 "/ai/stats?lookback=all&groupBy=model&agg=bogus")
          in
          check_invalid_query "aic-e67r an unknown agg"
            (server_get config store
               "/ai/stats?lookback=all&groupBy=model&agg=bogus")
            "agg must be one of";
          Alcotest.(check bool) "aic-e67r it lists every allowed agg" true
            (List.for_all
               (fun name -> contains (json_string_field "message" invalid_agg) name)
               [ "count"; "avg_duration"; "p95_duration"; "total_input_tokens";
                 "total_output_tokens"; "total_tokens"; "error_rate" ]);
          let tool_miss = server_get config store ("/ai/calls/" ^ tool_id) in
          Alcotest.(check int) "aic-t8tl a tool call is a 404" 404
            (Ox_http.Server.Response.status tool_miss);
          let tool_body = response_json tool_miss in
          Alcotest.(check string) "aic-t8tl the hint names the kind" "tool"
            (json_string_field "kind" tool_body);
          Alcotest.(check string) "aic-t8tl the hint points at the AI call"
            call_id (json_string_field "aiCallSpanId" tool_body);
          Alcotest.(check bool) "aic-t8tl the hint shows the way" true
            (contains (json_string_field "hint" tool_body) ("/ai/calls/" ^ call_id));
          let nested_miss = server_get config store ("/ai/calls/" ^ nested_id) in
          Alcotest.(check int)
            "aic-t8tl a nested provider span is a 404" 404
            (Ox_http.Server.Response.status nested_miss);
          Alcotest.(check string)
            "aic-t8tl the nested hint names the kind" "nested"
            (json_string_field "kind" (response_json nested_miss));
          Alcotest.(check string)
            "aic-t8tl the nested hint points at the AI call" call_id
            (json_string_field "aiCallSpanId" (response_json nested_miss));
          let unknown =
            server_get config store "/ai/calls/00000000000000ff"
          in
          Alcotest.(check int) "aic-t8tl an unknown span is a plain 404" 404
            (Ox_http.Server.Response.status unknown);
          Alcotest.(check bool)
            "aic-t8tl an unknown span has no parent hint" true
            (List.mem_assoc "kind" (match response_json unknown with
              | `Assoc fields -> fields
              | _ -> []) = false)))

(* aic-6xrr: the field provenance table lives in the README. *)
let read_repository_file ~(caps : < Ox_caps.Cap.fs_read ; .. >) names =
  match List.find_opt Sys.file_exists names with
  | Some path -> Ox_caps.Cap_stdlib.In_channel.with_open_bin ~caps path In_channel.input_all
  | None -> Alcotest.failf "none of %s exists" (String.concat ", " names)

let test_ai_field_provenance_documented ~(caps : < Ox_caps.Cap.fs_read ; .. >) () =
  let readme =
    (read_repository_file ~caps) [ "../README.md"; "README.md"; "../../README.md" ]
  in
  Alcotest.(check bool) "aic-6xrr the provenance table exists" true
    (contains readme "AI call field provenance");
  List.iter
    (fun fragment ->
      Alcotest.(check bool) ("aic-6xrr documents " ^ fragment) true
        (contains readme fragment))
    [
      "gen_ai.operation.name";
      "ai.operationId";
      "gen_ai.provider.name";
      "gen_ai.system";
      "ai.model.provider";
      "gen_ai.request.model";
      "ai.model.id";
      "gen_ai.usage.input_tokens";
      "ai.usage.inputTokens";
      "gen_ai.usage.output_tokens";
      "ai.usage.outputTokens";
      "gen_ai.response.finish_reasons";
      "ai.response.finishReason";
      "gen_ai.input.messages";
      "ai.prompt.messages";
      "gen_ai.output.messages";
      "ai.response.text";
      "ai.prompt.tools";
      "ai.response.providerMetadata";
      "gen_ai.response.time_to_first_chunk";
      "ai.response.msToFirstChunk";
      "ai.toolCall";
      "gen_ai.operation.name=execute_tool";
    ]

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
      "isRunning"; "/ai/calls"; "/ai/calls/{spanId}"; "/ai/stats";
      "/traces/stats"; "/logs/stats"; "/facets"; "/stats";
      "/docs"; "/docs/debug"; "/openapi.json"; "/endpoints";
      "inn_docs_index"; "inn_get_doc"; "inn_search_traces"; "inn_get_trace";
      "inn_search_ai_calls"; "inn_ai_stats"; "inn trace"; "inn docs";
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
          Alcotest.test_case "INN_RETENTION_HOURS is rejected (ret-f1oo)" `Quick
            (test_config_rejects_legacy_retention ~caps);
          Alcotest.test_case "invalid values are rejected (ret-6pix)" `Quick
            (test_config_rejects_invalid_values ~caps);
        ] );
      ( "schema",
        [
          Alcotest.test_case "fingerprint matches the version (schm-hnis)"
            `Quick test_schema_fingerprint_matches_version;
          Alcotest.test_case "reopen keeps data (schm-ld81)" `Quick
            (test_schema_reopen_keeps_data ~caps);
          Alcotest.test_case "version mismatch recreates (schm-s13e, schm-s52b)"
            `Quick (test_schema_mismatch_recreates_database ~caps);
          Alcotest.test_case "foreign database is refused (schm-xkk2)" `Quick
            (test_schema_refuses_foreign_database ~caps);
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
      ( "retention",
        [
          Alcotest.test_case "per-signal ttl (ret-mvsc, ret-57b8, ret-ggir)"
            `Quick (test_prune_per_signal_ttl ~caps);
          Alcotest.test_case "ingestion time decides expiry (ret-ovry)" `Quick
            (test_prune_uses_ingestion_time ~caps);
          Alcotest.test_case "fresh span keeps its trace (ret-4hhb, ret-hy7e)"
            `Quick (test_prune_keeps_trace_with_fresh_span ~caps);
          Alcotest.test_case "bounded batches clear a backlog (ret-xbij)" `Quick
            (test_prune_batches_large_backlog ~caps);
          Alcotest.test_case "ingest does not prune (ret-rkrf)" `Quick
            (test_ingest_does_not_prune ~caps);
          Alcotest.test_case "size cap deletes oldest first (ret-zjzs, ret-bizv)"
            `Quick (test_prune_size_cap_removes_only_oldest ~caps);
          Alcotest.test_case "stats carry the retention section (ret-eeb1)"
            `Quick (test_stats_reports_retention ~caps);
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
          Alcotest.test_case "pruner runs without ingest (ret-sj15, ret-sbgj)"
            `Slow (test_server_pruner_prunes_without_ingest ~caps);
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
      ( "ai",
        [
          Alcotest.test_case
            "classification (aic-cw6h, aic-jupv, aic-qs41, aic-q5qt)" `Quick
            test_ai_classification;
          Alcotest.test_case
            "extraction (aic-q5qt, aic-kqhv, aic-fy0u, aic-gywl)" `Quick
            test_ai_extraction;
          Alcotest.test_case
            "search, stats, and hints (aic-cw6h, aic-jupv, aic-qs41, aic-q5qt, aic-hjcg, aic-yfcd, aic-gywl, aic-qpv6, aic-e67r, aic-t8tl)"
            `Quick (test_ai_call_store_and_handlers ~caps);
          Alcotest.test_case "field provenance in the docs (aic-6xrr)" `Quick
            (test_ai_field_provenance_documented ~caps);
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
