open Inn

let env pairs key = List.assoc_opt key pairs

let hour_ms = 60 * 60 * 1000

(* A fixed ingestion-clock base: retention tests drive the store clock, so no
   test depends on wall-clock time. *)
let base_time = 1_700_000_000_000

let wall_now_ms () = int_of_float (Unix.gettimeofday () *. 1000.)

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
        ("INN_TRACES_RETENTION_HOURS", "72");
        ("INN_LOGS_RETENTION_HOURS", "6");
        ("INN_METRICS_RETENTION_HOURS", "12");
        ("INN_PRUNE_INTERVAL_SECONDS", "45");
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
      Alcotest.(check int)
        "traces ttl override (ret-6pix)" 72 config.traces_retention_hours;
      Alcotest.(check int)
        "logs ttl override (ret-6pix)" 6 config.logs_retention_hours;
      Alcotest.(check int)
        "metrics ttl override (ret-6pix)" 12 config.metrics_retention_hours;
      Alcotest.(check int)
        "prune interval override (ret-qd9f)" 45 config.prune_interval_seconds;
      Alcotest.(check int) "max db" 2048 config.max_db_size_mb

let test_config_rejects_legacy_retention () =
  let env = env [ ("INN_RETENTION_HOURS", "72") ] in
  match Config.resolve ~env ~home:"/home/alice" () with
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

let test_config_rejects_invalid_values () =
  let check_invalid name value =
    let env = env [ (name, value) ] in
    match Config.resolve ~env ~home:"/home/alice" () with
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

let test_span ?(trace_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    ?(span_id = "bbbbbbbbbbbbbbbb") ?(parent_span_id = None) ?(service_name = "svc")
    ?(operation_name = "root") ?(status = "ok") ?(attributes = []) () =
  {
    Model.trace_id;
    span_id;
    parent_span_id;
    service_name;
    scope_name = Some "scope";
    operation_name;
    kind = Some "SPAN_KIND_SERVER";
    start_time_ms = base_time;
    end_time_ms = base_time + 1_000;
    duration_ms = 1.0;
    status;
    status_message = None;
    attributes;
    resource = [ ("service.name", service_name) ];
    events = [];
  }

let test_log ?(service_name = "svc") ?(body = "failed") ?(timestamp_ms = base_time)
    ?(attributes = []) ?(resource = [ ("service.name", "svc") ]) () =
  {
    Model.trace_id = None;
    span_id = None;
    service_name;
    scope_name = Some "scope";
    severity_text = "ERROR";
    severity_number = Some 17;
    timestamp_ms;
    body;
    attributes;
    resource;
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
    start_time_ms = Some base_time;
    timestamp_ms;
    value = "3";
    attributes;
    resource = [ ("service.name", service_name) ];
    raw_json = `Assoc [];
  }

(* Store helpers --------------------------------------------------------- *)

let temp_db_path () =
  let db_path = Filename.temp_file "inn-test-" ".sqlite" in
  Sys.remove db_path;
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

let temp_config ?port ?traces_retention_hours ?logs_retention_hours
    ?metrics_retention_hours ?prune_interval_seconds ?max_db_size_mb () =
  test_config ?port ?traces_retention_hours ?logs_retention_hours
    ?metrics_retention_hours ?prune_interval_seconds ?max_db_size_mb
    (temp_db_path ())

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

let run_store_error program =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok _ -> None
  | Eta.Exit.Error cause ->
      Some (Format.asprintf "%a" (Eta.Cause.pp Store.pp_error) cause)

let run_store_in ~sw ~clock program =
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%a" (Eta.Cause.pp Store.pp_error) cause

let with_store ?now_ms ?report config f =
  run_store (Store.with_db ?now_ms ?report config f)

(* Test-only database probes. The store's public interface cannot produce a
   stale schema version or a foreign database, and it cannot prove that no
   orphaned attribute row is left behind, so these helpers use Eta SQL typed
   builders directly. *)

let pp_pool_error ppf = function
  | `Eta_sql error -> Eta_sql.pp_error ppf error
  | `Pool_shutdown -> Format.pp_print_string ppf "pool shutdown"
  | `Pool_shutdown_timeout -> Format.pp_print_string ppf "pool shutdown timeout"
  | `Timeout -> Format.pp_print_string ppf "timeout"

module Test_meta = struct
  module T = Eta_sql.Table.Make (struct
    let name = "inn_meta"
  end)

  include T

  let key = column "key" Eta_sql.text
  let value = column "value" Eta_sql.text
end

module Test_foreign = struct
  module T = Eta_sql.Table.Make (struct
    let name = "other_app"
  end)

  include T

  let id = column "id" Eta_sql.text
end

module Test_spans = struct
  module T = Eta_sql.Table.Make (struct
    let name = "spans"
  end)

  include T

  let id = column "id" Eta_sql.text
end

module Test_span_attributes = struct
  module T = Eta_sql.Table.Make (struct
    let name = "span_attributes"
  end)

  include T

  let owner_id = column "owner_id" Eta_sql.text
end

module Test_logs = struct
  module T = Eta_sql.Table.Make (struct
    let name = "logs"
  end)

  include T

  let id = column "id" Eta_sql.text
end

module Test_log_attributes = struct
  module T = Eta_sql.Table.Make (struct
    let name = "log_attributes"
  end)

  include T

  let owner_id = column "owner_id" Eta_sql.text
end

module Test_metric_points = struct
  module T = Eta_sql.Table.Make (struct
    let name = "metric_points"
  end)

  include T

  let id = column "id" Eta_sql.text
end

module Test_metric_attributes = struct
  module T = Eta_sql.Table.Make (struct
    let name = "metric_attributes"
  end)

  include T

  let owner_id = column "owner_id" Eta_sql.text
end

let run_test_db path program =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let open Eta.Syntax in
  let program =
    let* pool =
      Eta_sql.Pool.create
        ~default_timeout:(Eta.Duration.ms 5000)
        (Eta_sql.Sqlite.default_config path)
    in
    let* value = program pool in
    let* () = Eta_sql.Pool.shutdown pool in
    Eta.Effect.pure value
  in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%a" (Eta.Cause.pp pp_pool_error) cause

let write_schema_version path version =
  run_test_db path (fun pool ->
      let open Eta.Syntax in
      let update =
        Eta_sql.Update.(
          table Test_meta.table
          |> set Test_meta.value version
          |> where Eta_sql.Expr.(eq Test_meta.key "schema_version")
          |> compile)
      in
      let* _ = Eta_sql.Pool.Typed.execute_compiled pool update in
      Eta.Effect.pure ())

let create_foreign_database path =
  run_test_db path (fun pool ->
      let open Eta.Syntax in
      let schema =
        Eta_sql.Eta_schema.(
          compile
            (create_table Test_foreign.table
               [ column ~primary_key:true Test_foreign.id ]))
      in
      let* () = Eta_sql.Pool.Typed.run_schema pool schema in
      let insert =
        Eta_sql.Insert.(
          into Test_foreign.table
          |> value Test_foreign.id "row-1"
          |> compile)
      in
      let* _ = Eta_sql.Pool.Typed.execute_compiled pool insert in
      Eta.Effect.pure ())

let foreign_rows path =
  run_test_db path (fun pool ->
      Eta_sql.Pool.Typed.select pool
        (Eta_sql.Select.compile
           Eta_sql.Select.(
             from Test_foreign.table (Eta_sql.Projection.one Test_foreign.id))))

(* Attribute rows whose owner row is gone (ret-hy7e). *)
let orphan_attribute_rows path =
  run_test_db path (fun pool ->
      let open Eta.Syntax in
      let owners table owner_id =
        Eta_sql.Pool.Typed.select pool
          (Eta_sql.Select.compile
             Eta_sql.Select.(from table (Eta_sql.Projection.one owner_id)))
      in
      let ids table id =
        Eta_sql.Pool.Typed.select pool
          (Eta_sql.Select.compile
             Eta_sql.Select.(from table (Eta_sql.Projection.one id)))
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
      Eta.Effect.pure
        (count_orphans span_owners span_ids + count_orphans log_owners log_ids
       + count_orphans metric_owners metric_ids))

(* Server helpers -------------------------------------------------------- *)

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

let free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX _ -> Alcotest.fail "expected an inet socket")

let http_get_opt ~sw ~net ~clock client url =
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  let program =
    let open Eta.Syntax in
    let* response = Eta_http.request client (Eta_http.Request.make "GET" url) in
    let* body = Eta_http.Body.Stream.read_all response.Eta_http.Response.body in
    Eta.Effect.pure (response.Eta_http.Response.status, Bytes.to_string body)
  in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok value -> Some value
  | Eta.Exit.Error _ -> None

let http_get ~sw ~net ~clock client url =
  match http_get_opt ~sw ~net ~clock client url with
  | Some value -> value
  | None -> Alcotest.failf "GET %s failed" url

let wait_until ~clock ~timeout_seconds predicate =
  let deadline = Unix.gettimeofday () +. timeout_seconds in
  let rec loop () =
    if predicate () then true
    else if Unix.gettimeofday () > deadline then false
    else (
      Eio.Time.sleep clock 0.05;
      loop ())
  in
  loop ()

(* Schema ---------------------------------------------------------------- *)

(* Recorded together with [Store.schema_version]: change one and you must
   change the other (schm-hnis). *)
let recorded_schema_fingerprint = "4093c36348bf05af77b3168bdf8cd1ad"

let test_schema_fingerprint_matches_version () =
  Alcotest.(check int) "schema version" 2 Store.schema_version;
  Alcotest.(check string)
    "schema fingerprint (schm-hnis)" recorded_schema_fingerprint
    Store.schema_fingerprint

let test_schema_reopen_keeps_data () =
  let config = temp_config () in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  with_store config (fun store ->
      let open Eta.Syntax in
      let* _ = Store.ingest_traces store [ test_span () ] in
      let* _ = Store.ingest_logs store [ test_log () ] in
      Eta.Effect.pure ());
  let stats =
    with_store config (fun store ->
        let open Eta.Syntax in
        let* _ = Store.ingest_metrics store [ test_metric () ] in
        Store.stats store)
  in
  Alcotest.(check int) "traces kept (schm-ld81)" 1 stats.Model.traces;
  Alcotest.(check int) "spans kept (schm-ld81)" 1 stats.Model.spans;
  Alcotest.(check int) "logs kept (schm-ld81)" 1 stats.Model.logs;
  Alcotest.(check int) "metrics kept (schm-ld81)" 1 stats.Model.metric_points

let test_schema_mismatch_recreates_database () =
  let config = temp_config () in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  with_store config (fun store ->
      let open Eta.Syntax in
      let* _ = Store.ingest_logs store [ test_log () ] in
      Eta.Effect.pure ());
  write_schema_version config.Config.db_path "0";
  let messages = ref [] in
  let stats, ingested =
    with_store
      ~report:(fun message -> messages := message :: !messages)
      config
      (fun store ->
        let open Eta.Syntax in
        let* stats = Store.stats store in
        let* ingested = Store.ingest_logs store [ test_log ~body:"fresh" () ] in
        Eta.Effect.pure (stats, ingested))
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

let test_schema_refuses_foreign_database () =
  let config = temp_config () in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  create_foreign_database config.Config.db_path;
  (match run_store_error (Store.open_ config) with
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
    (foreign_rows config.Config.db_path);
  (* A file that is not SQLite at all is refused for the same reason. *)
  let other = test_config (temp_db_path ()) in
  Fun.protect
    ~finally:(fun () -> cleanup_config other)
    (fun () ->
      let contents = "not a database\n" in
      let channel = open_out_bin other.Config.db_path in
      output_string channel contents;
      close_out channel;
      (match run_store_error (Store.open_ other) with
      | Some message ->
          Alcotest.(check bool)
            "error says the file is not a database (schm-xkk2)" true
            (contains message "not an SQLite database")
      | None -> Alcotest.fail "expected the store to refuse a non-SQLite file");
      let channel = open_in_bin other.Config.db_path in
      let read = really_input_string channel (in_channel_length channel) in
      close_in channel;
      Alcotest.(check string)
        "the non-SQLite file is untouched (schm-xkk2)" contents read)

(* Store ----------------------------------------------------------------- *)

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

let test_prune_per_signal_ttl () =
  let config = temp_config () in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  let clock = ref base_time in
  let after_logs, after_traces, stats_after_logs, stats_after_traces =
    with_store ~now_ms:(fun () -> !clock) config (fun store ->
        let open Eta.Syntax in
        let* _ = Store.ingest_traces store [ test_span () ] in
        let* _ = Store.ingest_logs store [ test_log () ] in
        let* _ = Store.ingest_metrics store [ test_metric () ] in
        let* after_logs = Store.prune ~now_ms:(base_time + (25 * hour_ms)) store in
        let* stats_after_logs = Store.stats store in
        let* after_traces =
          Store.prune ~now_ms:(base_time + (49 * hour_ms)) store
        in
        let* stats_after_traces = Store.stats store in
        Eta.Effect.pure
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

let test_prune_uses_ingestion_time () =
  let config = temp_config () in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  let clock = ref base_time in
  let early, late, left =
    with_store ~now_ms:(fun () -> !clock) config (fun store ->
        let open Eta.Syntax in
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
        Eta.Effect.pure (early, late, left))
  in
  Alcotest.(check int)
    "client timestamps do not expire data early (ret-ovry)" 0 early.Model.logs;
  Alcotest.(check int)
    "both rows expire on ingestion time (ret-ovry)" 2 late.Model.logs;
  Alcotest.(check int) "no logs left (ret-ovry)" 0 left.Model.logs

let test_prune_keeps_trace_with_fresh_span () =
  let config = temp_config () in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  let clock = ref base_time in
  let kept_trace = "cccccccccccccccccccccccccccccccc" in
  let stale_trace = "dddddddddddddddddddddddddddddddd" in
  let report, stats, kept, gone, attr_spans, attr_traces =
    with_store ~now_ms:(fun () -> !clock) config (fun store ->
        let open Eta.Syntax in
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
              limit = 10;
            }
            store
        in
        let* attr_traces =
          Store.search_traces
            {
              service = None;
              operation = None;
              status = None;
              attrs = [ ("route", "/gone") ];
              limit = 10;
            }
            store
        in
        Eta.Effect.pure (report, stats, kept, gone, attr_spans, attr_traces))
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
    (orphan_attribute_rows config.Config.db_path)

let test_prune_batches_large_backlog () =
  let config = temp_config () in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  let clock = ref base_time in
  let bulk_logs = 5_000 in
  let report, stats =
    with_store ~now_ms:(fun () -> !clock) config (fun store ->
        let open Eta.Syntax in
        let logs =
          List.init bulk_logs (fun index ->
              test_log ~body:(Printf.sprintf "bulk-%d" index) ~attributes:[]
                ~resource:[] ())
        in
        let* _ = Store.ingest_logs store logs in
        let* report = Store.prune ~now_ms:(base_time + (25 * hour_ms)) store in
        let* stats = Store.stats store in
        Eta.Effect.pure (report, stats))
  in
  Alcotest.(check int)
    "a multi-batch backlog is fully pruned (ret-xbij)" bulk_logs
    report.Model.logs;
  Alcotest.(check int) "no logs left (ret-xbij)" 0 stats.Model.logs

let test_ingest_does_not_prune () =
  let config = temp_config () in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  let clock = ref base_time in
  let after_ingest, report, after_prune =
    with_store ~now_ms:(fun () -> !clock) config (fun store ->
        let open Eta.Syntax in
        let* _ = Store.ingest_logs store [ test_log ~body:"first" () ] in
        clock := base_time + (25 * hour_ms);
        let* _ = Store.ingest_logs store [ test_log ~body:"second" () ] in
        let* after_ingest = Store.stats store in
        let* report = Store.prune ~now_ms:(base_time + (25 * hour_ms)) store in
        let* after_prune = Store.stats store in
        Eta.Effect.pure (after_ingest, report, after_prune))
  in
  Alcotest.(check int)
    "expired data stays until the pruner runs (ret-rkrf)" 2
    after_ingest.Model.logs;
  Alcotest.(check int)
    "the pruner deletes the expired row (ret-rkrf)" 1 report.Model.logs;
  Alcotest.(check int) "the fresh row stays (ret-rkrf)" 1 after_prune.Model.logs

let test_prune_size_cap_removes_only_oldest () =
  let max_db_size_mb = 1 in
  let config = temp_config ~max_db_size_mb () in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  let clock = ref base_time in
  let old_logs = 150 and new_logs = 20 in
  let body = String.make (8 * 1024) 'x' in
  let report, second_report, stats, new_left, old_left =
    with_store ~now_ms:(fun () -> !clock) config (fun store ->
        let open Eta.Syntax in
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
            { service = Some "new"; severity = None; contains = None; limit = 1000 }
            store
        in
        let* old_left =
          Store.list_logs
            { service = Some "old"; severity = None; contains = None; limit = 1000 }
            store
        in
        Eta.Effect.pure (report, second_report, stats, new_left, old_left))
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

let test_stats_reports_retention () =
  let config =
    temp_config ~traces_retention_hours:12 ~logs_retention_hours:6
      ~metrics_retention_hours:18 ~prune_interval_seconds:60
      ~max_db_size_mb:512 ()
  in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  let clock = ref base_time in
  let stats =
    with_store ~now_ms:(fun () -> !clock) config (fun store ->
        let open Eta.Syntax in
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
      let stats =
        run_server_effect
          (Inn.Server.handler config store (request ~target:"/stats" ()))
      in
      Alcotest.(check int)
        "stats status" 200 (Eta_http.Server.Response.status stats);
      Alcotest.(check bool)
        "stats body carries the retention section (ret-eeb1)" true
        (Yojson.Safe.Util.member "retention" (response_json stats) <> `Null);
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

let test_server_pruner_prunes_without_ingest () =
  let port = free_port () in
  let config =
    temp_config ~port ~traces_retention_hours:1 ~logs_retention_hours:1
      ~metrics_retention_hours:1 ~prune_interval_seconds:1 ()
  in
  Fun.protect ~finally:(fun () -> cleanup_config config) @@ fun () ->
  (* Telemetry that expired while the server was not running (ret-sbgj). *)
  with_store
    ~now_ms:(fun () -> wall_now_ms () - (2 * hour_ms))
    config
    (fun store ->
      let open Eta.Syntax in
      let* _ =
        Store.ingest_logs store [ test_log ~body:"expired while stopped" () ]
      in
      Eta.Effect.pure ());
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.first
    (fun () -> Inn.Server.run ~sw ~env config)
    (fun () ->
      let client = Eta_http_eio.Client.make_h1_direct ~sw ~net () in
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
        (wait_until ~clock ~timeout_seconds:10.0 (fun () ->
             match http_get_opt ~sw ~net ~clock client (base_url ^ "/health") with
             | Some (status, _) -> status = 200
             | None -> false));
      Alcotest.(check bool)
        "the startup pass prunes without ingest (ret-sj15, ret-sbgj)" true
        (wait_until ~clock ~timeout_seconds:10.0 (fun () -> log_count () = 0));
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
        (Store.with_db
           ~now_ms:(fun () -> wall_now_ms () - (2 * hour_ms))
           config
           (fun store ->
             let open Eta.Syntax in
             let* _ =
               Store.ingest_logs store [ test_log ~body:"expired later" () ]
             in
             Eta.Effect.pure ()));
      Alcotest.(check bool)
        "the expired row becomes visible" true
        (wait_until ~clock ~timeout_seconds:5.0 (fun () -> log_count () = 1));
      Alcotest.(check bool)
        "the interval pass prunes it (ret-sj15)" true
        (wait_until ~clock ~timeout_seconds:10.0 (fun () -> log_count () = 0)))

let () =
  Alcotest.run "inn"
    [
      ( "config",
        [
          Alcotest.test_case "defaults are user-level" `Quick
            test_config_defaults_are_user_level;
          Alcotest.test_case "environment overrides are explicit" `Quick
            test_config_env_overrides;
          Alcotest.test_case "INN_RETENTION_HOURS is rejected (ret-f1oo)" `Quick
            test_config_rejects_legacy_retention;
          Alcotest.test_case "invalid values are rejected (ret-6pix)" `Quick
            test_config_rejects_invalid_values;
        ] );
      ( "schema",
        [
          Alcotest.test_case "fingerprint matches the version (schm-hnis)"
            `Quick test_schema_fingerprint_matches_version;
          Alcotest.test_case "reopen keeps data (schm-ld81)" `Quick
            test_schema_reopen_keeps_data;
          Alcotest.test_case "version mismatch recreates (schm-s13e, schm-s52b)"
            `Quick test_schema_mismatch_recreates_database;
          Alcotest.test_case "foreign database is refused (schm-xkk2)" `Quick
            test_schema_refuses_foreign_database;
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
      ( "retention",
        [
          Alcotest.test_case "per-signal ttl (ret-mvsc, ret-57b8, ret-ggir)"
            `Quick test_prune_per_signal_ttl;
          Alcotest.test_case "ingestion time decides expiry (ret-ovry)" `Quick
            test_prune_uses_ingestion_time;
          Alcotest.test_case "fresh span keeps its trace (ret-4hhb, ret-hy7e)"
            `Quick test_prune_keeps_trace_with_fresh_span;
          Alcotest.test_case "bounded batches clear a backlog (ret-xbij)" `Quick
            test_prune_batches_large_backlog;
          Alcotest.test_case "ingest does not prune (ret-rkrf)" `Quick
            test_ingest_does_not_prune;
          Alcotest.test_case "size cap deletes oldest first (ret-zjzs, ret-bizv)"
            `Quick test_prune_size_cap_removes_only_oldest;
          Alcotest.test_case "stats carry the retention section (ret-eeb1)"
            `Quick test_stats_reports_retention;
        ] );
      ( "server",
        [
          Alcotest.test_case "handler ingests and queries services" `Quick
            test_server_handler_ingests_and_queries_services;
          Alcotest.test_case "pruner runs without ingest (ret-sj15, ret-sbgj)"
            `Slow test_server_pruner_prunes_without_ingest;
        ] );
    ]
