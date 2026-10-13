module H = Ox_http
module S = Ox_http.Server
module Service = Ox_http.Service
module Serve = Ox_http.Service.Serve

let max_body_bytes = 32 * 1024 * 1024

(* An OTLP exporter batch of 512 spans with large attributes is several
   megabytes before Inn cuts its values; Ox's default 1 MiB request limit would
   reset those connections, so the server accepts what the body extractor
   accepts. *)
let server_config =
  { S.Config.default with max_request_body_bytes = max_body_bytes }

let text_headers =
  H.Header.unsafe_of_list [ ("content-type", "text/plain; charset=utf-8") ]

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

(* An error with extra fields, such as the guide names that a 404 lists. *)
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

let wall_clock = ref (fun () -> 0)
let wall_now_ms () = !wall_clock ()

let install_clock ~caps =
  wall_clock :=
    fun () ->
      int_of_float (Ox_caps.Cap_unix.gettimeofday ~caps () *. 1000.)

let started_at_ms = Atomic.make 0
let draining = Atomic.make false
let mark_started ~caps () =
  install_clock ~caps;
  Atomic.set started_at_ms (wall_now_ms ());
  Atomic.set draining false

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

(* One identity body for /health, /healthz, and /ready: an agent reads pid,
   version, startedAt, and uptimeSeconds. *)
let health_fields config =
  [
    ("ok", `Bool true);
    ("pid", `Int (Unix.getpid ()));
    ("stateDir", `String config.Config.state_dir);
    ("dataDir", `String config.data_dir);
    ("baseUrl", `String config.base_url);
    ("version", `String Version.value);
    ("startedAt", `String (iso8601_of_ms (Atomic.get started_at_ms)));
    ("uptimeSeconds", `Float (uptime_seconds ()));
  ]

let health config = json_response (`Assoc (health_fields config))

(* Inn owns /ready (and /api/ready): retain the JSON identity and store check,
   and report draining before Ox closes the listener (desc-dmuw, svc-pehm). *)
let draining_response () =
  error_response_with_details 503 "not_ready" "server is draining"
    [ ("ready", `Bool false); ("store", `String "draining") ]

let ready config store =
  if Atomic.get draining then Ok (draining_response ())
  else
    match Store.ping store with
    | Ok () when Atomic.get draining -> Ok (draining_response ())
    | Ok () ->
        Ok (json_response
              (`Assoc
                (health_fields config
                @ [ ("ready", `Bool true); ("store", `String "ok") ])))
    | Error error ->
        Ok (error_response_with_details 503 "not_ready"
              ("the store did not answer: " ^ store_error_message error)
              [ ("ready", `Bool false); ("store", `String "error") ])

(* GET /status: the identity and the store state without counting rows, so
   it stays cheap at any size (bcache-s7at). *)
let status config store =
  match Store.storage store with
  | Ok storage ->
      json_response
        (`Assoc
          (health_fields config
          @ [ ("storage", Model.storage_stats_to_json storage) ]))
  | Error error ->
      error_response 500 "store_error" (store_error_message error)

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
        ("dataDir", `String config.data_dir);
        ( "aliasPolicy",
          `Assoc
            [
              ("prefix", `String Endpoint.alias_prefix);
              ("description", `String Endpoint.alias_description);
            ] );
        ("endpoints", `List (List.map Endpoint.inventory_json endpoint_inventory));
      ])

let markdown_headers =
  H.Header.unsafe_of_list [ ("content-type", "text/markdown; charset=utf-8") ]

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
  %s/api/facets?type=traces&field=attribute_keys

Documentation:
  %s/docs            guide index (name, title, path)
  %s/docs/debug      debugging workflow for agents
  %s/docs/effect     Effect app setup (OtlpTracer, OtlpLogger, OtlpMetrics)
  %s/docs/ox        Ox app setup (ox_otel)
  %s/openapi.json    OpenAPI 3.1: every parameter and response schema
  %s/endpoints       endpoint inventory
|}
       url url url url url url url url url url url url url url url url url url)

let root_text config =
  text_response
    (Printf.sprintf
       "inn local telemetry server\n\nPOST /v1/traces\nPOST /v1/logs\nPOST /v1/metrics\nGET /health\nGET /healthz\nGET /ready\nGET /status\nGET /api/services\nGET /api/traces\nGET /api/traces/search\nGET /api/traces/stats\nGET /api/traces/<trace-id>\nGET /api/traces/<trace-id>/spans\nGET /api/traces/<trace-id>/logs\nGET /api/spans/search\nGET /api/spans/<span-id>\nGET /api/spans/<span-id>/logs\nGET /api/logs\nGET /api/logs/search\nGET /api/logs/stats\nGET /api/metrics\nGET /api/facets?type=logs&field=severity\nGET /api/stats\nGET /docs\nGET /docs/<name>\nGET /instructions\nGET /endpoints\nGET /openapi.json\n\nstate: %s\ndata: %s\n"
       config.Config.state_dir config.data_dir)

let store_json result encode =
  match result with
  | Ok value -> Ok (json_response (encode value))
  | Error error ->
      Ok (error_response 500 "store_error" (store_error_message error))

let add_response_header name value response =
  let headers = H.Header.unsafe_add name value (S.Response.headers response) in
  S.Response.make ~headers ~status:(S.Response.status response)
    ~body:(S.Response.body response)
    ~trailers:(S.Response.trailers response)
    ()

let store_accepted rejected_field decoded result =
  match result with
  | Ok _accepted -> Ok (otlp_response rejected_field decoded)
  | Error error ->
      let response = otlp_error 503 14 (store_error_message error) in
      Ok (add_response_header "retry-after" "1" response)

let param name params = List.assoc_opt name params

let with_query req f =
  match Service.Extractors.Query.all req with
  | Ok params -> f params
  | Error { S.Error.kind = Bad_request { message }; _ } ->
      Ok (error_response 400 "invalid_query" message)
  | Error error -> Error error

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
      Ok (error_response 400 "invalid_query" message)

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
  let content_type = Service.Req.header req "content-type" in
  match content_type with
  | Some value when not (String.equal
       (String.lowercase_ascii (String.trim (List.hd (String.split_on_char ';' value))))
       "application/json") ->
      Ok (otlp_error 415 3 "only OTLP JSON (application/json) is supported")
  | _ ->
      let body_result = Service.Extractors.body_text ~max_bytes:max_body_bytes req in
      match body_result with
      | Error { S.Error.kind = Request_body_too_large _; _ } ->
          Ok (otlp_error 413 8 "OTLP JSON body is too large")
      | Error error -> Error error
      | Ok body -> match decode (if String.trim body = "" then "{}" else body) with
          | Error message -> Ok (otlp_error 400 3 message)
          | Ok decoded -> store_accepted rejected_field decoded (ingest decoded.items)

let services store req =
  with_query req @@ fun params ->
  match List_policy.resolve_lookback ~now_ms:(Store.now_ms store) params with
  | Error message ->
      Ok (error_response 400 "invalid_query" message)
  | Ok (window, lookback) ->
      let signal = param "signal" params in
      match signal with
      | Some value when not (List.mem value Endpoint.service_signals) ->
          Ok
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
      Ok (error_response 400 "invalid_query" message)
  | Ok policy ->
      store_json
        (Store.list_trace_summaries ?service:(param "service" params)
           ~window:policy.List_policy.window ?cursor:policy.cursor
           ~limit:policy.limit store)
        (page_json "traces" Model.trace_summary_to_json policy)

let trace store trace_id _req =
  let result = (Store.get_trace store trace_id) in
  match result with
  | Error error ->
      Ok
        (error_response 500 "store_error" (store_error_message error))
  | Ok None ->
      Ok
        (error_response 404 "trace_not_found" "trace was not found")
  | Ok (Some trace) -> Ok (json_response (Model.trace_to_json trace))

let span store span_id _req =
  let result = (Store.get_span_node store span_id) in
  match result with
  | Error error ->
      Ok
        (error_response 500 "store_error" (store_error_message error))
  | Ok None ->
      Ok (error_response 404 "span_not_found" "span was not found")
  | Ok (Some node) ->
      Ok (json_response (Model.span_node_to_json node))

let trace_spans store trace_id req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Span
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Ok (error_response 400 "invalid_query" message)
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
      Ok (error_response 400 "invalid_query" message)
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
      Ok (error_response 400 "invalid_query" message)
  | Ok policy ->
      with_search_filters ~contains:true params @@ fun _ _ attr_contains ->
      let filter : Store.log_search_filter = {
        service = None; trace_id = None; span_id = Some span_id;
        severity = None; body = None; attrs = attr_filters params;
        window = policy.window; cursor = policy.cursor; limit = policy.limit;
      } in
      store_json (Store.search_logs ~attr_contains filter store)
        (page_json "logs" Model.log_to_json policy)

let search_spans store req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Span
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Ok (error_response 400 "invalid_query" message)
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
      Ok (error_response 400 "invalid_query" message)
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
      store_json (Store.search_traces ~attr_contains ?min_duration_ms filter store)
        (page_json "traces" Model.trace_summary_to_json policy)

let trace_stats store req =
  with_query req @@ fun params ->
  match
    ( param "groupBy" params,
      param "agg" params,
      List_policy.summary_request ~now_ms:(Store.now_ms store) params )
  with
  | None, _, _ ->
      Ok
        (error_response 400 "invalid_query" "groupBy is required")
  | _, None, _ ->
      Ok (error_response 400 "invalid_query" "agg is required")
  | _, _, Error message ->
      Ok (error_response 400 "invalid_query" message)
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
      Ok
        (error_response 400 "invalid_query"
           (Endpoint.allowed_values "agg" Endpoint.trace_agg))

let logs store req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Log
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Ok (error_response 400 "invalid_query" message)
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
      Ok (error_response 400 "invalid_query" message)
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
      Ok
        (error_response 400 "invalid_query" "groupBy is required")
  | _, Some agg, _ when not (List.mem agg Endpoint.log_agg) ->
      Ok
        (error_response 400 "invalid_query"
           (Endpoint.allowed_values "agg" Endpoint.log_agg))
  | _, _, Error message ->
      Ok (error_response 400 "invalid_query" message)
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
      Ok
        (error_response 400 "invalid_query" "type is required")
  | _, None, _ ->
      Ok (error_response 400 "invalid_query" "field is required")
  | _, _, Error message ->
      Ok (error_response 400 "invalid_query" message)
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
      Ok
        (error_response 400 "invalid_query"
           (Endpoint.allowed_values "type" Endpoint.facet_types))

let metrics store req =
  with_query req @@ fun params ->
  match
    List_policy.list_request ~kind:List_policy.Metric
      ~now_ms:(Store.now_ms store) params
  with
  | Error message ->
      Ok (error_response 400 "invalid_query" message)
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
      Ok (error_response 400 "invalid_query" message)
  | Ok (window, lookback) ->
      store_json (Store.stats ~window store) (fun stats ->
          match Model.stats_to_json stats with
          | `Assoc fields ->
              `Assoc
                (fields
                @ [ ("meta", List_policy.store_stats_meta ~lookback) ])
          | json -> json)

let method_not_allowed_handler ~allowed _request =
  Ok (method_not_allowed ()
      |> add_response_header "allow" (String.concat ", " allowed))

let not_found_handler _request = Ok (not_found ())

let with_route_param name f req =
  match Service.Extractors.Param.string name req with
  | Ok value -> f value req
  | Error error -> Error error

(* Every route comes from one declaration, and only the declared query
   parameters reach a handler, so the router topology, the inventory, and the
   OpenAPI document are the same list (desc-de6o, desc-dmuw). *)
let declared ~decl route req =
  let result = Service.Extractors.Query.all req in
  match result with
  | Ok params -> (
      match Endpoint.validate_query decl params with
      | Error message ->
          Ok (error_response 400 "invalid_query" message)
      | Ok () -> route req)
  | Error { S.Error.kind = Bad_request { message }; _ } ->
      Ok (error_response 400 "invalid_query" message)
  | Error error -> Error error

let route_for config store (endpoint : Endpoint.t) =
  match endpoint.Endpoint.id with
  | "root" -> fun _req -> Ok (root_text config)
  | "health" | "healthz" -> fun _req -> Ok (health config)
  | "ready" -> fun _req -> ready config store
  | "status" -> fun _req -> Ok (status config store)
  | "instructions" -> fun _req -> Ok (instructions config)
  | "endpoints" -> fun _req -> Ok (endpoints config)
  | "openapi" -> fun _req -> Ok (openapi config)
  | "docs_index" -> fun _req -> Ok (docs_index ())
  | "docs_get" ->
      with_route_param "name" (fun name _req ->
          Ok (docs_get name))
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
  | "metrics" -> metrics store
  | "facets" -> facets store
  | "stats" -> stats store
  | id ->
      fun _req ->
        Ok
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

let run_store_result = function
  | Ok value -> value
  | Error error -> failwith (store_error_message error)

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

let check_bind_available ~caps config =
  let fd =
    Ox_caps.Cap_unix.socket ~caps (socket_domain config.Config.host) Unix.SOCK_STREAM 0
  in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      (* The real listener reuses the address too, so a restart is not blocked
         by connections still in TIME_WAIT. *)
      Unix.setsockopt fd Unix.SO_REUSEADDR true;
      Unix.bind fd (unix_addr config.host config.port);
      Unix.listen fd 1)

(* The serving switch has finished before the store closes on this
   still-live outer switch. *)
let close_store ~caps store =
  match Store.close store with
  | Ok () -> ()
  | Error error ->
      Ox_caps.Cap_stdlib.prerr_endline ~caps
        (Format.asprintf "inn: closing the store failed: %a" Store.pp_error error)

(* Startup lines record the effective configuration, so
   [journalctl --user -u inn] shows the listen address, the data directory,
   and the budget the running process actually uses (svc-dh98). *)
let log_startup ~caps config =
  Ox_caps.Cap_stdlib.prerr_endline ~caps
    (Printf.sprintf "inn server listening on http://%s:%d" config.Config.host
       config.port);
  Ox_caps.Cap_stdlib.prerr_endline ~caps
    (Printf.sprintf
       "inn server configuration: data=%s max_db_size=%dMB segments=%d"
       config.data_dir config.max_db_size_mb Store.segment_count)

(* svc-pehm: Both SIGTERM and SIGINT stop accepts, then Serve.h1 drains
   in-flight requests for five seconds, and the outer finaliser closes the
   store, so systemd sees a clean exit.
   Keep Inn's /ready JSON contract instead of introducing Door-owned CLI/config. *)
let with_shutdown_signals ~caps ~sw f =
  let stop, resolver = Eio.Promise.create () in
  let signal = Atomic.make 0 in
  let changed = Eio.Condition.create () in
  let on_signal signo =
    Atomic.set draining true;
    Atomic.set signal signo;
    Eio.Condition.broadcast changed
  in
  (* Eio conditions are domain-local; like Ox_app, this must use Sys.signal,
     whose callback may close over the condition, rather than Sys.Safe.signal. *)
  let set_signal behavior_signal behavior =
    (Ox_caps.Cap_sys.signal [@alert "-unsafe_multidomain"]) ~caps
      behavior_signal behavior
  in
  let previous_term = set_signal Sys.sigterm (Sys.Signal_handle on_signal) in
  Fun.protect
    ~finally:(fun () -> ignore (set_signal Sys.sigterm previous_term))
    (fun () ->
      let previous_int = set_signal Sys.sigint (Sys.Signal_handle on_signal) in
      Fun.protect
        ~finally:(fun () -> ignore (set_signal Sys.sigint previous_int))
        (fun () ->
          Eio.Fiber.fork_daemon ~sw (fun () ->
              (* Check and suspend atomically, including signals that arrived
                 before this monitor was forked. Only a fiber resolves [stop]. *)
              ignore
                (Eio.Condition.loop_no_mutex changed (fun () ->
                     match Atomic.get signal with
                     | 0 -> None
                     | signo -> Some signo));
              Eio.Promise.resolve resolver ();
              `Stop_daemon);
          f stop))

let run ~caps ~sw ~env config =
  check_bind_available ~caps config;
  mark_started ~caps ();
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let store = run_store_result (Store.open_ ~caps ~sw config) in
  Fun.protect
    ~finally:(fun () -> close_store ~caps store)
    (fun () ->
      (* Serve.h1 returns after draining; the store closes on the outer
         switch. *)
      Eio.Switch.run (fun serve_sw ->
          log_startup ~caps config;
          let addr =
            Serve.tcp_addr ~host:config.Config.host ~port:config.port
          in
          with_shutdown_signals ~caps ~sw:serve_sw (fun stop ->
              Serve.h1 ~sw:serve_sw ~net ~clock ~addr ~stop
                ~drain_timeout:(Ox.Duration.seconds 5)
                ~config:server_config
                (handler config store))))
