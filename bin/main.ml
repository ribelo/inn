open Cmdliner

module H = Eta_http

let version = Inn.Version.value

let getenv key =
  match Sys.getenv_opt key with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None

let env_with_overrides overrides key =
  match List.assoc_opt key overrides with
  | Some (Some value) -> Some value
  | _ -> getenv key

let config state_dir db_path host port base_url retention_hours
    traces_retention_hours logs_retention_hours metrics_retention_hours
    prune_interval_seconds max_db_size_mb =
  let int_override = Option.map string_of_int in
  let overrides =
    [
      ("INN_STATE_DIR", state_dir);
      ("INN_DB_PATH", db_path);
      ("INN_HOST", host);
      ("INN_PORT", int_override port);
      ("INN_BASE_URL", base_url);
      ("INN_RETENTION_HOURS", int_override retention_hours);
      ("INN_TRACES_RETENTION_HOURS", int_override traces_retention_hours);
      ("INN_LOGS_RETENTION_HOURS", int_override logs_retention_hours);
      ("INN_METRICS_RETENTION_HOURS", int_override metrics_retention_hours);
      ("INN_PRUNE_INTERVAL_SECONDS", int_override prune_interval_seconds);
      ("INN_MAX_DB_SIZE_MB", int_override max_db_size_mb);
    ]
  in
  match Inn.Config.resolve ~env:(env_with_overrides overrides) () with
  | Ok config -> config
  | Error message -> failwith message

let state_dir_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "state-dir" ] ~docv:"DIR"
        ~doc:"User-level Inn state directory.")

let db_path_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "db" ] ~docv:"PATH" ~doc:"Inn SQLite database path.")

let host_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "host" ] ~docv:"HOST" ~doc:"Server bind host.")

let port_t =
  Arg.(
    value
    & opt (some int) None
    & info [ "port" ] ~docv:"PORT" ~doc:"Server port.")

let base_url_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "base-url" ] ~docv:"URL" ~doc:"Inn server base URL for queries.")

let retention_hours_t =
  Arg.(
    value
    & opt (some int) None
    & info [ "retention-hours" ] ~docv:"HOURS"
        ~doc:"Deprecated: rejected at startup; use the per-signal retention flags.")

let traces_retention_hours_t =
  Arg.(
    value
    & opt (some int) None
    & info [ "traces-retention-hours" ] ~docv:"HOURS"
        ~doc:"Trace time-to-live in hours (default 48).")

let logs_retention_hours_t =
  Arg.(
    value
    & opt (some int) None
    & info [ "logs-retention-hours" ] ~docv:"HOURS"
        ~doc:"Log time-to-live in hours (default 24).")

let metrics_retention_hours_t =
  Arg.(
    value
    & opt (some int) None
    & info [ "metrics-retention-hours" ] ~docv:"HOURS"
        ~doc:"Metric point time-to-live in hours (default 48).")

let prune_interval_seconds_t =
  Arg.(
    value
    & opt (some int) None
    & info [ "prune-interval-seconds" ] ~docv:"SECONDS"
        ~doc:"Seconds between background prune passes (default 300).")

let max_db_size_mb_t =
  Arg.(
    value
    & opt (some int) None
    & info [ "max-db-size-mb" ] ~docv:"MB"
        ~doc:"Target maximum live database size.")

let config_t =
  Term.(
    const config $ state_dir_t $ db_path_t $ host_t $ port_t $ base_url_t
    $ retention_hours_t $ traces_retention_hours_t $ logs_retention_hours_t
    $ metrics_retention_hours_t $ prune_interval_seconds_t $ max_db_size_mb_t)

let trim_trailing_slash url =
  let rec loop len =
    if len > 0 && url.[len - 1] = '/' then loop (len - 1) else len
  in
  let len = loop (String.length url) in
  String.sub url 0 len

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' -> true
  | _ -> false

let percent_encode text =
  let buffer = Buffer.create (String.length text) in
  String.iter
    (fun char ->
      if is_unreserved char then Buffer.add_char buffer char
      else Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code char)))
    text;
  Buffer.contents buffer

let query params =
  let params = List.filter_map (fun (key, value) -> Option.map (fun v -> (key, v)) value) params in
  match params with
  | [] -> ""
  | params ->
      "?"
      ^ String.concat "&"
          (List.map
             (fun (key, value) -> percent_encode key ^ "=" ^ percent_encode value)
             params)

let attr_param (key, value) = ("attr." ^ key, Some value)
let attr_contains_param (key, value) = ("attrContains." ^ key, Some value)

let contains_substring ~needle text =
  let text = String.lowercase_ascii text in
  let needle = String.lowercase_ascii needle in
  let text_len = String.length text in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else
    let rec loop index =
      if index + needle_len > text_len then false
      else if String.equal (String.sub text index needle_len) needle then true
      else loop (index + 1)
    in
    loop 0

let http_request config method_ path =
  let url = trim_trailing_slash config.Inn.Config.base_url ^ path in
  try
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let client = H.Client.create ~sw ~net ~clock () in
    match H.Client.request client ~method_ ~url () with
    | Ok response -> Ok (response.status, Bytes.to_string response.body)
    | Error error ->
        Error
          (match error with
          | `Connect message -> "connection refused: " ^ message
          | `Tls message -> "TLS: " ^ message
          | `Protocol message -> "HTTP protocol: " ^ message
          | `Timeout -> "HTTP request timed out"
          | `Idle_timeout -> "HTTP response idle timeout"
          | `Body_too_large -> "HTTP response exceeds body limit"
          | `Closed -> "HTTP connection closed")
  with exn -> Error (Printexc.to_string exn)

let friendly_http_error config message =
  if
    contains_substring ~needle:"Connect_error" message
    || contains_substring ~needle:"connection refused" message
    || contains_substring ~needle:"ECONNREFUSED" message
  then
    Printf.sprintf
      "could not connect to Inn server at %s\nStart it with `systemctl --user start inn` (the systemd user service), `inn daemon`, or `inn server`; use `--base-url URL` to query a different server."
      config.Inn.Config.base_url
  else message

let run_http config method_ path =
  match http_request config method_ path with
  | Ok (status, body) when status >= 200 && status < 300 ->
      print_string body;
      0
  | Ok (_status, body) ->
      prerr_string body;
      1
  | Error message ->
      prerr_endline (friendly_http_error config message);
      1

let server config =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw -> Inn.Server.run ~sw ~env config

let rec mkdir_p path =
  if path = "" || path = "." || Sys.file_exists path then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)

let runtime_path config name = Filename.concat config.Inn.Config.state_dir name
let pid_path config = runtime_path config "server.pid"
let registry_path config = runtime_path config "server.json"
let log_path config = runtime_path config "server.log"

let process_alive pid =
  try
    Unix.kill pid 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) -> true
  | Unix.Unix_error _ -> false

let read_file path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
        Some (really_input_string channel (in_channel_length channel)))
  with Sys_error _ -> None

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let read_pid config =
  match read_file (pid_path config) with
  | None -> None
  | Some contents -> int_of_string_opt (String.trim contents)

let daemon_instance_id () =
  Random.self_init ();
  Printf.sprintf "%d-%.0f-%d" (Unix.getpid ()) (Unix.gettimeofday () *. 1000.)
    (Random.bits ())

let write_daemon_registry config pid instance_id =
  let json =
    `Assoc
      [
        ("pid", `Int pid);
        ("instanceId", `String instance_id);
        ("baseUrl", `String config.Inn.Config.base_url);
        ("dbPath", `String config.db_path);
        ("stateDir", `String config.state_dir);
        ("logPath", `String (log_path config));
        ("startedAtMs", `Int (int_of_float (Unix.gettimeofday () *. 1000.)));
      ]
  in
  write_file (pid_path config) (string_of_int pid ^ "\n");
  write_file (registry_path config) (Yojson.Safe.pretty_to_string json ^ "\n")

let remove_daemon_registry config =
  List.iter
    (fun path ->
      if Sys.file_exists path then
        try Sys.remove path with Sys_error _ -> ())
    [ pid_path config; registry_path config ]

let registry_instance_id config =
  match read_file (registry_path config) with
  | None -> None
  | Some contents -> (
      match Yojson.Safe.from_string contents with
      | `Assoc fields -> (
          match List.assoc_opt "instanceId" fields with
          | Some (`String value) -> Some value
          | _ -> None)
      | _ -> None
      | exception _ -> None)

let json_bool name value = (name, `Bool value)
let json_string name value = (name, `String value)
let json_int_opt name = function None -> [] | Some value -> [ (name, `Int value) ]
let json_string_opt name = function None -> [] | Some value -> [ (name, `String value) ]

let health_identity config =
  match http_request config "GET" "/health" with
  | Error message -> Error (friendly_http_error config message)
  | Ok (status, body) when status >= 200 && status < 300 -> (
      match Yojson.Safe.from_string body with
      | `Assoc fields ->
          let pid =
            match List.assoc_opt "pid" fields with
            | Some (`Int value) -> Some value
            | _ -> None
          in
          let instance_id =
            match List.assoc_opt "instanceId" fields with
            | Some (`String value) -> Some value
            | _ -> None
          in
          Ok (pid, instance_id)
      | _ -> Error "health response was not a JSON object"
      | exception exn -> Error (Printexc.to_string exn))
  | Ok (status, body) ->
      Error (Printf.sprintf "health returned HTTP %d: %s" status body)

let daemon_identity_matches config pid instance_id =
  match health_identity config with
  | Ok (Some health_pid, Some health_instance_id) ->
      health_pid = pid && String.equal health_instance_id instance_id
  | _ -> false

let daemon_status_json config =
  let pid = read_pid config in
  let instance_id = registry_instance_id config in
  let alive = Option.value (Option.map process_alive pid) ~default:false in
  let health =
    match health_identity config with
    | Ok (health_pid, health_instance_id) -> (true, None, health_pid, health_instance_id)
    | Error message -> (false, Some message, None, None)
  in
  let healthy, reason, health_pid, health_instance_id = health in
  let managed =
    match (pid, instance_id) with
    | Some pid, Some instance_id when alive ->
        daemon_identity_matches config pid instance_id
    | _ -> false
  in
  `Assoc
    ([
       json_bool "running" (alive && healthy);
       json_bool "alive" alive;
       json_bool "healthy" healthy;
       json_bool "managed" managed;
       json_string "baseUrl" config.Inn.Config.base_url;
       json_string "stateDir" config.state_dir;
       json_string "dbPath" config.db_path;
       json_string "pidPath" (pid_path config);
       json_string "logPath" (log_path config);
     ]
    @ json_int_opt "pid" pid
    @ json_string_opt "instanceId" instance_id
    @ json_int_opt "healthPid" health_pid
    @ json_string_opt "healthInstanceId" health_instance_id
    @ json_string_opt "reason" reason)

let print_json json =
  print_endline (Yojson.Safe.pretty_to_string json)

let status config =
  let json = daemon_status_json config in
  print_json json;
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "running" fields with
      | Some (`Bool true) -> 0
      | _ -> 1)
  | _ -> 1

let wait_for_health config pid instance_id =
  let deadline = Unix.gettimeofday () +. 10.0 in
  let rec loop last_error =
    match health_identity config with
    | Ok (Some health_pid, Some health_instance_id)
      when health_pid = pid && String.equal health_instance_id instance_id ->
        Ok ()
    | Ok _ as result ->
        if Unix.gettimeofday () >= deadline then
          Error
            (Printf.sprintf "daemon did not report expected identity: %s"
               (match result with
               | Ok (pid, instance) ->
                   Yojson.Safe.to_string
                     (`Assoc
                       (json_int_opt "pid" pid
                       @ json_string_opt "instanceId" instance))
               | Error message -> message))
        else (
          Unix.sleepf 0.1;
          loop last_error)
    | Error message ->
        if Unix.gettimeofday () >= deadline then Error message
        else if process_alive pid then (
          Unix.sleepf 0.1;
          loop (Some message))
        else
          Error
            (Option.value last_error
               ~default:
                 (Printf.sprintf "daemon process %d exited during startup" pid))
  in
  loop None

let daemon config =
  mkdir_p config.Inn.Config.state_dir;
  match (read_pid config, registry_instance_id config) with
  | Some pid, Some instance_id
    when process_alive pid && daemon_identity_matches config pid instance_id ->
      print_json (daemon_status_json config);
      0
  | _ ->
      let instance_id = daemon_instance_id () in
      match Unix.fork () with
      | 0 ->
          ignore (Unix.setsid ());
          Inn.Server.set_instance_id instance_id;
          let fd =
            Unix.openfile (log_path config)
              [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_APPEND ]
              0o600
          in
          Unix.dup2 fd Unix.stdout;
          Unix.dup2 fd Unix.stderr;
          Unix.close fd;
          server config;
          exit 0
      | pid -> (
          write_daemon_registry config pid instance_id;
          match wait_for_health config pid instance_id with
          | Ok () ->
              print_json (daemon_status_json config);
              0
          | Error message ->
              prerr_endline message;
              print_json (daemon_status_json config);
              1)

let stop config =
  match (read_pid config, registry_instance_id config) with
  | None, _ ->
      remove_daemon_registry config;
      print_json (daemon_status_json config);
      0
  | Some pid, Some instance_id ->
      if not (process_alive pid) then (
        remove_daemon_registry config;
        print_json (daemon_status_json config);
        0)
      else if not (daemon_identity_matches config pid instance_id) then (
        prerr_endline
          (Printf.sprintf
             "refusing to stop pid %d because it is not an identity-verified Inn daemon"
             pid);
        print_json (daemon_status_json config);
        1)
      else (
        Unix.kill pid Sys.sigterm;
        let deadline = Unix.gettimeofday () +. 5.0 in
        while process_alive pid && Unix.gettimeofday () < deadline do
          Unix.sleepf 0.1
        done;
        if process_alive pid then Unix.kill pid Sys.sigkill;
        remove_daemon_registry config;
        print_json (daemon_status_json config);
        0)
  | Some pid, None ->
      prerr_endline
        (Printf.sprintf
           "refusing to stop pid %d because %s has no instance id" pid
           (registry_path config));
      print_json (daemon_status_json config);
      1

let restart config =
  let stopped = stop config in
  if stopped <> 0 then stopped else daemon config

let mcp config =
  let tool_call =
    Inn.Mcp.tool_call
      ~request:(fun path -> http_request config "GET" path)
      ~status:(fun () -> daemon_status_json config)
      ~base_url:config.Inn.Config.base_url
  in
  Inn.Mcp.run ~tool_call ()

let finish code = if code <> 0 then exit code

let get path config = finish (run_http config "GET" path)

let health config = get "/health" config
let services lookback config =
  get ("/services" ^ query [ ("lookback", lookback) ]) config
let stats lookback config =
  get ("/stats" ^ query [ ("lookback", lookback) ]) config
let instructions config = get "/instructions" config
let endpoints config = get "/endpoints" config
let openapi config = get "/openapi.json" config

(* inn docs lists the guides; inn docs NAME reads one as Markdown. *)
let docs name config =
  match name with
  | None -> get "/docs" config
  | Some name -> get ("/docs/" ^ percent_encode name) config

let traces service lookback cursor limit config =
  get
    ("/traces"
    ^ query
        [
          ("service", service);
          ("lookback", lookback);
          ("cursor", cursor);
          ("limit", Some (string_of_int limit));
        ])
    config

(* CLI tree rendering: one line per span, indented by depth, with the
   operation, the service, the duration, and an error mark (tree-d24c). *)
let json_field name = function
  | `Assoc fields -> (
      match List.assoc_opt name fields with Some value -> value | None -> `Null)
  | _ -> `Null

let json_text = function
  | `String value -> value
  | `Null -> ""
  | `Int value -> string_of_int value
  | `Float value -> string_of_float value
  | value -> Yojson.Safe.to_string value

let json_number = function
  | `Float value -> value
  | `Int value -> float_of_int value
  | _ -> 0.

let json_flag = function `Bool value -> value | _ -> false
let json_items = function `List items -> items | _ -> []

let span_line span =
  let depth = match json_field "depth" span with `Int value -> value | _ -> 0 in
  let operation = json_text (json_field "operationName" span) in
  let service = json_text (json_field "serviceName" span) in
  let mark = if json_text (json_field "status" span) = "error" then "!" else "-" in
  let duration =
    if json_flag (json_field "isRunning" span) then "running"
    else Printf.sprintf "%.3fms" (json_number (json_field "durationMs" span))
  in
  Printf.sprintf "%s%s %s  (%s, %s)\n"
    (String.make (2 * max 0 depth) ' ') mark operation service duration

let render_trace json =
  let summary = json_field "summary" json in
  let spans = json_items (json_field "spans" json) in
  let warnings = json_items (json_field "warnings" json) in
  let buffer = Buffer.create 1024 in
  Buffer.add_string buffer
    (Printf.sprintf "trace %s  %d spans  %s  %s\n"
       (json_text (json_field "traceId" summary))
       (match json_field "spanCount" summary with `Int value -> value | _ -> List.length spans)
       (Printf.sprintf "%.3fms" (json_number (json_field "durationMs" summary)))
       (if json_flag (json_field "isRunning" summary) then "running" else "finished"));
  List.iter (fun span -> Buffer.add_string buffer (span_line span)) spans;
  List.iter
    (fun warning -> Buffer.add_string buffer ("warning: " ^ json_text warning ^ "\n"))
    warnings;
  Buffer.contents buffer

let trace json_flag trace_id config =
  let path = "/traces/" ^ percent_encode trace_id in
  match http_request config "GET" path with
  | Ok (status, body) when status >= 200 && status < 300 ->
      if json_flag then (print_string body; 0)
      else
        (match Yojson.Safe.from_string body with
        | json -> print_string (render_trace json); 0
        | exception _ -> print_string body; 0)
  | Ok (_status, body) -> prerr_string body; 1
  | Error message -> prerr_endline (friendly_http_error config message); 1

let span span_id config = get ("/spans/" ^ percent_encode span_id) config

let trace_spans trace_id lookback cursor limit config =
  get
    ("/traces/" ^ percent_encode trace_id ^ "/spans"
    ^ query
        [
          ("lookback", lookback);
          ("cursor", cursor);
          ("limit", Some (string_of_int limit));
        ])
    config

let trace_logs trace_id lookback cursor attrs attr_contains limit config =
  get ("/traces/" ^ percent_encode trace_id ^ "/logs" ^ query
    ([ ("lookback", lookback); ("cursor", cursor);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let span_logs span_id lookback cursor attrs attr_contains limit config =
  get ("/spans/" ^ percent_encode span_id ^ "/logs" ^ query
    ([ ("lookback", lookback); ("cursor", cursor);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let search_spans service trace_id operation parent_operation status lookback
    cursor attrs attr_contains min_duration limit config =
  get ("/spans/search" ^ query
    ([ ("service", service); ("traceId", trace_id);
       ("operation", operation); ("parentOperation", parent_operation);
       ("status", status); ("lookback", lookback); ("cursor", cursor);
       ("minDurationMs", Option.map string_of_float min_duration);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let search_traces service operation status lookback cursor attrs attr_contains
    min_duration text limit config =
  get ("/traces/search" ^ query
    ([ ("service", service); ("operation", operation); ("status", status);
       ("lookback", lookback); ("cursor", cursor); ("text", text);
       ("minDurationMs", Option.map string_of_float min_duration);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let logs service severity contains lookback cursor attrs attr_contains
    min_severity limit config =
  get ("/logs" ^ query
    ([ ("service", service); ("severity", severity);
       ("contains", contains); ("lookback", lookback); ("cursor", cursor);
       ("minSeverity", min_severity); ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let search_logs service trace_id span_id severity body lookback cursor attrs
    attr_contains min_severity limit config =
  get ("/logs/search" ^ query
    ([ ("service", service); ("traceId", trace_id); ("spanId", span_id);
       ("severity", severity); ("body", body); ("lookback", lookback);
       ("cursor", cursor); ("minSeverity", min_severity);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let trace_stats_query group_by agg service operation status lookback attrs
    attr_contains min_duration limit config =
  get ("/traces/stats" ^ query
    ([ ("groupBy", Some group_by); ("agg", Some agg); ("service", service);
       ("operation", operation); ("status", status); ("lookback", lookback);
       ("minDurationMs", Option.map string_of_float min_duration);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let log_stats_query group_by service trace_id span_id severity body lookback
    attrs attr_contains min_severity limit config =
  get ("/logs/stats" ^ query
    ([ ("groupBy", Some group_by); ("agg", Some "count");
       ("service", service); ("traceId", trace_id); ("spanId", span_id);
       ("severity", severity); ("body", body); ("lookback", lookback);
       ("minSeverity", min_severity);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let facets kind field key service lookback limit config =
  get
    ("/facets"
    ^ query
        [
          ("type", Some kind);
          ("field", Some field);
          ("key", key);
          ("service", service);
          ("lookback", lookback);
          ("limit", Some (string_of_int limit));
        ])
    config

let ai_calls service trace_id session_id function_id provider model operation
    status finish_reason text lookback cursor min_duration limit config =
  get
    ("/ai/calls"
    ^ query
        [
          ("service", service);
          ("traceId", trace_id);
          ("sessionId", session_id);
          ("functionId", function_id);
          ("provider", provider);
          ("model", model);
          ("operation", operation);
          ("status", status);
          ("finishReason", finish_reason);
          ("text", text);
           ("minDurationMs", Option.map string_of_float min_duration);
          ("lookback", lookback);
          ("cursor", cursor);
          ("limit", Some (string_of_int limit));
        ])
    config

let ai_call span_id config =
  get ("/ai/calls/" ^ percent_encode span_id) config

let ai_stats group_by agg service trace_id session_id function_id provider model
    operation status finish_reason text lookback min_duration limit config =
  get
    ("/ai/stats"
    ^ query
        [
          ("groupBy", Some group_by);
          ("agg", Some agg);
          ("service", service);
          ("traceId", trace_id);
          ("sessionId", session_id);
          ("functionId", function_id);
          ("provider", provider);
          ("model", model);
          ("operation", operation);
          ("status", status);
          ("finishReason", finish_reason);
          ("text", text);
           ("minDurationMs", Option.map string_of_float min_duration);
          ("lookback", lookback);
          ("limit", Some (string_of_int limit));
        ])
    config

let metrics service name lookback cursor limit config =
  get
    ("/metrics"
    ^ query
        [
          ("service", service);
          ("name", name);
          ("lookback", lookback);
          ("cursor", cursor);
          ("limit", Some (string_of_int limit));
        ])
    config

let service_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "service" ] ~docv:"SERVICE" ~doc:"Filter by service.name.")

let severity_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "severity" ] ~docv:"SEVERITY" ~doc:"Filter logs by severity text.")

let contains_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "contains" ] ~docv:"TEXT" ~doc:"Filter logs by body substring.")

let body_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "body" ] ~docv:"TEXT" ~doc:"Filter logs by body substring.")

let metric_name_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "name" ] ~docv:"NAME" ~doc:"Filter metrics by metric name.")

let limit_t =
  Arg.(
    value
    & opt int 100
    & info [ "limit" ] ~docv:"N" ~doc:"Maximum rows to return.")

let lookback_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "lookback" ] ~docv:"WINDOW"
        ~doc:
          "Relative time window: Nm, Nh, Nd, or all. Lists default to 1h; \
           stats, facets, and services default to all.")

let cursor_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "cursor" ] ~docv:"CURSOR"
        ~doc:"Opaque nextCursor value from a previous list response.")

let trace_id_t =
  Arg.(required & pos 0 (some string) None & info [] ~docv:"TRACE_ID")

let span_id_t =
  Arg.(required & pos 0 (some string) None & info [] ~docv:"SPAN_ID")

let trace_id_filter_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "trace-id" ] ~docv:"TRACE_ID" ~doc:"Filter by trace id.")

let span_id_filter_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "span-id" ] ~docv:"SPAN_ID" ~doc:"Filter by span id.")

let operation_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "operation" ] ~docv:"NAME" ~doc:"Filter by operation name.")

let parent_operation_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "parent" ] ~docv:"NAME" ~doc:"Filter by parent operation name.")

let status_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "status" ] ~docv:"STATUS" ~doc:"Filter by span status.")

let session_id_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "session-id" ] ~docv:"SESSION" ~doc:"Filter by AI session id.")

let function_id_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "function-id" ] ~docv:"FUNCTION" ~doc:"Filter by AI function id.")

let provider_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "provider" ] ~docv:"PROVIDER" ~doc:"Filter by AI provider.")

let model_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "model" ] ~docv:"MODEL" ~doc:"Filter by AI model.")

let text_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "text" ] ~docv:"TEXT" ~doc:"Filter AI calls by text.")

let finish_reason_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "finish-reason" ] ~docv:"REASON"
        ~doc:"Filter AI calls by finish reason substring.")

let json_t =
  Arg.(
    value
    & flag
    & info [ "json" ] ~doc:"Print the raw JSON response instead of the tree.")

let attr_pair =
  let parse text =
    match String.index_opt text '=' with
    | Some index when index > 0 ->
        let key = String.sub text 0 index in
        let value =
          String.sub text (index + 1) (String.length text - index - 1)
        in
        Ok (key, value)
    | _ -> Error (`Msg "expected KEY=VALUE")
  in
  let print ppf (key, value) = Format.fprintf ppf "%s=%s" key value in
  Arg.conv (parse, print)

let attrs_t =
  Arg.(value & opt_all attr_pair [] & info [ "attr" ] ~docv:"KEY=VALUE"
    ~doc:"Require an exact attribute key/value match. May be repeated.")

let attr_contains_t =
  Arg.(value & opt_all attr_pair [] & info [ "attr-contains" ]
    ~docv:"KEY=TEXT"
    ~doc:"Require a literal, case-insensitive substring within an attribute. May be repeated.")

let min_duration_t =
  Arg.(value & opt (some float) None & info [ "min-duration-ms" ]
    ~docv:"MILLISECONDS" ~doc:"Require at least this duration in milliseconds.")

let min_severity_t =
  Arg.(value & opt (some string) None & info [ "min-severity" ]
    ~docv:"LEVEL" ~doc:"Minimum OTLP severity (trace, debug, info, warn, error, fatal).")

let group_by_t =
  Arg.(required & pos 0 (some string) None & info [] ~docv:"GROUP_BY")

let agg_t =
  Arg.(required & pos 1 (some string) None & info [] ~docv:"AGG")

let facet_type_t =
  Arg.(required & pos 0 (some string) None & info [] ~docv:"traces|logs")

let facet_field_t =
  Arg.(required & pos 1 (some string) None & info [] ~docv:"FIELD")

let facet_key_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "key" ] ~docv:"KEY"
        ~doc:"Attribute key for attribute_values facets.")

let cmd name doc term =
  Cmd.v (Cmd.info name ~doc) term

let help_default = Term.(ret (const (`Help (`Pager, None))))

let code_term f = Term.(const (fun config -> finish (f config)) $ config_t)

let server_cmd =
  cmd "server" "Run the Inn local HTTP ingest/query server."
    Term.(const server $ config_t)

let daemon_cmd =
  cmd "daemon" "Run the Inn server as a managed background daemon."
    (code_term daemon)

let status_cmd =
  cmd "status" "Show managed daemon status." (code_term status)

let health_cmd =
  cmd "health" "Check the configured Inn server." Term.(const health $ config_t)

let stop_cmd =
  cmd "stop" "Stop the managed Inn daemon." (code_term stop)

let restart_cmd =
  cmd "restart" "Restart the managed Inn daemon." (code_term restart)

let services_cmd =
  cmd "services" "List services known to Inn."
    Term.(const services $ lookback_t $ config_t)

let traces_cmd =
  cmd "traces" "List trace summaries."
    Term.(const traces $ service_t $ lookback_t $ cursor_t $ limit_t $ config_t)

let trace_cmd =
  cmd "trace" "Read one trace by trace id as a tree."
    Term.(
      const (fun json_flag trace_id config ->
          finish (trace json_flag trace_id config))
      $ json_t $ trace_id_t $ config_t)

let span_cmd =
  cmd "span" "Read one span by span id."
    Term.(const span $ span_id_t $ config_t)

let trace_spans_cmd =
  cmd "trace-spans" "List spans for a trace."
    Term.(const trace_spans $ trace_id_t $ lookback_t $ cursor_t $ limit_t $ config_t)

let trace_logs_cmd =
  cmd "trace-logs" "List logs correlated with a trace."
    Term.(const trace_logs $ trace_id_t $ lookback_t $ cursor_t $ attrs_t
       $ attr_contains_t $ limit_t $ config_t)

let span_logs_cmd =
  cmd "span-logs" "List logs correlated with a span."
    Term.(const span_logs $ span_id_t $ lookback_t $ cursor_t $ attrs_t
       $ attr_contains_t $ limit_t $ config_t)

let search_spans_cmd =
  cmd "search-spans" "Search spans by service, operation, status, and attributes."
    Term.(const search_spans $ service_t $ trace_id_filter_t $ operation_t
      $ parent_operation_t $ status_t $ lookback_t $ cursor_t $ attrs_t
      $ attr_contains_t $ min_duration_t $ limit_t $ config_t)

let search_traces_cmd =
  cmd "search-traces" "Search trace summaries by span filters."
    Term.(const search_traces $ service_t $ operation_t $ status_t $ lookback_t
      $ cursor_t $ attrs_t $ attr_contains_t $ min_duration_t $ text_t
      $ limit_t $ config_t)

let logs_cmd =
  cmd "logs" "List logs."
    Term.(const logs $ service_t $ severity_t $ contains_t $ lookback_t
      $ cursor_t $ attrs_t $ attr_contains_t $ min_severity_t
      $ limit_t $ config_t)

let search_logs_cmd =
  cmd "search-logs" "Search logs by service, correlation ids, body, and attributes."
    Term.(
      const search_logs $ service_t $ trace_id_filter_t $ span_id_filter_t
      $ severity_t $ body_t $ lookback_t $ cursor_t $ attrs_t
       $ attr_contains_t $ min_severity_t $ limit_t $ config_t)

let trace_stats_cmd =
  cmd "trace-stats" "Aggregate trace statistics."
    Term.(
      const trace_stats_query $ group_by_t $ agg_t $ service_t $ operation_t
      $ status_t $ lookback_t $ attrs_t $ attr_contains_t $ min_duration_t
       $ limit_t $ config_t)

let log_stats_cmd =
  cmd "log-stats" "Aggregate log counts."
    Term.(const log_stats_query $ group_by_t $ service_t $ trace_id_filter_t
      $ span_id_filter_t $ severity_t $ body_t $ lookback_t $ attrs_t
      $ attr_contains_t $ min_severity_t $ limit_t $ config_t)

let facets_cmd =
  cmd "facets" "List trace or log facet values."
    Term.(
      const facets $ facet_type_t $ facet_field_t $ facet_key_t $ service_t
      $ lookback_t $ limit_t $ config_t)

let ai_calls_cmd =
  cmd "ai-calls" "Search AI call spans."
    Term.(
      const ai_calls $ service_t $ trace_id_filter_t $ session_id_t
      $ function_id_t $ provider_t $ model_t $ operation_t $ status_t
      $ finish_reason_t $ text_t
      $ lookback_t $ cursor_t $ min_duration_t $ limit_t $ config_t)

let ai_call_cmd =
  cmd "ai-call" "Read one AI call by span id."
    Term.(const ai_call $ span_id_t $ config_t)

let ai_stats_cmd =
  cmd "ai-stats" "Aggregate AI call statistics."
    Term.(
      const ai_stats $ group_by_t $ agg_t $ service_t $ trace_id_filter_t
      $ session_id_t $ function_id_t $ provider_t $ model_t $ operation_t
      $ status_t $ finish_reason_t $ text_t $ lookback_t $ min_duration_t
      $ limit_t $ config_t)

let metrics_cmd =
  cmd "metrics" "List metric points."
    Term.(
      const metrics $ service_t $ metric_name_t $ lookback_t $ cursor_t $ limit_t
      $ config_t)

let stats_cmd =
  cmd "stats" "Show store statistics." Term.(const stats $ lookback_t $ config_t)

let instructions_cmd =
  cmd "instructions" "Print OTLP setup instructions."
    Term.(const instructions $ config_t)

let endpoints_cmd =
  cmd "endpoints" "Print Inn endpoint and exporter configuration."
    Term.(const endpoints $ config_t)

let openapi_cmd =
  cmd "openapi" "Print the Inn OpenAPI document."
    Term.(const openapi $ config_t)

let docs_name_t =
  Arg.(
    value
    & pos 0 (some string) None
    & info [] ~docv:"NAME" ~doc:"Guide name: debug, effect, or eta.")

let docs_cmd =
  cmd "docs" "List the Inn guides, or print one guide as Markdown."
    Term.(const docs $ docs_name_t $ config_t)

let mcp_cmd =
  cmd "mcp" "Run the Inn MCP stdio server." Term.(const mcp $ config_t)

let root =
  let doc = "cwd-independent local OpenTelemetry collector and query service" in
  let exits = Cmd.Exit.defaults in
  Cmd.group (Cmd.info "inn" ~version ~doc ~exits)
    ~default:help_default
    [
      server_cmd;
      daemon_cmd;
      status_cmd;
      health_cmd;
      stop_cmd;
      restart_cmd;
      services_cmd;
      traces_cmd;
      trace_cmd;
      span_cmd;
      trace_spans_cmd;
      trace_logs_cmd;
      span_logs_cmd;
      search_spans_cmd;
      search_traces_cmd;
      logs_cmd;
      search_logs_cmd;
      trace_stats_cmd;
      log_stats_cmd;
      facets_cmd;
      ai_calls_cmd;
      ai_call_cmd;
      ai_stats_cmd;
      metrics_cmd;
      stats_cmd;
      instructions_cmd;
      endpoints_cmd;
      openapi_cmd;
      docs_cmd;
      mcp_cmd;
    ]

let friendly_unix_error error operation arg =
  match (error, operation) with
  | Unix.EADDRINUSE, "bind" ->
      "could not start Inn server: address is already in use\n\
       Another process is already bound to the configured host/port.\n\
       Stop an existing Inn daemon with `inn stop`, or choose another port with `--port PORT`."
  | Unix.EADDRNOTAVAIL, "bind" ->
      "could not start Inn server: bind host is not available on this machine\n\
       Use `--host 127.0.0.1` for local-only access, or choose an address assigned to this host."
  | Unix.EACCES, "bind" ->
      "could not start Inn server: permission denied while binding the configured host/port\n\
       Choose an unprivileged port with `--port PORT`, or fix the process permissions."
  | Unix.EACCES, _ ->
      Printf.sprintf "permission denied while running %s%s" operation
        (if String.equal arg "" then "" else " on " ^ arg)
  | Unix.ENOENT, _ ->
      Printf.sprintf "path not found while running %s%s" operation
        (if String.equal arg "" then "" else ": " ^ arg)
  | Unix.ENOSPC, _ ->
      "not enough disk space for the requested operation"
  | Unix.EMFILE, _ | Unix.ENFILE, _ ->
      "too many open files; close other processes or raise the file descriptor limit"
  | _ ->
      let target = if String.equal arg "" then "" else " " ^ arg in
      Printf.sprintf "%s%s failed: %s" operation target
        (Unix.error_message error)

let friendly_exception = function
  | Sys.Break -> "interrupted"
  | Unix.Unix_error (error, operation, arg) ->
      friendly_unix_error error operation arg
  | Sys_error message -> message
  | Invalid_argument message when String.trim message <> "" ->
      "invalid argument: " ^ message
  | Failure message when String.trim message <> "" -> message
  | exn ->
      "unexpected internal error: " ^ Printexc.to_string exn
      ^ "\nThis is a bug in Inn. Re-run with OCAMLRUNPARAM=b for a backtrace."

let exception_exit_code = function
  | Sys.Break -> 130
  | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ | Failure _ -> 1
  | _ -> 125

let () =
  try exit (Cmd.eval ~catch:false root) with exn ->
    prerr_endline (friendly_exception exn);
    exit (exception_exit_code exn)
