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

let accepted_response accepted =
  json_response (`Assoc [ ("accepted", `Int accepted) ])

let method_not_allowed () =
  error_response 405 "method_not_allowed" "method is not allowed for this endpoint"

let not_found () = error_response 404 "not_found" "endpoint not found"

let health config =
  let instance_id =
    match Atomic.get daemon_instance_id with
    | Some value -> [ ("instanceId", `String value) ]
    | None -> []
  in
  json_response
    (`Assoc
      ([
         ("ok", `Bool true);
         ("pid", `Int (Unix.getpid ()));
         ("stateDir", `String config.Config.state_dir);
         ("dbPath", `String config.db_path);
         ("baseUrl", `String config.base_url);
       ]
      @ instance_id))

let endpoint method_ path description =
  `Assoc
    [
      ("method", `String method_);
      ("path", `String path);
      ("description", `String description);
    ]

let endpoint_inventory =
  [
    endpoint "GET" "/health" "liveness and configured storage paths";
    endpoint "POST" "/v1/traces" "OTLP/HTTP JSON trace ingest";
    endpoint "POST" "/v1/logs" "OTLP/HTTP JSON log ingest";
    endpoint "POST" "/v1/metrics" "OTLP/HTTP JSON metric ingest";
    endpoint "GET" "/services" "services that have emitted telemetry";
    endpoint "GET" "/traces" "recent trace summaries";
    endpoint "GET" "/traces/search" "search trace summaries by span filters";
    endpoint "GET" "/traces/stats" "aggregate trace statistics";
    endpoint "GET" "/traces/{traceId}" "full trace with spans and logs";
    endpoint "GET" "/traces/{traceId}/spans" "spans for one trace";
    endpoint "GET" "/traces/{traceId}/logs" "logs correlated with one trace";
    endpoint "GET" "/spans/search" "search spans";
    endpoint "GET" "/spans/{spanId}" "single span";
    endpoint "GET" "/spans/{spanId}/logs" "logs correlated with one span";
    endpoint "GET" "/logs" "recent logs";
    endpoint "GET" "/logs/search" "search logs";
    endpoint "GET" "/logs/stats" "aggregate log counts";
    endpoint "GET" "/ai/calls" "search spans that represent AI calls";
    endpoint "GET" "/ai/calls/{spanId}" "AI call detail with correlated logs";
    endpoint "GET" "/ai/stats" "aggregate AI call statistics";
    endpoint "GET" "/metrics" "recent metric points";
    endpoint "GET" "/facets" "discover trace and log facet values";
    endpoint "GET" "/stats" "store row counts";
    endpoint "GET" "/instructions" "copy-paste OTLP setup instructions";
    endpoint "GET" "/endpoints" "machine-readable endpoint inventory";
    endpoint "GET" "/openapi.json" "OpenAPI description";
  ]

let endpoints config =
  json_response
    (`Assoc
      [
        ("baseUrl", `String config.Config.base_url);
        ("exporterUrl", `String (config.base_url ^ "/v1/traces"));
        ("logsExporterUrl", `String (config.base_url ^ "/v1/logs"));
        ("metricsExporterUrl", `String (config.base_url ^ "/v1/metrics"));
        ("databasePath", `String config.db_path);
        ("endpoints", `List endpoint_inventory);
      ])

let instructions config =
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
  %s/openapi.json
|}
       config.Config.base_url config.base_url config.base_url config.base_url
       config.base_url config.base_url config.base_url config.base_url
       config.base_url config.base_url config.base_url config.base_url)

let path_item method_ summary =
  `Assoc
    [
      (String.lowercase_ascii method_,
       `Assoc
         [
           ("summary", `String summary);
           ( "responses",
             `Assoc [ ("200", `Assoc [ ("description", `String "OK") ]) ] );
         ]);
    ]

let openapi config =
  let paths =
    List.map
      (function
        | `Assoc fields ->
            let method_ =
              match List.assoc_opt "method" fields with
              | Some (`String value) -> value
              | _ -> "GET"
            in
            let path =
              match List.assoc_opt "path" fields with
              | Some (`String value) -> value
              | _ -> "/"
            in
            let description =
              match List.assoc_opt "description" fields with
              | Some (`String value) -> value
              | _ -> path
            in
            (path, path_item method_ description)
        | _ -> ("/", path_item "GET" "Inn endpoint"))
      endpoint_inventory
  in
  json_response
    (`Assoc
      [
        ("openapi", `String "3.1.0");
        ("info", `Assoc [ ("title", `String "Inn API"); ("version", `String "1.0.0") ]);
        ("servers", `List [ `Assoc [ ("url", `String config.Config.base_url) ] ]);
        ("paths", `Assoc paths);
      ])

let root_text config =
  text_response
    (Printf.sprintf
       "inn local telemetry server\n\nPOST /v1/traces\nPOST /v1/logs\nPOST /v1/metrics\nGET /api/services\nGET /api/traces\nGET /api/traces/search\nGET /api/traces/stats\nGET /api/traces/<trace-id>\nGET /api/traces/<trace-id>/spans\nGET /api/traces/<trace-id>/logs\nGET /api/spans/search\nGET /api/spans/<span-id>\nGET /api/spans/<span-id>/logs\nGET /api/logs\nGET /api/logs/search\nGET /api/logs/stats\nGET /api/ai/calls\nGET /api/ai/calls/<span-id>\nGET /api/ai/stats\nGET /api/metrics\nGET /api/facets?type=logs&field=severity\nGET /api/stats\nGET /instructions\nGET /endpoints\nGET /openapi.json\n\nstate: %s\ndatabase: %s\n"
       config.Config.state_dir config.db_path)

let store_error_message error = Format.asprintf "%a" Store.pp_error error

let store_json eff encode =
  let open Eta.Syntax in
  let* result = Eta.Effect.result eff in
  match result with
  | Ok value -> Eta.Effect.pure (json_response (encode value))
  | Error error ->
      Eta.Effect.pure
        (error_response 500 "store_error" (store_error_message error))

let store_accepted eff =
  let open Eta.Syntax in
  let* result = Eta.Effect.result eff in
  match result with
  | Ok accepted -> Eta.Effect.pure (accepted_response accepted)
  | Error error ->
      Eta.Effect.pure
        (error_response 500 "store_error" (store_error_message error))

let param name params = List.assoc_opt name params

let with_query req f =
  let open Eta.Syntax in
  let* result = Eta.Effect.result (Service.Extractors.Query.all req) in
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

let parse_limit ?(default = 100) params =
  match param "limit" params with
  | None -> Ok default
  | Some value -> (
      match int_of_string_opt value with
      | Some limit when limit > 0 && limit <= 10_000 -> Ok limit
      | _ -> Error "limit must be an integer between 1 and 10000")

let valid_trace_agg = function
  | "count" | "avg_duration" | "p95_duration" | "error_rate" -> true
  | _ -> false

let valid_ai_agg = function
  | "count" | "avg_duration" | "p95_duration" | "total_input_tokens"
  | "total_output_tokens" ->
      true
  | _ -> false

let json_list name encode values =
  `Assoc [ (name, `List (List.map encode values)) ]

let ingest req decode ingest =
  let open Eta.Syntax in
  let* body = Service.Extractors.body_text ~max_bytes:max_body_bytes req in
  match decode body with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_otlp" message)
  | Ok values -> store_accepted (ingest values)

let services store _req =
  store_json (Store.list_services store) (fun services ->
      json_list "services" (fun service -> `String service) services)

let traces store req =
  with_query req @@ fun params ->
  match parse_limit params with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok limit ->
      store_json
        (Store.list_trace_summaries ?service:(param "service" params) ~limit
           store)
        (json_list "traces" Model.trace_summary_to_json)

let trace store trace_id _req =
  let open Eta.Syntax in
  let* result = Eta.Effect.result (Store.get_trace store trace_id) in
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
  let* result = Eta.Effect.result (Store.get_span store span_id) in
  match result with
  | Error error ->
      Eta.Effect.pure
        (error_response 500 "store_error" (store_error_message error))
  | Ok None ->
      Eta.Effect.pure (error_response 404 "span_not_found" "span was not found")
  | Ok (Some span) -> Eta.Effect.pure (json_response (Model.span_to_json span))

let trace_spans store trace_id _req =
  store_json (Store.list_trace_spans store trace_id)
    (json_list "spans" Model.span_to_json)

let trace_logs store trace_id _req =
  store_json (Store.list_trace_logs store trace_id)
    (json_list "logs" Model.log_to_json)

let span_logs store span_id _req =
  store_json (Store.list_span_logs store span_id)
    (json_list "logs" Model.log_to_json)

let has_prefix prefix text = String.starts_with ~prefix text

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

let span_all_attrs (span : Model.span) = span.resource @ span.attributes

let attr_any keys attrs =
  List.find_map
    (fun key ->
      match List.assoc_opt key attrs with
      | Some value -> Some value
      | None -> None)
    keys

let attr_int keys attrs =
  match attr_any keys attrs with
  | None -> None
  | Some value -> int_of_string_opt value

let ai_model attrs =
  attr_any
    [
      "ai.model.id";
      "ai.model";
      "gen_ai.request.model";
      "gen_ai.response.model";
    ]
    attrs

let ai_provider attrs =
  attr_any
    [
      "ai.model.provider";
      "ai.provider";
      "gen_ai.system";
      "gen_ai.provider.name";
    ]
    attrs

let ai_session_id attrs =
  attr_any
    [
      "ai.telemetry.metadata.sessionId";
      "ai.session.id";
      "session.id";
    ]
    attrs

let ai_function_id attrs =
  attr_any
    [
      "ai.telemetry.functionId";
      "ai.function.id";
      "function.id";
    ]
    attrs

let ai_input_tokens attrs =
  attr_int
    [
      "ai.usage.inputTokens";
      "ai.usage.promptTokens";
      "gen_ai.usage.input_tokens";
      "gen_ai.usage.prompt_tokens";
    ]
    attrs

let ai_output_tokens attrs =
  attr_int
    [
      "ai.usage.outputTokens";
      "ai.usage.completionTokens";
      "gen_ai.usage.output_tokens";
      "gen_ai.usage.completion_tokens";
    ]
    attrs

let is_ai_span (span : Model.span) =
  let attrs = span_all_attrs span in
  List.exists
    (fun (key, _) -> has_prefix "ai." key || has_prefix "gen_ai." key)
    attrs
  || contains_substring ~needle:"generateText" span.operation_name
  || contains_substring ~needle:"streamText" span.operation_name
  || contains_substring ~needle:"generateObject" span.operation_name
  || contains_substring ~needle:"streamObject" span.operation_name

let span_search_text (span : Model.span) =
  let attrs = span_all_attrs span in
  let attr_text =
    attrs |> List.map (fun (key, value) -> key ^ "=" ^ value) |> String.concat "\n"
  in
  let event_text =
    span.events
    |> List.map (fun (event : Model.span_event) ->
           event.Model.name ^ "\n"
           ^ (event.attributes
             |> List.map (fun (key, value) -> key ^ "=" ^ value)
             |> String.concat "\n"))
    |> String.concat "\n"
  in
  String.concat "\n" [ span.operation_name; attr_text; event_text ]

let option_matches expected actual =
  match expected with
  | None -> true
  | Some expected -> (
      match actual with
      | Some actual -> String.equal expected actual
      | None -> false)

let ai_call_matches params (span : Model.span) =
  let attrs = span_all_attrs span in
  option_matches (param "model" params) (ai_model attrs)
  && option_matches (param "provider" params) (ai_provider attrs)
  && option_matches (param "sessionId" params) (ai_session_id attrs)
  && option_matches (param "functionId" params) (ai_function_id attrs)
  &&
  match param "text" params with
  | None -> true
  | Some text -> contains_substring ~needle:text (span_search_text span)

let ai_call_to_json (span : Model.span) =
  let attrs = span_all_attrs span in
  let optional name = function
    | None -> []
    | Some value -> [ (name, `String value) ]
  in
  let optional_int name = function
    | None -> []
    | Some value -> [ (name, `Int value) ]
  in
  `Assoc
    ([
       ("traceId", `String span.trace_id);
       ("spanId", `String span.span_id);
       ("serviceName", `String span.service_name);
       ("operationName", `String span.operation_name);
       ("status", `String span.status);
       ("durationMs", `Float span.duration_ms);
       ("attributes", Model.attrs_to_json span.attributes);
       ("resource", Model.attrs_to_json span.resource);
     ]
    @ optional "model" (ai_model attrs)
    @ optional "provider" (ai_provider attrs)
    @ optional "sessionId" (ai_session_id attrs)
    @ optional "functionId" (ai_function_id attrs)
    @ optional_int "inputTokens" (ai_input_tokens attrs)
    @ optional_int "outputTokens" (ai_output_tokens attrs))

let select_ai_spans store params =
  match parse_limit params with
  | Error message -> Error message
  | Ok limit ->
      let filter =
        {
          Store.service = param "service" params;
          trace_id = param "traceId" params;
          operation = param "operation" params;
          parent_operation = None;
          status = param "status" params;
          attrs = attr_filters params;
          limit = 10_000;
        }
      in
      Ok (limit, Store.search_spans filter store)

let ai_calls store req =
  with_query req @@ fun params ->
  match select_ai_spans store params with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok (limit, eff) ->
      let open Eta.Syntax in
      let* result = Eta.Effect.result eff in
      (match result with
      | Error error ->
          Eta.Effect.pure
            (error_response 500 "store_error" (store_error_message error))
      | Ok spans ->
          let calls =
            spans
            |> List.filter is_ai_span
            |> List.filter (ai_call_matches params)
            |> List.sort (fun (left : Model.span) (right : Model.span) ->
                   compare right.Model.start_time_ms left.Model.start_time_ms)
            |> fun spans ->
            let rec take acc count = function
              | _ when count <= 0 -> List.rev acc
              | [] -> List.rev acc
              | item :: rest -> take (item :: acc) (count - 1) rest
            in
            take [] limit spans
          in
          Eta.Effect.pure (json_response (json_list "calls" ai_call_to_json calls)))

let ai_call store span_id _req =
  let open Eta.Syntax in
  let* span_result = Eta.Effect.result (Store.get_span store span_id) in
  match span_result with
  | Error error ->
      Eta.Effect.pure
        (error_response 500 "store_error" (store_error_message error))
  | Ok None ->
      Eta.Effect.pure
        (error_response 404 "ai_call_not_found" "AI call was not found")
  | Ok (Some span) when not (is_ai_span span) ->
      Eta.Effect.pure
        (error_response 404 "ai_call_not_found" "AI call was not found")
  | Ok (Some span) ->
      let* logs_result = Eta.Effect.result (Store.list_span_logs store span.span_id) in
      (match logs_result with
      | Error error ->
          Eta.Effect.pure
            (error_response 500 "store_error" (store_error_message error))
      | Ok logs ->
          Eta.Effect.pure
            (json_response
               (`Assoc
                 [
                   ("call", ai_call_to_json span);
                   ("span", Model.span_to_json span);
                   ("logs", `List (List.map Model.log_to_json logs));
                 ])))

let ai_stats store req =
  with_query req @@ fun params ->
  match
    (param "groupBy" params, param "agg" params, parse_limit ~default:20 params)
  with
  | None, _, _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query" "groupBy is required")
  | _, None, _ ->
      Eta.Effect.pure (error_response 400 "invalid_query" "agg is required")
  | _, _, Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Some _group_by, Some agg, Ok _limit when not (valid_ai_agg agg) ->
      Eta.Effect.pure
        (error_response 400 "invalid_query"
           "agg must be count, avg_duration, p95_duration, total_input_tokens, or total_output_tokens")
  | Some group_by, Some agg, Ok limit -> (
      match select_ai_spans store params with
      | Error message ->
          Eta.Effect.pure (error_response 400 "invalid_query" message)
      | Ok (_, eff) ->
          let open Eta.Syntax in
          let* result = Eta.Effect.result eff in
          (match result with
                  | Error error ->
                      Eta.Effect.pure
                        (error_response 500 "store_error" (store_error_message error))
                  | Ok spans ->
                      let groups = Hashtbl.create 16 in
                      let bucket group span =
                        let count, total, durations, input_tokens, output_tokens =
                          Option.value (Hashtbl.find_opt groups group)
                            ~default:(0, 0.0, [], 0, 0)
                        in
                        let attrs = span_all_attrs span in
                        Hashtbl.replace groups group
                          ( count + 1,
                            total +. span.Model.duration_ms,
                            span.duration_ms :: durations,
                            input_tokens
                            + Option.value (ai_input_tokens attrs) ~default:0,
                            output_tokens
                            + Option.value (ai_output_tokens attrs) ~default:0 )
                      in
                      let group_for span =
                        let attrs = span_all_attrs span in
                        match group_by with
                        | "provider" ->
                            Option.value (ai_provider attrs) ~default:"unknown"
                        | "model" -> Option.value (ai_model attrs) ~default:"unknown"
                        | "functionId" ->
                            Option.value (ai_function_id attrs) ~default:"unknown"
                        | "sessionId" ->
                            Option.value (ai_session_id attrs) ~default:"unknown"
                        | "status" -> span.Model.status
                        | _ -> "unknown"
                      in
                      spans
                      |> List.filter is_ai_span
                      |> List.filter (ai_call_matches params)
                      |> List.iter (fun span -> bucket (group_for span) span);
                      let rows =
                        Hashtbl.fold
                          (fun group (count, total, durations, input_tokens, output_tokens) acc ->
                            let value =
                              match agg with
                              | "count" -> float_of_int count
                              | "avg_duration" -> total /. float_of_int (max 1 count)
                              | "p95_duration" ->
                                  let sorted = List.sort Float.compare durations in
                                  let len = List.length sorted in
                                  if len = 0 then 0.0
                                  else
                                    let index =
                                      max 0
                                        (min (len - 1)
                                           (int_of_float
                                              (ceil
                                                 ((float_of_int len *. 0.95)
                                                -. 1.0))))
                                    in
                                    List.nth sorted index
                              | "total_input_tokens" -> float_of_int input_tokens
                              | "total_output_tokens" -> float_of_int output_tokens
                              | _ -> float_of_int count
                            in
                            `Assoc
                              [
                                ("group", `String group);
                                ("value", `Float value);
                                ("count", `Int count);
                              ]
                            :: acc)
                          groups []
                        |> List.sort (fun left right ->
                               let value = function
                                 | `Assoc fields -> (
                                     match List.assoc_opt "value" fields with
                                     | Some (`Float value) -> value
                                     | Some (`Int value) -> float_of_int value
                                     | _ -> 0.0)
                                 | _ -> 0.0
                               in
                               Float.compare (value right) (value left))
                      in
                      let rec take acc count = function
                        | _ when count <= 0 -> List.rev acc
                        | [] -> List.rev acc
                        | item :: rest -> take (item :: acc) (count - 1) rest
                      in
                      Eta.Effect.pure
                        (json_response
                           (`Assoc [ ("stats", `List (take [] limit rows)) ]))))

let search_spans store req =
  with_query req @@ fun params ->
  match parse_limit params with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok limit ->
      let filter =
        {
          Store.service = param "service" params;
          trace_id = param "traceId" params;
          operation = param "operation" params;
          parent_operation = param "parentOperation" params;
          status = param "status" params;
          attrs = attr_filters params;
          limit;
        }
      in
      store_json (Store.search_spans filter store)
        (json_list "spans" Model.span_to_json)

let search_traces store req =
  with_query req @@ fun params ->
  match parse_limit params with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok limit ->
      let filter =
        {
          Store.service = param "service" params;
          operation = param "operation" params;
          status = param "status" params;
          attrs = attr_filters params;
          limit;
        }
      in
      store_json (Store.search_traces filter store)
        (json_list "traces" Model.trace_summary_to_json)

let trace_stats store req =
  with_query req @@ fun params ->
  match (param "groupBy" params, param "agg" params, parse_limit ~default:20 params) with
  | None, _, _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query" "groupBy is required")
  | _, None, _ ->
      Eta.Effect.pure (error_response 400 "invalid_query" "agg is required")
  | _, _, Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Some group_by, Some agg, Ok limit when valid_trace_agg agg ->
      let filter =
        {
          Store.group_by;
          agg;
          service = param "service" params;
          operation = param "operation" params;
          status = param "status" params;
          attrs = attr_filters params;
          limit;
        }
      in
      store_json (Store.trace_stats filter store)
        (json_list "stats" Model.stat_item_to_json)
  | _, Some _, Ok _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query"
           "agg must be count, avg_duration, p95_duration, or error_rate")

let logs store req =
  with_query req @@ fun params ->
  match parse_limit params with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok limit ->
      let filter =
        {
          Store.service = param "service" params;
          severity = param "severity" params;
          contains = param "contains" params;
          limit;
        }
      in
      store_json (Store.list_logs filter store)
        (json_list "logs" Model.log_to_json)

let search_logs store req =
  with_query req @@ fun params ->
  match parse_limit params with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok limit ->
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
          limit;
        }
      in
      store_json (Store.search_logs filter store)
        (json_list "logs" Model.log_to_json)

let log_stats store req =
  with_query req @@ fun params ->
  match (param "groupBy" params, param "agg" params, parse_limit ~default:20 params) with
  | None, _, _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query" "groupBy is required")
  | _, Some agg, _ when not (String.equal agg "count") ->
      Eta.Effect.pure
        (error_response 400 "invalid_query" "agg must be count")
  | _, _, Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Some group_by, _, Ok limit ->
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
          limit;
        }
      in
      store_json (Store.log_stats filter store)
        (json_list "stats" Model.stat_item_to_json)

let facets store req =
  with_query req @@ fun params ->
  match (param "type" params, param "field" params, parse_limit ~default:20 params) with
  | None, _, _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query" "type is required")
  | _, None, _ ->
      Eta.Effect.pure (error_response 400 "invalid_query" "field is required")
  | _, _, Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Some kind, Some field, Ok limit
    when String.equal kind "traces" || String.equal kind "logs" ->
      let filter =
        {
          Store.kind;
          field;
          key = param "key" params;
          service = param "service" params;
          limit;
        }
      in
      store_json (Store.facets filter store)
        (json_list "facets" Model.facet_item_to_json)
  | Some _, Some _, Ok _ ->
      Eta.Effect.pure
        (error_response 400 "invalid_query" "type must be traces or logs")

let metrics store req =
  with_query req @@ fun params ->
  match parse_limit params with
  | Error message ->
      Eta.Effect.pure (error_response 400 "invalid_query" message)
  | Ok limit ->
      let filter =
        {
          Store.service = param "service" params;
          name = param "name" params;
          limit;
        }
      in
      store_json (Store.list_metric_points filter store)
        (json_list "metrics" Model.metric_point_to_json)

let stats store _req = store_json (Store.stats store) Model.stats_to_json

let add_response_header name value response =
  let headers = H.Core.Header.unsafe_add name value (S.Response.headers response) in
  S.Response.make ~headers ~status:(S.Response.status response)
    ~body:(S.Response.body response)
    ~trailers:(S.Response.trailers response)
    ()

let method_not_allowed_handler ~allowed _request =
  method_not_allowed ()
  |> add_response_header "allow" (String.concat ", " allowed)
  |> Eta.Effect.pure

let not_found_handler _request = Eta.Effect.pure (not_found ())

let with_route_param name f req =
  let open Eta.Syntax in
  let* value = Service.Extractors.Param.string name req in
  f value req

let add_route router ~methods path route =
  Service.Router.add_exn router ~methods path route;
  let aliases =
    if String.equal path "/" then [ "/api"; "/api/" ] else [ "/api" ^ path ]
  in
  List.iter
    (fun alias -> Service.Router.add_exn router ~methods alias route)
    aliases

let handler config store =
  let router = Service.Router.create () in
  add_route router ~methods:[ "GET" ] "/" (fun _req ->
      Eta.Effect.pure (root_text config));
  add_route router ~methods:[ "GET" ] "/health" (fun _req ->
      Eta.Effect.pure (health config));
  add_route router ~methods:[ "GET" ] "/healthz" (fun _req ->
      Eta.Effect.pure (health config));
  add_route router ~methods:[ "GET" ] "/instructions" (fun _req ->
      Eta.Effect.pure (instructions config));
  add_route router ~methods:[ "GET" ] "/endpoints" (fun _req ->
      Eta.Effect.pure (endpoints config));
  add_route router ~methods:[ "GET" ] "/openapi.json" (fun _req ->
      Eta.Effect.pure (openapi config));
  add_route router ~methods:[ "POST" ] "/v1/traces" (fun req ->
      ingest req Otlp.decode_traces_json (Store.ingest_traces store));
  add_route router ~methods:[ "POST" ] "/v1/logs" (fun req ->
      ingest req Otlp.decode_logs_json (Store.ingest_logs store));
  add_route router ~methods:[ "POST" ] "/v1/metrics" (fun req ->
      ingest req Otlp.decode_metrics_json (Store.ingest_metrics store));
  add_route router ~methods:[ "GET" ] "/services" (services store);
  add_route router ~methods:[ "GET" ] "/traces" (traces store);
  add_route router ~methods:[ "GET" ] "/traces/search" (search_traces store);
  add_route router ~methods:[ "GET" ] "/traces/stats" (trace_stats store);
  add_route router ~methods:[ "GET" ] "/traces/{traceId}/spans"
    (with_route_param "traceId" (trace_spans store));
  add_route router ~methods:[ "GET" ] "/traces/{traceId}/logs"
    (with_route_param "traceId" (trace_logs store));
  add_route router ~methods:[ "GET" ] "/traces/{traceId}"
    (with_route_param "traceId" (trace store));
  add_route router ~methods:[ "GET" ] "/spans/search" (search_spans store);
  add_route router ~methods:[ "GET" ] "/spans/{spanId}"
    (with_route_param "spanId" (span store));
  add_route router ~methods:[ "GET" ] "/spans/{spanId}/logs"
    (with_route_param "spanId" (span_logs store));
  add_route router ~methods:[ "GET" ] "/logs" (logs store);
  add_route router ~methods:[ "GET" ] "/logs/search" (search_logs store);
  add_route router ~methods:[ "GET" ] "/logs/stats" (log_stats store);
  add_route router ~methods:[ "GET" ] "/ai/calls" (ai_calls store);
  add_route router ~methods:[ "GET" ] "/ai/calls/{spanId}"
    (with_route_param "spanId" (ai_call store));
  add_route router ~methods:[ "GET" ] "/ai/stats" (ai_stats store);
  add_route router ~methods:[ "GET" ] "/facets" (facets store);
  add_route router ~methods:[ "GET" ] "/metrics" (metrics store);
  add_route router ~methods:[ "GET" ] "/stats" (stats store);
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

let run ~sw ~env config =
  check_bind_available config;
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let store = run_store_effect ~sw ~clock (Store.open_ config) in
  Fun.protect
    ~finally:(fun () ->
      run_store_effect ~sw ~clock (Store.close store))
    (fun () ->
      let addr = Serve.tcp_addr ~host:config.Config.host ~port:config.port in
      prerr_endline
        (Printf.sprintf "inn server listening on http://%s:%d" config.host
           config.port);
      Serve.h1 ~sw ~net ~clock ~addr (handler config store))
