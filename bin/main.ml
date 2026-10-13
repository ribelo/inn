open Cmdliner

module H = Ox_http
module Cap = Ox_caps.Cap

let version = Inn.Version.value

(* ^inndoor-k4px: runtime ownership is explicit; capabilities travel separately. *)
type runtime = {
  base : Eio_unix.Stdenv.base;
  owned : (Eio.Switch.t -> int) -> int;
}

let exn_hook = ref (fun _exn -> ("internal error", 125))

let delay ~caps:(caps : < Cap.stderr; .. >) body =
  fun () ->
    try body ()
    with
    | Eio.Cancel.Cancelled _ as exn ->
        Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
    | exn ->
      let message, code = !exn_hook exn in
      Ox_caps.Cap_stdlib.prerr_endline ~caps message;
      code

let getenv ~caps key =
  match Ox_caps.Cap_sys.getenv_opt ~caps key with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None

let env_with_overrides ~caps overrides key =
  match List.assoc_opt key overrides with
  | Some (Some value) -> Some value
  | _ -> getenv ~caps key

let config ~caps:(caps : < Cap.env; .. >) state_dir host port base_url max_db_size_mb =
  let int_override = Option.map string_of_int in
  let overrides =
    [
      ("INN_STATE_DIR", state_dir);
      ("INN_HOST", host);
      ("INN_PORT", int_override port);
      ("INN_BASE_URL", base_url);
      ("INN_MAX_DB_SIZE_MB", int_override max_db_size_mb);
    ]
  in
  match Inn.Config.resolve ~caps ~env:(env_with_overrides ~caps overrides) () with
  | Ok config -> config
  | Error message -> failwith message

let state_dir_t =
  Arg.(
    value
    & opt (some string) None
    & info [ "state-dir" ] ~docv:"DIR"
        ~doc:"User-level Inn state directory.")

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

let max_db_size_mb_t =
  Arg.(
    value
    & opt (some int) None
    & info [ "max-db-size-mb" ] ~docv:"MB"
        ~doc:"Store budget in megabytes (default 1024). Inn keeps the newest telemetry that fits.")

let config_t ~caps =
  Term.(
    const (config ~caps) $ state_dir_t $ host_t $ port_t $ base_url_t
    $ max_db_size_mb_t)

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

let describe_http_error = function
  | `Connect message -> "connection refused: " ^ message
  | `Tls message -> "TLS: " ^ message
  | `Protocol message -> "HTTP protocol: " ^ message
  | `Timeout -> "HTTP request timed out"
  | `Idle_timeout -> "HTTP response idle timeout"
  | `Body failure -> (
      match failure.H.Client.reason with
      | `Too_large -> "HTTP response exceeds body limit"
      | `Truncated -> "HTTP protocol: truncated response body"
      | `Malformed message -> "HTTP protocol: " ^ message
      | `Timeout -> "HTTP request timed out"
      | `Idle_timeout -> "HTTP response idle timeout"
      | `Tls message -> "TLS: " ^ message
      | `Closed -> "HTTP connection closed"
      | `Connect message -> "connection refused: " ^ message)
  | `Closed -> "HTTP connection closed"

let http_request ~runtime config method_ path =
  let url = trim_trailing_slash config.Inn.Config.base_url ^ path in
  let outcome = ref None in
  (* The owned boundary classifies cancellation to an exit code; retain the
     exception so this helper still propagates it to its caller. ^innlint-b7km *)
  let cancellation = ref None in
  ignore
    (runtime.owned (fun sw ->
         let net = Eio.Stdenv.net runtime.base in
         let clock = Eio.Stdenv.clock runtime.base in
         (try
            let client = H.Client.create ~sw ~net ~clock () in
            outcome :=
              Some
                (match H.Client.request client ~method_ ~url () with
                | Ok response -> (
                    match response.body with
                    | `Read bytes -> Ok (response.status, Bytes.to_string bytes)
                    | `Skipped -> Error "HTTP response body was not read")
                | Error error -> Error (describe_http_error error))
          with
          | Eio.Cancel.Cancelled _ as exn ->
              let backtrace = Printexc.get_raw_backtrace () in
              cancellation := Some (exn, backtrace);
              Printexc.raise_with_backtrace exn backtrace
          | exn -> outcome := Some (Error (Printexc.to_string exn)));
         0));
  match !cancellation with
  | Some (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
  | None -> (
      match !outcome with
      | Some result -> result
      | None -> Error "HTTP request did not run")

let friendly_http_error config message =
  if
    contains_substring ~needle:"Connect_error" message
    || contains_substring ~needle:"connection refused" message
    || contains_substring ~needle:"ECONNREFUSED" message
  then
    Printf.sprintf
      "could not connect to Inn server at %s\nInn runs as the systemd user service; restart it with `systemctl --user restart inn`. Use `--base-url URL` to query a different server."
      config.Inn.Config.base_url
  else message

let run_http ~caps:(caps : < Cap.stdout; Cap.stderr; .. >) ~runtime config method_ path =
  match http_request ~runtime config method_ path with
  | Ok (status, body) when status >= 200 && status < 300 ->
      Ox_caps.Cap_stdlib.print_string ~caps body;
      0
  | Ok (_status, body) ->
      Ox_caps.Cap_stdlib.prerr_string ~caps body;
      1
  | Error message ->
      Ox_caps.Cap_stdlib.prerr_endline ~caps (friendly_http_error config message);
      1

let server ~caps ~runtime config =
  runtime.owned (fun sw ->
      Inn.Server.run ~caps ~sw ~env:runtime.base config;
      0)

let mcp ~caps ~runtime config =
  let tool_call =
    Inn.Mcp.tool_call
      ~request:(fun path -> http_request ~runtime config "GET" path)
      ~base_url:config.Inn.Config.base_url
  in
  Inn.Mcp.run ~caps ~tool_call ()

let get ~caps ~runtime path config = run_http ~caps ~runtime config "GET" path

let health ~caps ~runtime config = get ~caps ~runtime "/health" config
let status ~caps ~runtime config = get ~caps ~runtime "/status" config
let services ~caps ~runtime lookback config =
  get ~caps ~runtime ("/services" ^ query [ ("lookback", lookback) ]) config
let stats ~caps ~runtime lookback config =
  get ~caps ~runtime ("/stats" ^ query [ ("lookback", lookback) ]) config
let instructions ~caps ~runtime config = get ~caps ~runtime "/instructions" config
let endpoints ~caps ~runtime config = get ~caps ~runtime "/endpoints" config
let openapi ~caps ~runtime config = get ~caps ~runtime "/openapi.json" config

(* inn docs lists the guides; inn docs NAME reads one as Markdown. *)
let docs ~caps ~runtime name config =
  match name with
  | None -> get ~caps ~runtime "/docs" config
  | Some name -> get ~caps ~runtime ("/docs/" ^ percent_encode name) config

let traces ~caps ~runtime service lookback cursor limit config =
  get ~caps ~runtime
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

let trace ~caps:(caps : < Cap.stdout; Cap.stderr; .. >) ~runtime json_flag trace_id config =
  let path = "/traces/" ^ percent_encode trace_id in
  match http_request ~runtime config "GET" path with
  | Ok (status, body) when status >= 200 && status < 300 ->
      if json_flag then (
        Ox_caps.Cap_stdlib.print_string ~caps body;
        0)
      else
        (match Yojson.Safe.from_string body with
        | json ->
            Ox_caps.Cap_stdlib.print_string ~caps (render_trace json);
            0
        | exception Yojson.Json_error _ ->
            Ox_caps.Cap_stdlib.print_string ~caps body;
            0)
  | Ok (_status, body) ->
      Ox_caps.Cap_stdlib.prerr_string ~caps body;
      1
  | Error message ->
      Ox_caps.Cap_stdlib.prerr_endline ~caps
        (friendly_http_error config message);
      1

let span ~caps ~runtime span_id config = get ~caps ~runtime ("/spans/" ^ percent_encode span_id) config

let trace_spans ~caps ~runtime trace_id lookback cursor limit config =
  get ~caps ~runtime
    ("/traces/" ^ percent_encode trace_id ^ "/spans"
    ^ query
        [
          ("lookback", lookback);
          ("cursor", cursor);
          ("limit", Some (string_of_int limit));
        ])
    config

let trace_logs ~caps ~runtime trace_id lookback cursor attrs attr_contains limit config =
  get ~caps ~runtime ("/traces/" ^ percent_encode trace_id ^ "/logs" ^ query
    ([ ("lookback", lookback); ("cursor", cursor);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let span_logs ~caps ~runtime span_id lookback cursor attrs attr_contains limit config =
  get ~caps ~runtime ("/spans/" ^ percent_encode span_id ^ "/logs" ^ query
    ([ ("lookback", lookback); ("cursor", cursor);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let search_spans ~caps ~runtime service trace_id operation parent_operation status lookback
    cursor attrs attr_contains min_duration limit config =
  get ~caps ~runtime ("/spans/search" ^ query
    ([ ("service", service); ("traceId", trace_id);
       ("operation", operation); ("parentOperation", parent_operation);
       ("status", status); ("lookback", lookback); ("cursor", cursor);
       ("minDurationMs", Option.map string_of_float min_duration);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let search_traces ~caps ~runtime service operation status lookback cursor attrs attr_contains
    min_duration limit config =
  get ~caps ~runtime ("/traces/search" ^ query
    ([ ("service", service); ("operation", operation); ("status", status);
       ("lookback", lookback); ("cursor", cursor);
       ("minDurationMs", Option.map string_of_float min_duration);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let logs ~caps ~runtime service severity contains lookback cursor attrs attr_contains
    min_severity limit config =
  get ~caps ~runtime ("/logs" ^ query
    ([ ("service", service); ("severity", severity);
       ("contains", contains); ("lookback", lookback); ("cursor", cursor);
       ("minSeverity", min_severity); ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let search_logs ~caps ~runtime service trace_id span_id severity body lookback cursor attrs
    attr_contains min_severity limit config =
  get ~caps ~runtime ("/logs/search" ^ query
    ([ ("service", service); ("traceId", trace_id); ("spanId", span_id);
       ("severity", severity); ("body", body); ("lookback", lookback);
       ("cursor", cursor); ("minSeverity", min_severity);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let trace_stats_query ~caps ~runtime group_by agg service operation status lookback attrs
    attr_contains min_duration limit config =
  get ~caps ~runtime ("/traces/stats" ^ query
    ([ ("groupBy", Some group_by); ("agg", Some agg); ("service", service);
       ("operation", operation); ("status", status); ("lookback", lookback);
       ("minDurationMs", Option.map string_of_float min_duration);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let log_stats_query ~caps ~runtime group_by service trace_id span_id severity body lookback
    attrs attr_contains min_severity limit config =
  get ~caps ~runtime ("/logs/stats" ^ query
    ([ ("groupBy", Some group_by); ("agg", Some "count");
       ("service", service); ("traceId", trace_id); ("spanId", span_id);
       ("severity", severity); ("body", body); ("lookback", lookback);
       ("minSeverity", min_severity);
       ("limit", Some (string_of_int limit)) ]
     @ List.map attr_param attrs
     @ List.map attr_contains_param attr_contains)) config

let facets ~caps ~runtime kind field key service lookback limit config =
  get ~caps ~runtime
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


let metrics ~caps ~runtime service name lookback cursor limit config =
  get ~caps ~runtime
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

let later1 ~caps f t1 = Term.(const (fun a -> delay ~caps (fun () -> f a)) $ t1)

let later2 ~caps f t1 t2 = Term.(const (fun a b -> delay ~caps (fun () -> f a b)) $ t1 $ t2)

let later3 ~caps f t1 t2 t3 =
  Term.(const (fun a b c -> delay ~caps (fun () -> f a b c)) $ t1 $ t2 $ t3)

let later5 ~caps f t1 t2 t3 t4 t5 =
  Term.(const (fun a b c d e -> delay ~caps (fun () -> f a b c d e)) $ t1 $ t2 $ t3 $ t4 $ t5)

let later6 ~caps f t1 t2 t3 t4 t5 t6 =
  Term.(
    const (fun a b c d e g -> delay ~caps (fun () -> f a b c d e g))
    $ t1 $ t2 $ t3 $ t4 $ t5 $ t6)

let later7 ~caps f t1 t2 t3 t4 t5 t6 t7 =
  Term.(
    const (fun a b c d e g h -> delay ~caps (fun () -> f a b c d e g h))
    $ t1 $ t2 $ t3 $ t4 $ t5 $ t6 $ t7)

let later10 ~caps f t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 =
  Term.(
    const (fun a b c d e g h i j k -> delay ~caps (fun () -> f a b c d e g h i j k))
    $ t1 $ t2 $ t3 $ t4 $ t5 $ t6 $ t7 $ t8 $ t9 $ t10)

let later11 ~caps f t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t11 =
  Term.(
    const
      (fun a b c d e g h i j k l -> delay ~caps (fun () -> f a b c d e g h i j k l))
    $ t1 $ t2 $ t3 $ t4 $ t5 $ t6 $ t7 $ t8 $ t9 $ t10 $ t11)

let later12 ~caps f t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t11 t12 =
  Term.(
    const
      (fun a b c d e g h i j k l m ->
        delay ~caps (fun () -> f a b c d e g h i j k l m))
    $ t1 $ t2 $ t3 $ t4 $ t5 $ t6 $ t7 $ t8 $ t9 $ t10 $ t11 $ t12)

let later_unit1 ~caps f t1 = Term.(const (fun a -> delay ~caps (fun () -> f a; 0)) $ t1)

(* ^inndoor-k4px: callbacks capture authority supplied by the Door argument. *)
let commands ~caps ~runtime =
  let config_t = config_t ~caps:(caps :> Cap.env) in
  let stderr_caps = (caps :> Cap.stderr) in
  let output_caps = (caps :> < Cap.stdout; Cap.stderr >) in
  let server_cmd =
    cmd "server" "Run the Inn local HTTP ingest/query server."
      (later1 ~caps:stderr_caps (server
           ~caps:(caps :> < Cap.env; Cap.network; Cap.time; Cap.signal;
                            Cap.fs_read; Cap.fs_write; Cap.stderr >)
           ~runtime) config_t)
  in

  let status_cmd =
    cmd "status" "Show the state of the Inn server." (later1 ~caps:stderr_caps (status ~caps:output_caps ~runtime) config_t)
  in

  let health_cmd =
    cmd "health" "Check the configured Inn server." (later1 ~caps:stderr_caps (health ~caps:output_caps ~runtime) config_t)
  in

  let services_cmd =
    cmd "services" "List services known to Inn."
      (later2 ~caps:stderr_caps (services ~caps:output_caps ~runtime) lookback_t config_t)
  in

  let traces_cmd =
    cmd "traces" "List trace summaries."
      (later5 ~caps:stderr_caps (traces ~caps:output_caps ~runtime) service_t lookback_t cursor_t limit_t config_t)
  in

  let trace_cmd =
    cmd "trace" "Read one trace by trace id as a tree."
      (later3 ~caps:stderr_caps (trace ~caps:output_caps ~runtime) json_t trace_id_t config_t)
  in

  let span_cmd =
    cmd "span" "Read one span by span id." (later2 ~caps:stderr_caps (span ~caps:output_caps ~runtime) span_id_t config_t)
  in

  let trace_spans_cmd =
    cmd "trace-spans" "List spans for a trace."
      (later5 ~caps:stderr_caps (trace_spans ~caps:output_caps ~runtime) trace_id_t lookback_t cursor_t limit_t config_t)
  in

  let trace_logs_cmd =
    cmd "trace-logs" "List logs correlated with a trace."
      (later7 ~caps:stderr_caps (trace_logs ~caps:output_caps ~runtime) trace_id_t lookback_t cursor_t attrs_t attr_contains_t
         limit_t config_t)
  in

  let span_logs_cmd =
    cmd "span-logs" "List logs correlated with a span."
      (later7 ~caps:stderr_caps (span_logs ~caps:output_caps ~runtime) span_id_t lookback_t cursor_t attrs_t attr_contains_t
         limit_t config_t)
  in

  let search_spans_cmd =
    cmd "search-spans" "Search spans by service, operation, status, and attributes."
      (later12 ~caps:stderr_caps (search_spans ~caps:output_caps ~runtime) service_t trace_id_filter_t operation_t
         parent_operation_t status_t lookback_t cursor_t attrs_t attr_contains_t
         min_duration_t limit_t config_t)
  in

  let search_traces_cmd =
    cmd "search-traces" "Search trace summaries by span filters."
      (later10 ~caps:stderr_caps (search_traces ~caps:output_caps ~runtime) service_t operation_t status_t lookback_t cursor_t
         attrs_t attr_contains_t min_duration_t limit_t config_t)
  in

  let logs_cmd =
    cmd "logs" "List logs."
      (later10 ~caps:stderr_caps (logs ~caps:output_caps ~runtime) service_t severity_t contains_t lookback_t cursor_t attrs_t
         attr_contains_t min_severity_t limit_t config_t)
  in

  let search_logs_cmd =
    cmd "search-logs" "Search logs by service, correlation ids, body, and attributes."
      (later12 ~caps:stderr_caps (search_logs ~caps:output_caps ~runtime) service_t trace_id_filter_t span_id_filter_t severity_t
         body_t lookback_t cursor_t attrs_t attr_contains_t min_severity_t limit_t
         config_t)
  in

  let trace_stats_cmd =
    cmd "trace-stats" "Aggregate trace statistics."
      (later11 ~caps:stderr_caps (trace_stats_query ~caps:output_caps ~runtime) group_by_t agg_t service_t operation_t status_t
         lookback_t attrs_t attr_contains_t min_duration_t limit_t config_t)
  in

  let log_stats_cmd =
    cmd "log-stats" "Aggregate log counts."
      (later12 ~caps:stderr_caps (log_stats_query ~caps:output_caps ~runtime) group_by_t service_t trace_id_filter_t
         span_id_filter_t severity_t body_t lookback_t attrs_t attr_contains_t
         min_severity_t limit_t config_t)
  in

  let facets_cmd =
    cmd "facets" "List trace or log facet values."
      (later7 ~caps:stderr_caps (facets ~caps:output_caps ~runtime) facet_type_t facet_field_t facet_key_t service_t lookback_t
         limit_t config_t)
  in

  let metrics_cmd =
    cmd "metrics" "List metric points."
      (later6 ~caps:stderr_caps (metrics ~caps:output_caps ~runtime) service_t metric_name_t lookback_t cursor_t limit_t config_t)
  in

  let stats_cmd =
    cmd "stats" "Show store statistics." (later2 ~caps:stderr_caps (stats ~caps:output_caps ~runtime) lookback_t config_t)
  in

  let instructions_cmd =
    cmd "instructions" "Print OTLP setup instructions."
      (later1 ~caps:stderr_caps (instructions ~caps:output_caps ~runtime) config_t)
  in

  let endpoints_cmd =
    cmd "endpoints" "Print Inn endpoint and exporter configuration."
      (later1 ~caps:stderr_caps (endpoints ~caps:output_caps ~runtime) config_t)
  in

  let openapi_cmd =
    cmd "openapi" "Print the Inn OpenAPI document."
      (later1 ~caps:stderr_caps (openapi ~caps:output_caps ~runtime) config_t)
  in

  let docs_name_t =
    Arg.(
      value
      & pos 0 (some string) None
      & info [] ~docv:"NAME" ~doc:"Guide name: debug, effect, or ox.")
  in

  let docs_cmd =
    cmd "docs" "List the Inn guides, or print one guide as Markdown."
      (later2 ~caps:stderr_caps (docs ~caps:output_caps ~runtime) docs_name_t config_t)
  in

  let mcp_cmd =
    cmd "mcp" "Run the Inn MCP stdio server." (later_unit1 ~caps:stderr_caps (mcp ~caps:(caps :> < Cap.stdin; Cap.stdout >) ~runtime) config_t)
  in

  [
        server_cmd;
        status_cmd;
        health_cmd;
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
       Check `systemctl --user status inn`, or choose another port with `--port PORT`."
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
  exn_hook := (fun exn -> (friendly_exception exn, exception_exit_code exn));
  Ox_app.run_and_exit_with_args ~name:"inn"
       ~doc:"cwd-independent local OpenTelemetry collector and query service"
       ~version ~bare:`Help ~service_command:"door" ~usage_exit:124
       ~log_level:Ox_observability.Logger.Error
       ~journal_level:Ox_observability.Logger.Error
       ~service_args:(Term.const ())
       ~config:Ox_app.Config.none
       ~pp_err:(fun ppf () -> Format.pp_print_string ppf "inn")
       ~commands_with_env_code:(fun env _run_owned owned ->
         commands ~caps:env.Ox_app.Env.caps
           ~runtime:{ base = env.Ox_app.Env.base; owned })
       (fun _env _source () () _sw -> Ok ())
