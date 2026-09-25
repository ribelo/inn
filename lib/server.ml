module H = Eta_http
module S = Eta_http.Server
module Service = Eta_http_service
module Serve = Eta_http_service_eio.Serve

let max_body_bytes = 32 * 1024 * 1024

let daemon_instance_id = Atomic.make None
let set_instance_id value = Atomic.set daemon_instance_id (Some value)

let text_headers =
  H.Core.Header.unsafe_of_list [ ("content-type", "text/plain; charset=utf-8") ]

let json_response ?(status = 200) json =
  Service.Json.response ~status ~newline:true json

let text_response ?(status = 200) text =
  S.Response.text ~status ~headers:text_headers text

let error_response status code message =
  json_response ~status
    (`Assoc
      [
        ("error", `String code);
        ("message", `String message);
      ])

(* A 404 that can say where to look instead (aic-t8tl). *)
let error_response_with_details status code message details =
  json_response ~status
    (`Assoc
      (([ ("error", `String code); ("message", `String message) ]) @ details))

let otlp_error ?(headers = None) status code message =
  let response = json_response ~status
    (`Assoc [ ("code", `Int code); ("message", `String message) ]) in
  match headers with
  | None -> response
  | Some headers ->
      S.Response.make ~status ~headers ~body:(S.Response.body response)
        ~trailers:(S.Response.trailers response) ()

let otlp_response rejected_field (decoded : _ Otlp.decoded) =
  if decoded.rejected = 0 then json_response (`Assoc [])
  else json_response (`Assoc [ ("partialSuccess", `Assoc [
    (rejected_field, `Int decoded.rejected);
    ("errorMessage", `String decoded.error_message) ]) ])

let method_not_allowed () =
  error_response 405 "method_not_allowed" "method is not allowed for this endpoint"

let not_found () = error_response 404 "not_found" "endpoint not found"

(* The running build's identity. [started_at_ms] is captured when this module
   loads and refreshed when the server starts, so /health reports the version,
   the ISO 8601 start time, and the uptime of the running process
   (desc-8syr, desc-lqpr). *)

let wall_now_ms () = int_of_float (Unix.gettimeofday () *. 1000.)

let started_at_ms = Atomic.make (wall_now_ms ())
let mark_started () = Atomic.set started_at_ms (wall_now_ms ())

let iso8601_of_ms ms =
  let seconds = ms / 1000 in
  let millis = ms mod 1000 in
  let tm = Unix.gmtime (float_of_int seconds) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec millis

let uptime_seconds () =
  let elapsed = wall_now_ms () - Atomic.get started_at_ms in
  Float.round (float_of_int elapsed /. 1000. *. 1000.) /. 1000.

let store_error_message error = Format.asprintf "%a" Store.pp_error error

(* One identity body for /health, /healthz, and /ready: the daemon handshake
   reads pid and instanceId, an agent reads version, startedAt, and
   uptimeSeconds. *)
let health_fields config =
  let instance_id =
    match Atomic.get daemon_instance_id with
    | Some value -> [ ("instanceId", `String value) ]
    | None -> []
  in
  [
    ("ok", `Bool true);
    ("pid", `Int (Unix.getpid ()));
    ("stateDir", `String config.Config.state_dir);
    ("dbPath", `String config.db_path);
    ("baseUrl", `String config.base_url);
    ("version", `String Version.value);
    ("startedAt", `String (iso8601_of_ms (Atomic.get started_at_ms)));
    ("uptimeSeconds", `Float (uptime_seconds ()));
  ]
  @ instance_id

let health config = json_response (`Assoc (health_fields config))

(* Readiness is more than liveness: the store must answer (desc-dmuw). *)
let ready config store =
  let open Eta.Syntax in
  let* result =
    Eta.Effect.fold ~ok:(fun value -> Ok value)
      ~error:(fun error -> Error error)
      (Store.ping store)
  in
  match result with
  | Ok () ->
      Eta.Effect.pure
        (json_response
           (`Assoc
             (health_fields config
             @ [ ("ready", `Bool true); ("store", `String "ok") ])))
  | Error error ->
      Eta.Effect.pure
        (error_response_with_details 503 "not_ready"
           ("the store did not answer: " ^ store_error_message error)
           [ ("ready", `Bool false); ("store", `String "error") ])

(* The inventory and the OpenAPI document are rendered from the same
   declarations the router registers and the query parser validates against, so
   neither can drift from behavior (desc-de6o, desc-dmuw). *)
let endpoint_inventory = Endpoint.all

let endpoints config =
  json_response
    (`Assoc
      [
        ("baseUrl", `String config.Config.base_url);
        ("exporterUrl", `String (config.base_url ^ "/v1/traces"));
        ("logsExporterUrl", `String (config.base_url ^ "/v1/logs"));
        ("metricsExporterUrl", `String (config.base_url ^ "/v1/metrics"));
        ("databasePath", `String config.db_path);
        ( "aliasPolicy",
          `Assoc
            [
              ("prefix", `String Endpoint.alias_prefix);
              ("description", `String Endpoint.alias_description);
            ] );
        ("endpoints", `List (List.map Endpoint.inventory_json endpoint_inventory));
      ])

let markdown_headers =
  H.Core.Header.unsafe_of_list [ ("content-type", "text/markdown; charset=utf-8") ]

(* GET /docs and GET /docs/{name} serve the guides embedded at build time
   (desc-bqwh, desc-7wwz). *)
let docs_index () = json_response (Docs.index_json ())

let docs_get name =
  match Docs.find name with
  | Some guide -> S.Response.text ~headers:markdown_headers guide.Docs.content
  | None ->
      error_response_with_details 404 "doc_not_found"
        (Printf.sprintf "no guide named %s" name)
        [ ("available", `List (List.map (fun name -> `String name) Docs.names)) ]

let openapi config =
  json_response
    (Endpoint.document ~base_url:config.Config.base_url endpoint_inventory)

(* The setup text points at the guides and the OpenAPI document, so an agent
   that starts here finds the full documentation (desc-qv27). *)
let instructions config =
  let url = config.Config.base_url in
  text_response
    (Printf.sprintf
       {|Inn local OpenTelemetry collector

OTLP/HTTP traces:
  %s/v1/traces

OTLP/HTTP logs:
  %s/v1/logs

OTLP/HTTP metrics:
  %s/v1/metrics

Common environment:
  OTEL_EXPORTER_OTLP_ENDPOINT=%s
  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=%s/v1/traces
  OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=%s/v1/logs
  OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=%s/v1/metrics

Query API:
  %s/api/services
  %s/api/traces?service=<service>
  %s/api/traces/search?service=<service>&operation=<operation>&attr.<key>=<value>
  %s/api/logs/search?service=<service>&body=<text>
  %s/api/ai/calls?model=<model>&lookback=1h
  %s/api/facets?type=traces&field=attribute_keys

Documentation:
  %s/docs            guide index (name, title, path)
  %s/docs/debug      debugging workflow for agents
  %s/docs/effect     Effect app setup (OtlpTracer, OtlpLogger, OtlpMetrics)
  %s/docs/eta        Eta app setup (eta_otel)
  %s/openapi.json    OpenAPI 3.1: every parameter and response schema
  %s/endpoints       endpoint inventory
|}
       url url url url url url url url url url url url url url url url url url url)

let root_text config =
  text_response
    (Printf.sprintf
       "inn local telemetry server\n\nPOST /v1/traces\nPOST /v1/logs\nPOST /v1/metrics\nGET /health\nGET /healthz\nGET /ready\nGET /api/services\nGET /api/traces\nGET /api/traces/search\nGET /api/traces/stats\nGET /api/traces/<trace-id>\nGET /api/traces/<trace-id>/spans\nGET /api/traces/<trace-id>/logs\nGET /api/spans/search\nGET /api/spans/<span-id>\nGET /api/spans/<span-id>/logs\nGET /api/logs\nGET /api/logs/search\nGET /api/logs/stats\nGET /api/ai/calls\nGET /api/ai/calls/<span-id>\nGET /api/ai/stats\nGET /api/metrics\nGET /api/facets?type=logs&field=severity\nGET /api/stats\nGET /docs\nGET /docs/<name>\nGET /instructions\nGET /endpoints\nGET /openapi.json\n\nstate: %s\ndatabase: %s\n"
       config.Config.state_dir config.db_path)

let store_json eff encode =
  let open Eta.Syntax in
  let* result = Eta.Effect.fold ~ok:(fun value -> Ok value) ~error:(fun error -> Error error) eff in
  match result with
  | Ok value -> Eta.Effect.pure (json_response (encode value))
  | Error error ->
      Eta.Effect.pure
        (error_response 500 "store_error" (store_error_message error))

let add_response_header name value response =
  let headers = H.Core.Header.unsafe_add name value (S.Response.headers response) in
  S.Response.make ~headers ~status:(S.Response.status response)
    ~body:(S.Response.body response)
    ~trailers:(S.Response.trailers response)
    ()

let store_accepted rejected_field decoded eff =
  let open Eta.Syntax in
  let* result = Eta.Effect.fold ~ok:(fun value -> Ok value) ~error:(fun error -> Error error) eff in
  match result with
  | Ok _accepted -> Eta.Effect.pure (otlp_response rejected_field decoded)
  | Error error ->
      let response = otlp_error 503 14 (store_error_message error) in
      Eta.Effect.pure (add_response_header "retry-after" "1" response)

let param name params = List.assoc_opt name params

let with_query req f =
  let open Eta.Syntax in
  let* result = Eta.Effect.fold
      ~ok:(fun value -> Ok value)
      ~error:(fun error -> Error error)
      (Service.Extractors.Query.all req) in
  match result with
  | Ok params -> f params
  | Error { S.Error.kind = Bad_request { message }; _ } ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Error error -> Eta.Effect.fail error

let attr_prefix = "attr."

let attr_filters params =
  List.filter_map
    (fun (key, value) ->
      if String.starts_with ~prefix:attr_prefix key then
        let attr_key =
          String.sub key (String.length attr_prefix)
            (String.length key - String.length attr_prefix)
        in
        if String.equal attr_key "" then None else Some (attr_key, value)
      else None)
    params

let attr_contains_filters params =
  let prefix = "attrContains." in
  List.filter_map (fun (key, value) ->
    if String.starts_with ~prefix key then
      Some (String.sub key (String.length prefix)
        (String.length key - String.length prefix), value)
    else None) params

let valid_attr_contains params =
  let prefix = "attrContains." in
  if List.exists (fun (key, _) -> String.equal key prefix) params then
    Error "attrContains. requires an attribute key"
  else Ok (attr_contains_filters params)

let parse_min_duration params =
  match param "minDurationMs" params with
  | None -> Ok None
  | Some value ->
      (match float_of_string_opt value with
       | Some number when Float.is_finite number && number >= 0. ->
           Ok (Some number)
       | _ -> Error "minDurationMs must be a finite non-negative number")

let parse_min_severity params =
  match param "minSeverity" params with
  | None -> Ok None
  | Some value ->
      match String.lowercase_ascii value with
      | "trace" -> Ok (Some 1)
      | "debug" -> Ok (Some 5)
      | "info" -> Ok (Some 9)
      | "warn" -> Ok (Some 13)
      | "error" -> Ok (Some 17)
      | "fatal" -> Ok (Some 21)
      | _ ->
          Error
            (Endpoint.allowed_values "minSeverity" Endpoint.severity_levels)

let with_search_filters ?(duration = false) ?(severity = false)
    ?(contains = false) params f =
  let durations = if duration then parse_min_duration params else Ok None in
  let severities = if severity then parse_min_severity params else Ok None in
  let attrs = if contains then valid_attr_contains params else Ok [] in
  match durations, severities, attrs with
  | Ok min_duration_ms, Ok min_severity, Ok attr_contains ->
      f min_duration_ms min_severity attr_contains
  | Error message, _, _ | _, Error message, _ | _, _, Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)

let json_list name encode values =
  `Assoc [ (name, `List (List.map encode values)) ]

let rec take count values =
  if count <= 0 then []
  else
    match values with
    | [] -> []
    | value :: rest -> value :: take (count - 1) rest

(* A list or search response keeps its named collection key and adds the
   sibling meta object; [nextCursor] is present only when another page exists
   (win-fl8w, win-7xet). *)
let page_json name encode (policy : List_policy.request) (page : _ Store.page) =
  let returned = List.length page.items in
  `Assoc
    [
      (name, `List (List.map encode page.items));
      ( "meta",
        List_policy.meta_json policy ~returned
          ~truncated:(Option.is_some page.next) ~next:page.next );
    ]

let summary_json name encode (policy : List_policy.request) values =
  `Assoc
    [
      (name, `List (List.map encode values));
      ( "meta",
        List_policy.stats_meta ~lookback:policy.List_policy.lookback
          ~limit:policy.limit );
    ]

let ingest req rejected_field decode ingest =
  let open Eta.Syntax in
  let content_type = Service.Req.header req "content-type" in
  match content_type with
  | Some value when not (String.equal
       (String.lowercase_ascii (String.trim (List.hd (String.split_on_char ';' value))))
       "application/json") ->
      Eta.Effect.pure (otlp_error 415 3 "only OTLP JSON (application/json) is supported")
  | _ ->
      let* body_result = Eta.Effect.fold
        ~ok:(fun value -> Ok value) ~error:(fun error -> Error error)
        (Service.Extractors.body_text ~max_bytes:max_body_bytes req) in
      match body_result with
      | Error { S.Error.kind = Request_body_too_large _; _ } ->
          Eta.Effect.pure (otlp_error 413 8 "OTLP JSON body is too large")
      | Error error -> Eta.Effect.fail error
      | Ok body -> match decode (if String.trim body = "" then "{}" else body) with
          | Error message -> Eta.Effect.pure (otlp_error 400 3 message)
          | Ok decoded -> store_accepted rejected_field decoded (ingest decoded.items)

let services store req =
  with_query req @@ fun params ->
  match List_policy.resolve_lookback ~now_ms:(Store.now_ms store) params with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok (window, lookback) ->
      let signal = param "signal" params in
      match signal with
      | Some value when not (List.mem value Endpoint.service_signals) ->
          Eta.Effect.pure
            (error_response 400 "invalid_query"
               (Endpoint.allowed_values "signal" Endpoint.service_signals))
      | _ ->
          store_json (Store.list_services ~window
        ~include_metrics:(signal = Some "metrics") store) (fun services ->
          `Assoc
            [
              ("services", `List (List.map (fun service -> `String service) services));
              ( "meta",
                List_policy.services_meta ~lookback
                  ~returned:(List.length services) );
            ])

let traces store req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Trace
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok policy ->
      store_json
        (Store.list_trace_summaries ?service:(param "service" params)
           ~window:policy.List_policy.window ?cursor:policy.cursor
           ~limit:policy.limit store)
        (page_json "traces" Model.trace_summary_to_json policy)

let trace store trace_id _req =
  let open Eta.Syntax in
  let* result = Eta.Effect.fold
      ~ok:(fun value -> Ok value)
      ~error:(fun error -> Error error)
      (Store.get_trace store trace_id) in
  match result with
  | Error error ->
      Eta.Effect.pure
        (error_response 500 "store_error" (store_error_message error))
  | Ok None ->
      Eta.Effect.pure
        (error_response 404 "trace_not_found" "trace was not found")
  | Ok (Some trace) -> Eta.Effect.pure (json_response (Model.trace_to_json trace))

let span store span_id _req =
  let open Eta.Syntax in
  let* result = Eta.Effect.fold
      ~ok:(fun value -> Ok value)
      ~error:(fun error -> Error error)
      (Store.get_span_node store span_id) in
  match result with
  | Error error ->
      Eta.Effect.pure
        (error_response 500 "store_error" (store_error_message error))
  | Ok None ->
      Eta.Effect.pure (error_response 404 "span_not_found" "span was not found")
  | Ok (Some node) ->
      Eta.Effect.pure (json_response (Model.span_node_to_json node))

let trace_spans store trace_id req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Span
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok policy ->
      store_json
        (Store.list_trace_spans store ~window:policy.List_policy.window
           ?cursor:policy.cursor ~limit:policy.limit trace_id)
        (page_json "spans" Model.span_node_to_json policy)

let trace_logs store trace_id req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Log
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok policy ->
      with_search_filters ~contains:true params @@ fun _ _ attr_contains ->
      let filter : Store.log_search_filter = {
        service = None; trace_id = Some trace_id; span_id = None;
        severity = None; body = None; attrs = attr_filters params;
        window = policy.window; cursor = policy.cursor; limit = policy.limit;
      } in
      store_json (Store.search_logs ~attr_contains filter store)
        (page_json "logs" Model.log_to_json policy)

let span_logs store span_id req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Log
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok policy ->
      with_search_filters ~contains:true params @@ fun _ _ attr_contains ->
      let filter : Store.log_search_filter = {
        service = None; trace_id = None; span_id = Some span_id;
        severity = None; body = None; attrs = attr_filters params;
        window = policy.window; cursor = policy.cursor; limit = policy.limit;
      } in
      store_json (Store.search_logs ~attr_contains filter store)
        (page_json "logs" Model.log_to_json policy)

(* AI calls -------------------------------------------------------------- *)

(* Every filter the AI call spec defines, resolved for the store: the HTTP
   layer parses, the store only queries (aic-yfcd). The attribute key table
   behind the stored summary lives in [Ai] and the README. *)
let ai_span_filter params policy cursor limit : Store.ai_call_filter =
  {
    Store.service = param "service" params;
    trace_id = param "traceId" params;
    operation = param "operation" params;
    status = param "status" params;
    provider = param "provider" params;
    model = param "model" params;
    session_id = param "sessionId" params;
    function_id = param "functionId" params;
    finish_reason = param "finishReason" params;
    text = param "text" params;
    attrs = attr_filters params;
    window = policy.List_policy.window;
    cursor;
    limit;
  }

(* AI calls only, from the AI call table that ingest maintains; paging never
   scans unrelated spans (acc-gkoz). *)
let ai_calls store req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Ai_call
      ~now_ms:(Store.now_ms store) params
  with
  | Error message -> Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok policy ->
      with_search_filters ~duration:true ~contains:true params @@
      fun min_duration_ms _ attr_contains ->
      store_json
        (Store.search_ai_calls ~attr_contains ?min_duration_ms
           (ai_span_filter params policy policy.cursor policy.limit) store)
        (page_json "calls" Model.ai_call_to_json policy)

(* The hint is best-effort: a store failure while looking up the parent must
   not turn the 404 into a 500. *)
let optional_store eff =
  Eta.Effect.fold ~ok:(fun value -> Ok value) ~error:(fun _ -> Error ()) eff
  |> Eta.Effect.map (function Ok value -> value | Error () -> None)

let ai_call_hint store kind (span : Model.span) =
  let open Eta.Syntax in
  let* parent =
    match span.Model.parent_span_id with
    | None -> Eta.Effect.pure None
    | Some parent_id -> optional_store (Store.get_span store parent_id)
  in
  let* parent_is_call =
    match parent with
    | None -> Eta.Effect.pure false
    | Some (parent : Model.span) ->
        optional_store (Store.span_ai_kind store parent.Model.span_id)
        |> Eta.Effect.map (fun parent_kind -> parent_kind = Some "call")
  in
  let label =
    match kind with
    | "tool" -> "a tool call"
    | "nested" -> "a nested provider span"
    | _ -> "not an AI call"
  in
  let parent_call =
    match parent with
    | Some (parent : Model.span) when parent_is_call -> Some parent
    | _ -> None
  in
  Eta.Effect.pure
    [
      ("kind", `String kind);
      ( "aiCallSpanId",
        match parent_call with
        | Some (parent : Model.span) -> `String parent.span_id
        | None -> `Null );
      ( "aiCallOperationName",
        match parent_call with
        | Some (parent : Model.span) -> `String parent.operation_name
        | None -> `Null );
      ( "hint",
        match parent_call with
        | Some (parent : Model.span) ->
            `String
              (Printf.sprintf
                 "this span is %s; read its AI call with GET /ai/calls/%s" label
                 parent.span_id)
        | None ->
            `String
              (Printf.sprintf
                 "this span is %s; no stored AI call parent was found" label) );
    ]

let ai_call_detail_json config (detail : Model.ai_call_detail) span logs =
  let links =
    [
      ( "trace",
        `String
          (config.Config.base_url ^ "/traces/" ^ detail.Model.call.trace_id) );
      ( "traceSpans",
        `String
          (config.Config.base_url ^ "/traces/" ^ detail.Model.call.trace_id
         ^ "/spans") );
    ]
  in
  match Model.ai_call_detail_to_json detail with
  | `Assoc fields ->
      `Assoc
        (fields
        @ [
            ("span", Model.span_to_json span);
            ("logs", `List (List.map Model.log_to_json logs));
            ("links", `Assoc links);
          ])
  | json -> json

(* The detail classifies from the stored kind, not from the span alone: a
   nested provider span's parent is outside the span (aic-t8tl). *)
let ai_call config store span_id _req =
  let open Eta.Syntax in
  let* kind_result =
    Eta.Effect.fold ~ok:(fun value -> Ok value)
      ~error:(fun error -> Error error)
      (Store.span_ai_kind store span_id)
  in
  match kind_result with
  | Error error ->
      Eta.Effect.pure
        (error_response 500 "store_error" (store_error_message error))
  | Ok None ->
      Eta.Effect.pure
        (error_response 404 "ai_call_not_found"
           ("AI call was not found for span " ^ span_id))
  | Ok (Some kind) when not (String.equal kind "call") ->
      let* span_result =
        Eta.Effect.fold ~ok:(fun value -> Ok value)
          ~error:(fun error -> Error error)
          (Store.get_span store span_id)
      in
      (match span_result with
      | Error error ->
          Eta.Effect.pure
            (error_response 500 "store_error" (store_error_message error))
      | Ok None ->
          Eta.Effect.pure
            (error_response 404 "ai_call_not_found"
               ("AI call was not found for span " ^ span_id))
      | Ok (Some span) ->
          let* details = ai_call_hint store kind span in
          Eta.Effect.pure
            (error_response_with_details 404 "ai_call_not_found"
               ("span " ^ span_id ^ " is not an AI call")
               details))
  | Ok (Some _) ->
      let* span_result =
        Eta.Effect.fold ~ok:(fun value -> Ok value)
          ~error:(fun error -> Error error)
          (Store.get_span store span_id)
      in
      (match span_result with
      | Error error ->
          Eta.Effect.pure
            (error_response 500 "store_error" (store_error_message error))
      | Ok None ->
          Eta.Effect.pure
            (error_response 404 "ai_call_not_found"
               ("AI call was not found for span " ^ span_id))
      | Ok (Some span) -> (
          let* children_result =
            Eta.Effect.fold ~ok:(fun value -> Ok value)
              ~error:(fun error -> Error error)
              (Store.list_span_children store span.Model.span_id)
          in
          match children_result with
          | Error error ->
              Eta.Effect.pure
                (error_response 500 "store_error" (store_error_message error))
          | Ok children -> (
              let* logs_result =
                Eta.Effect.fold ~ok:(fun value -> Ok value)
                  ~error:(fun error -> Error error)
                  (Store.list_span_logs store ~window:Model.window_all
                     ~limit:10_000 span.Model.span_id)
              in
              match logs_result with
              | Error error ->
                  Eta.Effect.pure
                    (error_response 500 "store_error"
                       (store_error_message error))
              | Ok logs ->
                  let detail = Ai.detail_of_span ~children span in
                  Eta.Effect.pure
                    (json_response
                       (ai_call_detail_json config detail span
                          logs.Store.items)))))

(* Every group and aggregate runs in SQL over the whole window; an unknown
   groupBy or agg is rejected with the allowed values (aic-qpv6, aic-e67r). *)
let ai_stats store req =
  with_query req @@ fun params ->
  match
    ( param "groupBy" params,
      param "agg" params,
      List_policy.summary_request ~now_ms:(Store.now_ms store) params )
  with
  | None, _, _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query" "groupBy is required")
  | _, None, _ ->
      Eta.Effect.pure (error_response 400 "invalid_query" "agg is required")
  | _, _, Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Some group_by, Some _, Ok _ when not (List.mem group_by Endpoint.ai_group_by)
    ->
      Eta.Effect.pure
        (error_response 400 "invalid_query"
           (Endpoint.allowed_values "groupBy" Endpoint.ai_group_by))
  | Some _, Some agg, Ok _ when not (List.mem agg Endpoint.ai_agg) ->
      Eta.Effect.pure
        (error_response 400 "invalid_query" (Endpoint.allowed_values "agg" Endpoint.ai_agg))
  | Some group_by, Some agg, Ok policy ->
      with_search_filters ~duration:true ~contains:true params @@
      fun min_duration_ms _ attr_contains ->
      store_json
        (Store.ai_stats ~attr_contains ?min_duration_ms ~group_by ~agg
           (ai_span_filter params policy None policy.limit) store)
        (fun stats ->
          `Assoc
            [
              ("stats", `List (List.map Model.stat_item_to_json stats));
              ( "meta",
                List_policy.stats_meta ~lookback:policy.lookback
                  ~limit:policy.limit );
            ])

let search_spans store req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Span
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok policy ->
      with_search_filters ~duration:true ~contains:true params @@
      fun min_duration_ms _ attr_contains ->
      let filter =
        {
          Store.service = param "service" params;
          trace_id = param "traceId" params;
          operation = param "operation" params;
          parent_operation = param "parentOperation" params;
          status = param "status" params;
          attrs = attr_filters params;
          window = policy.List_policy.window;
          cursor = policy.cursor;
          limit = policy.limit;
        }
      in
      store_json (Store.search_spans ~attr_contains ?min_duration_ms filter store)
        (page_json "spans" Model.span_to_json policy)

let search_traces store req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Trace
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok policy ->
      with_search_filters ~duration:true ~contains:true params @@
      fun min_duration_ms _ attr_contains ->
      let filter =
        {
          Store.service = param "service" params;
          operation = param "operation" params;
          status = param "status" params;
          attrs = attr_filters params;
          window = policy.List_policy.window;
          cursor = policy.cursor;
          limit = policy.limit;
        }
      in
      store_json (Store.search_traces ~attr_contains ?min_duration_ms
        ?text:(param "text" params) filter store)
        (page_json "traces" Model.trace_summary_to_json policy)

let trace_stats store req =
  with_query req @@ fun params ->
  match
    ( param "groupBy" params,
      param "agg" params,
      List_policy.summary_request ~now_ms:(Store.now_ms store) params )
  with
  | None, _, _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query" "groupBy is required")
  | _, None, _ ->
      Eta.Effect.pure (error_response 400 "invalid_query" "agg is required")
  | _, _, Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Some group_by, Some agg, Ok policy when List.mem agg Endpoint.trace_agg ->
      with_search_filters ~duration:true ~contains:true params @@
      fun min_duration_ms _ attr_contains ->
      let filter =
        {
          Store.group_by;
          agg;
          service = param "service" params;
          operation = param "operation" params;
          status = param "status" params;
          attrs = attr_filters params;
          window = policy.List_policy.window;
          limit = policy.limit;
        }
      in
      store_json (Store.trace_stats ~attr_contains ?min_duration_ms filter store)
        (summary_json "stats" Model.stat_item_to_json policy)
  | _, Some _, Ok _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query"
           (Endpoint.allowed_values "agg" Endpoint.trace_agg))

let logs store req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Log
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok policy ->
      with_search_filters ~severity:true ~contains:true params @@
      fun _ min_severity attr_contains ->
      let filter : Store.log_search_filter = {
        service = param "service" params;
        trace_id = None; span_id = None;
        severity = param "severity" params;
        body = param "contains" params; attrs = attr_filters params;
        window = policy.window; cursor = policy.cursor; limit = policy.limit;
      } in
      store_json (Store.search_logs ~attr_contains ?min_severity filter store)
        (page_json "logs" Model.log_to_json policy)

let search_logs store req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Log
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok policy ->
      with_search_filters ~severity:true ~contains:true params @@
      fun _ min_severity attr_contains ->
      let body =
        match param "body" params with
        | Some _ as value -> value
        | None -> param "contains" params
      in
      let filter =
        {
          Store.service = param "service" params;
          trace_id = param "traceId" params;
          span_id = param "spanId" params;
          severity = param "severity" params;
          body;
          attrs = attr_filters params;
          window = policy.List_policy.window;
          cursor = policy.cursor;
          limit = policy.limit;
        }
      in
      store_json (Store.search_logs ~attr_contains ?min_severity filter store)
        (page_json "logs" Model.log_to_json policy)

let log_stats store req =
  with_query req @@ fun params ->
  match
    ( param "groupBy" params,
      param "agg" params,
      List_policy.summary_request ~now_ms:(Store.now_ms store) params )
  with
  | None, _, _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query" "groupBy is required")
  | _, Some agg, _ when not (List.mem agg Endpoint.log_agg) ->
      Eta.Effect.pure
        (error_response 400 "invalid_query"
           (Endpoint.allowed_values "agg" Endpoint.log_agg))
  | _, _, Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Some group_by, _, Ok policy ->
      with_search_filters ~severity:true ~contains:true params @@
      fun _ min_severity attr_contains ->
      let body =
        match param "body" params with
        | Some _ as value -> value
        | None -> param "contains" params
      in
      let filter =
        {
          Store.group_by;
          service = param "service" params;
          trace_id = param "traceId" params;
          span_id = param "spanId" params;
          severity = param "severity" params;
          body;
          attrs = attr_filters params;
          window = policy.List_policy.window;
          limit = policy.limit;
        }
      in
      store_json (Store.log_stats ~attr_contains ?min_severity filter store)
        (summary_json "stats" Model.stat_item_to_json policy)

let facets store req =
  with_query req @@ fun params ->
  match
    ( param "type" params,
      param "field" params,
      List_policy.summary_request ~now_ms:(Store.now_ms store) params )
  with
  | None, _, _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query" "type is required")
  | _, None, _ ->
      Eta.Effect.pure (error_response 400 "invalid_query" "field is required")
  | _, _, Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Some kind, Some field, Ok policy
    when String.equal kind "traces" || String.equal kind "logs" ->
      let filter =
        {
          Store.kind;
          field;
          key = param "key" params;
          service = param "service" params;
          window = policy.List_policy.window;
          limit = policy.limit;
        }
      in
      store_json (Store.facets filter store)
        (summary_json "facets" Model.facet_item_to_json policy)
  | Some _, Some _, Ok _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query"
           (Endpoint.allowed_values "type" Endpoint.facet_types))

let metrics store req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Metric
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok policy ->
      let filter =
        {
          Store.service = param "service" params;
          name = param "name" params;
          window = policy.List_policy.window;
          cursor = policy.cursor;
          limit = policy.limit;
        }
      in
      store_json (Store.list_metric_points filter store)
        (page_json "metrics" Model.metric_point_to_json policy)

let stats store req =
  with_query req @@ fun params ->
  match List_policy.resolve_lookback ~now_ms:(Store.now_ms store) params with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok (window, lookback) ->
      store_json (Store.stats ~window store) (fun stats ->
          match Model.stats_to_json stats with
          | `Assoc fields ->
              `Assoc
                (fields
                @ [ ("meta", List_policy.store_stats_meta ~lookback) ])
          | json -> json)

let method_not_allowed_handler ~allowed _request =
  method_not_allowed ()
  |> add_response_header "allow" (String.concat ", " allowed)
  |> Eta.Effect.pure

let not_found_handler _request = Eta.Effect.pure (not_found ())

let with_route_param name f req =
  let open Eta.Syntax in
  let* value = Service.Extractors.Param.string name req in
  f value req

(* Every route comes from one declaration, and only the declared query
   parameters reach a handler, so the router topology, the inventory, and the
   OpenAPI document are the same list (desc-de6o, desc-dmuw). *)
let declared ~decl route req =
  let open Eta.Syntax in
  let* result =
    Eta.Effect.fold ~ok:(fun value -> Ok value)
      ~error:(fun error -> Error error)
      (Service.Extractors.Query.all req)
  in
  match result with
  | Ok params -> (
      match Endpoint.validate_query decl params with
      | Error message ->
          Eta.Effect.pure (error_response 400 "invalid_query" message)
      | Ok () -> route req)
  | Error { S.Error.kind = Bad_request { message }; _ } ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Error error -> Eta.Effect.fail error

let route_for config store (endpoint : Endpoint.t) =
  match endpoint.Endpoint.id with
  | "root" -> fun _req -> Eta.Effect.pure (root_text config)
  | "health" | "healthz" -> fun _req -> Eta.Effect.pure (health config)
  | "ready" -> fun _req -> ready config store
  | "instructions" -> fun _req -> Eta.Effect.pure (instructions config)
  | "endpoints" -> fun _req -> Eta.Effect.pure (endpoints config)
  | "openapi" -> fun _req -> Eta.Effect.pure (openapi config)
  | "docs_index" -> fun _req -> Eta.Effect.pure (docs_index ())
  | "docs_get" ->
      with_route_param "name" (fun name _req ->
          Eta.Effect.pure (docs_get name))
  | "ingest_traces" ->
      fun req ->
        ingest req "rejectedSpans" Otlp.decode_traces_json
          (Store.ingest_traces store)
  | "ingest_logs" ->
      fun req ->
        ingest req "rejectedLogRecords" Otlp.decode_logs_json
          (Store.ingest_logs store)
  | "ingest_metrics" ->
      fun req ->
        ingest req "rejectedDataPoints" Otlp.decode_metrics_json
          (Store.ingest_metrics store)
  | "services" -> services store
  | "traces" -> traces store
  | "trace_search" -> search_traces store
  | "trace_stats" -> trace_stats store
  | "trace_spans" -> with_route_param "traceId" (trace_spans store)
  | "trace_logs" -> with_route_param "traceId" (trace_logs store)
  | "trace" -> with_route_param "traceId" (trace store)
  | "span_search" -> search_spans store
  | "span" -> with_route_param "spanId" (span store)
  | "span_logs" -> with_route_param "spanId" (span_logs store)
  | "logs" -> logs store
  | "log_search" -> search_logs store
  | "log_stats" -> log_stats store
  | "ai_calls" -> ai_calls store
  | "ai_call" -> with_route_param "spanId" (ai_call config store)
  | "ai_stats" -> ai_stats store
  | "metrics" -> metrics store
  | "facets" -> facets store
  | "stats" -> stats store
  | id ->
      fun _req ->
        Eta.Effect.pure
          (error_response 500 "undeclared_endpoint"
             ("no handler is registered for endpoint " ^ id))

let add_declaration router config store endpoint =
  let methods = [ Endpoint.method_to_string endpoint.Endpoint.method_ ] in
  let route = declared ~decl:endpoint (route_for config store endpoint) in
  Service.Router.add_exn router ~methods endpoint.Endpoint.path route;
  let aliases =
    if String.equal endpoint.Endpoint.path "/" then
      [ Endpoint.alias_path endpoint; "/api/" ]
    else [ Endpoint.alias_path endpoint ]
  in
  List.iter
    (fun alias -> Service.Router.add_exn router ~methods alias route)
    aliases

let handler config store =
  let router = Service.Router.create () in
  List.iter (add_declaration router config store) Endpoint.all;
  Service.Router.compile ~not_found:not_found_handler
    ~method_not_allowed:method_not_allowed_handler router

let run_store_effect ~sw ~clock eff =
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith (Format.asprintf "%a" (Eta.Cause.pp Store.pp_error) cause)

let unix_addr host port =
  let ip =
    match host with
    | "localhost" | "127.0.0.1" -> Unix.inet_addr_loopback
    | "::1" -> Unix.inet6_addr_loopback
    | "0.0.0.0" -> Unix.inet_addr_any
    | "::" -> Unix.inet6_addr_any
    | host -> Unix.inet_addr_of_string host
  in
  Unix.ADDR_INET (ip, port)

let socket_domain host =
  if String.contains host ':' then Unix.PF_INET6 else Unix.PF_INET

let check_bind_available config =
  let fd = Unix.socket (socket_domain config.Config.host) Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      Unix.bind fd (unix_addr config.host config.port);
      Unix.listen fd 1)

let prune_interval config =
  Eta.Duration.seconds config.Config.prune_interval_seconds

let report_prune (report : Model.prune_report) =
  let deleted =
    report.traces + report.spans + report.logs + report.metric_points
  in
  if deleted > 0 then
    prerr_endline
      (Printf.sprintf
         "inn pruner: deleted %d traces, %d spans, %d logs, and %d metric points%s"
         report.traces report.spans report.logs report.metric_points
         (if report.size_cap_triggered then " (size cap)" else ""))

let report_prune_failure error =
  prerr_endline (Format.asprintf "inn pruner: %a" Store.pp_error error)

(* One prune pass at startup, then one pass per interval. The pruner never
   fails the server: a failed pass is reported and retried on the next interval
   (ret-sj15, ret-sbgj). *)
let pruner_loop ~config store =
  let open Eta.Syntax in
  let rec loop () =
    let* outcome =
      Store.prune store
      |> Eta.Effect.fold ~ok:(fun report -> Ok report) ~error:(fun error ->
             Error error)
    in
    let* () =
      match outcome with
      | Ok report -> Eta.Effect.sync (fun () -> report_prune report)
      | Error error -> Eta.Effect.sync (fun () -> report_prune_failure error)
    in
    let* () = Eta.Effect.sleep (prune_interval config) in
    loop ()
  in
  loop ()

let start_pruner ~sw ~clock ~config store =
  Eio.Fiber.fork ~sw (fun () ->
      let rt = Eta_eio.Runtime.create ~sw ~clock () in
      match Eta.Runtime.run rt (pruner_loop ~config store) with
      | Eta.Exit.Ok () -> ()
      | Eta.Exit.Error cause ->
          if not (Eta.Cause.is_interrupt_only cause) then
            prerr_endline
              (Format.asprintf "inn pruner stopped: %a"
                 (Eta.Cause.pp Store.pp_error) cause))

(* Shutdown runs on a cancelled switch, so the close effect is expected to be
   interrupted; only a real failure is reported. *)
let close_store ~sw ~clock store =
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  match Eta.Runtime.run rt (Store.close store) with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error cause ->
      if not (Eta.Cause.is_interrupt_only cause) then
        prerr_endline
          (Format.asprintf "inn: closing the store failed: %a"
             (Eta.Cause.pp Store.pp_error) cause)

let run ~sw ~env config =
  check_bind_available config;
  mark_started ();
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let store = run_store_effect ~sw ~clock (Store.open_ config) in
  Fun.protect
    ~finally:(fun () -> close_store ~sw ~clock store)
    (fun () ->
      (* The pruner runs under its own switch, so it is cancelled and awaited
         before the store it uses is closed. *)
      Eio.Switch.run (fun pruner_sw ->
          start_pruner ~sw:pruner_sw ~clock ~config store;
          let addr = Serve.tcp_addr ~host:config.Config.host ~port:config.port in
          prerr_endline
            (Printf.sprintf "inn server listening on http://%s:%d" config.host
               config.port);
          Serve.h1 ~sw ~net ~clock ~addr (handler config store)))
