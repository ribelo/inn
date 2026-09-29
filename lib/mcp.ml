(* The MCP catalogue and query translation live here; protocol handling is independently testable. *)
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
  let params =
    List.filter_map
      (fun (key, value) -> Option.map (fun v -> (key, v)) value)
      params
  in
  match params with
  | [] -> ""
  | params ->
      "?"
      ^ String.concat "&"
          (List.map
             (fun (key, value) ->
               percent_encode key ^ "=" ^ percent_encode value)
             params)

let attr_param (key, value) = ("attr." ^ key, Some value)

let mcp_string_property description =
  `Assoc [ ("type", `String "string"); ("description", `String description) ]

let mcp_int_property description =
  `Assoc [ ("type", `String "integer"); ("description", `String description) ]

let mcp_lookback_property =
  mcp_string_property
    "Relative time window: Nm, Nh, Nd, or all. Lists default to 1h; stats, \
     facets, and services default to all."

let mcp_cursor_property =
  mcp_string_property
    "Opaque nextCursor value from a previous list response."

let mcp_attributes_property =
  `Assoc
    [
      ("type", `String "object");
      ( "description",
        `String "Exact OTel attribute filters as key/value strings." );
      ("additionalProperties", `Assoc [ ("type", `String "string") ]);
    ]

let mcp_attribute_contains_property =
  `Assoc [
    ("type", `String "object");
    ("description", `String "Literal case-insensitive substring matches by attribute key.");
    ("additionalProperties", `Assoc [ ("type", `String "string") ]) ]

let mcp_number_property description =
  `Assoc [ ("type", `String "number"); ("description", `String description) ]

let mcp_schema ?(required = []) properties =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("required", `List (List.map (fun value -> `String value) required));
      ("additionalProperties", `Bool false);
    ]

let mcp_tool ?required name description properties =
  `Assoc
    [
      ("name", `String name);
      ("description", `String description);
      ("inputSchema", mcp_schema ?required properties);
    ]

let mcp_tools =
  [
    mcp_tool "inn_status" "Check configured Inn daemon/server status." [];
    mcp_tool "inn_services"
      "List services that have emitted telemetry."
      [ ("lookback", mcp_lookback_property) ];
    mcp_tool "inn_search_traces"
      "Search trace summaries by service, operation, status, and attributes."
      [
        ("service", mcp_string_property "OTel service.name");
        ("operation", mcp_string_property "Span operation name");
        ("status", mcp_string_property "ok or error");
        ("attributes", mcp_attributes_property);
        ("attributeContains", mcp_attribute_contains_property);
        ("minDurationMs", mcp_number_property "Minimum duration in milliseconds");
        ("text", mcp_string_property "AI prompt or response substring");
        ("lookback", mcp_lookback_property);
        ("cursor", mcp_cursor_property);
        ("limit", mcp_int_property "Maximum number of traces");
      ];
    mcp_tool ~required:[ "traceId" ] "inn_get_trace"
      "Fetch one full trace by trace id."
      [ ("traceId", mcp_string_property "32-character trace id") ];
    mcp_tool ~required:[ "traceId" ] "inn_get_trace_spans"
      "Fetch spans for one trace."
      [
        ("traceId", mcp_string_property "32-character trace id");
        ("lookback", mcp_lookback_property);
        ("cursor", mcp_cursor_property);
        ("limit", mcp_int_property "Maximum number of spans");
      ];
    mcp_tool ~required:[ "traceId" ] "inn_get_trace_logs"
      "Fetch logs correlated with one trace."
      [
        ("traceId", mcp_string_property "32-character trace id");
        ("attributeContains", mcp_attribute_contains_property);
        ("lookback", mcp_lookback_property);
        ("cursor", mcp_cursor_property);
        ("limit", mcp_int_property "Maximum number of logs");
      ];
    mcp_tool "inn_search_spans"
      "Search spans by service, trace id, operation, parent operation, status, \
       and attributes."
      [
        ("service", mcp_string_property "OTel service.name");
        ("traceId", mcp_string_property "Trace id");
        ("operation", mcp_string_property "Span operation name");
        ("parentOperation", mcp_string_property "Parent span operation name");
        ("status", mcp_string_property "ok or error");
        ("attributes", mcp_attributes_property);
        ("attributeContains", mcp_attribute_contains_property);
        ("minDurationMs", mcp_number_property "Minimum duration in milliseconds");
        ("lookback", mcp_lookback_property);
        ("cursor", mcp_cursor_property);
        ("limit", mcp_int_property "Maximum number of spans");
      ];
    mcp_tool ~required:[ "spanId" ] "inn_get_span" "Fetch one span by span id."
      [ ("spanId", mcp_string_property "16-character span id") ];
    mcp_tool ~required:[ "spanId" ] "inn_get_span_logs"
      "Fetch logs correlated with one span."
      [
        ("spanId", mcp_string_property "16-character span id");
        ("attributeContains", mcp_attribute_contains_property);
        ("lookback", mcp_lookback_property);
        ("cursor", mcp_cursor_property);
        ("limit", mcp_int_property "Maximum number of logs");
      ];
    mcp_tool "inn_search_logs"
      "Search logs by service, severity, trace/span correlation, body \
       substring, and attributes."
      [
        ("service", mcp_string_property "OTel service.name");
        ("severity", mcp_string_property "Log severity text");
        ("traceId", mcp_string_property "Trace id");
        ("spanId", mcp_string_property "Span id");
        ("body", mcp_string_property "Body substring");
        ("attributes", mcp_attributes_property);
        ("attributeContains", mcp_attribute_contains_property);
        ("minSeverity", mcp_string_property "Minimum OTLP severity level");
        ("lookback", mcp_lookback_property);
        ("cursor", mcp_cursor_property);
        ("limit", mcp_int_property "Maximum number of logs");
      ];
    mcp_tool ~required:[ "groupBy"; "agg" ] "inn_trace_stats"
      "Aggregate traces by service, operation, status, or attr.<key>."
      [
        ( "groupBy",
          mcp_string_property "service, operation, status, or attr.<key>" );
        ( "agg",
          mcp_string_property "count, avg_duration, p95_duration, or error_rate"
        );
        ("service", mcp_string_property "OTel service.name");
        ("operation", mcp_string_property "Span operation name");
        ("status", mcp_string_property "ok or error");
        ("attributes", mcp_attributes_property);
        ("attributeContains", mcp_attribute_contains_property);
        ("minDurationMs", mcp_number_property "Minimum duration in milliseconds");
        ("lookback", mcp_lookback_property);
        ("limit", mcp_int_property "Maximum number of rows");
      ];
    mcp_tool ~required:[ "groupBy" ] "inn_log_stats"
      "Aggregate log counts by service, severity, scope, or attr.<key>."
      [
        ( "groupBy",
          mcp_string_property "service, severity, scope, or attr.<key>" );
        ("service", mcp_string_property "OTel service.name");
        ("severity", mcp_string_property "Log severity text");
        ("traceId", mcp_string_property "Trace id");
        ("spanId", mcp_string_property "Span id");
        ("body", mcp_string_property "Body substring");
        ("attributes", mcp_attributes_property);
        ("attributeContains", mcp_attribute_contains_property);
        ("minSeverity", mcp_string_property "Minimum OTLP severity level");
        ("lookback", mcp_lookback_property);
        ("limit", mcp_int_property "Maximum number of rows");
      ];
    mcp_tool ~required:[ "type"; "field" ] "inn_facets"
      "List trace or log facet values and counts."
      [
        ("type", mcp_string_property "traces or logs");
        ( "field",
          mcp_string_property
            "service, operation, status, severity, scope, attribute_keys, or \
             attribute_values" );
        ("key", mcp_string_property "Attribute key for attribute_values");
        ("service", mcp_string_property "OTel service.name");
        ("lookback", mcp_lookback_property);
        ("limit", mcp_int_property "Maximum number of values");
      ];
    mcp_tool "inn_search_ai_calls"
      "Search AI calls by service, model, provider, session, function, \
       operation, status, finish reason, and text."
      [
        ("service", mcp_string_property "OTel service.name");
        ("traceId", mcp_string_property "Trace id");
        ("sessionId", mcp_string_property "AI session id");
        ("functionId", mcp_string_property "AI function id");
        ("provider", mcp_string_property "AI provider");
        ("model", mcp_string_property "AI model");
        ("operation", mcp_string_property "GenAI operation name");
        ("status", mcp_string_property "ok or error");
        ("finishReason", mcp_string_property "Model finish reason substring");
        ( "text",
          mcp_string_property "Text contained in the prompt, response, or tools" );
        ("minDurationMs", mcp_number_property "Minimum duration in milliseconds");
        ("lookback", mcp_lookback_property);
        ("cursor", mcp_cursor_property);
        ("limit", mcp_int_property "Maximum number of calls");
      ];
    mcp_tool ~required:[ "spanId" ] "inn_get_ai_call"
      "Fetch one AI call by span id, including span and correlated logs."
      [ ("spanId", mcp_string_property "AI call span id") ];
    mcp_tool ~required:[ "groupBy"; "agg" ] "inn_ai_stats"
      "Aggregate AI call statistics by provider, model, functionId, sessionId, \
       status, operation, or finishReason."
      [
        ( "groupBy",
          mcp_string_property
            "provider, model, functionId, sessionId, status, operation, or \
             finishReason" );
        ( "agg",
          mcp_string_property
            "count, avg_duration, p95_duration, total_input_tokens, \
             total_output_tokens, total_tokens, or error_rate" );
        ("service", mcp_string_property "OTel service.name");
        ("traceId", mcp_string_property "Trace id");
        ("sessionId", mcp_string_property "AI session id");
        ("functionId", mcp_string_property "AI function id");
        ("provider", mcp_string_property "AI provider");
        ("model", mcp_string_property "AI model");
        ("operation", mcp_string_property "GenAI operation name");
        ("status", mcp_string_property "ok or error");
        ("finishReason", mcp_string_property "Model finish reason substring");
        ( "text",
          mcp_string_property "Text contained in the prompt, response, or tools" );
        ("minDurationMs", mcp_number_property "Minimum duration in milliseconds");
        ("lookback", mcp_lookback_property);
        ("limit", mcp_int_property "Maximum number of rows");
      ];
    mcp_tool "inn_metrics" "List recent metric points."
      [
        ("service", mcp_string_property "OTel service.name");
        ("name", mcp_string_property "Metric name");
        ("lookback", mcp_lookback_property);
        ("cursor", mcp_cursor_property);
        ("limit", mcp_int_property "Maximum number of metric points");
      ];
    mcp_tool "inn_stats"
      "Fetch store row counts and the retention section, including the last \
       prune report."
      [ ("lookback", mcp_lookback_property) ];
    mcp_tool "inn_endpoints" "Fetch Inn endpoint inventory." [];
    mcp_tool "inn_instructions" "Fetch OTLP setup instructions." [];
    mcp_tool "inn_openapi" "Fetch Inn OpenAPI JSON." [];
    mcp_tool "inn_docs_index" "List the available Inn guides." [];
    mcp_tool ~required:[ "name" ] "inn_get_doc"
      "Read one Inn guide as Markdown by name (debug, effect, or ox)."
      [ ("name", mcp_string_property "Guide name from inn_docs_index") ];
  ]

let json_member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let json_string_arg name json =
  match json_member name json with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None

let json_int_arg name json =
  match json_member name json with
  | Some (`Int value) when value > 0 -> Some value
  | Some (`String value) -> int_of_string_opt value
  | _ -> None

let json_required_string name json =
  match json_string_arg name json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing required string argument %s" name)

let json_attribute_pairs name prefix json =
  match json_member name json with
  | Some (`Assoc attrs) ->
      List.filter_map (fun (key, value) ->
        let value = match value with
          | `String value -> Some value
          | `Int value -> Some (string_of_int value)
          | `Float value -> Some (string_of_float value)
          | `Bool value -> Some (string_of_bool value)
          | _ -> None in
        Option.map (fun value -> (prefix ^ key, Some value)) value) attrs
  | _ -> []

let json_attributes_arg json = json_attribute_pairs "attributes" "attr." json
let json_attributes_contains_arg json =
  json_attribute_pairs "attributeContains" "attrContains." json

let json_number_arg name json = match json_member name json with
  | Some (`Int n) -> Some (string_of_int n)
  | Some (`Float n) -> Some (string_of_float n)
  | Some (`String n) -> Some n
  | _ -> None

let json_limit_arg ?(default = 100) json =
  Some (string_of_int (Option.value (json_int_arg "limit" json) ~default))

let optional_arg name query_name json = (query_name, json_string_arg name json)

let http_tool ~request ~base_url path =
  match request path with
  | Ok (status, body) when status >= 200 && status < 300 -> Ok body
  | Ok (status, body) -> Error (Printf.sprintf "HTTP %d: %s" status body)
  | Error message ->
      Error
        (Printf.sprintf
           "could not connect to Inn server at %s\n\
            Start it with `systemctl --user start inn` (the systemd user \
            service), `inn daemon`, or `inn server`; use `--base-url URL` to \
            query a different server.\n\
            Details: %s"
           base_url message)

let tool_call ~request ~status ~base_url name args =
  match name with
  | "inn_status" -> Ok (Yojson.Safe.pretty_to_string (status ()))
  | "inn_services" ->
      http_tool ~request ~base_url
        ("/services"
        ^ query [ optional_arg "lookback" "lookback" args ])
  | "inn_search_traces" ->
      http_tool ~request ~base_url
        ("/traces/search"
        ^ query
            ([
               optional_arg "service" "service" args;
               optional_arg "operation" "operation" args;
               optional_arg "status" "status" args;
               optional_arg "text" "text" args;
                ("minDurationMs", json_number_arg "minDurationMs" args);
               optional_arg "lookback" "lookback" args;
               optional_arg "cursor" "cursor" args;
               ("limit", json_limit_arg args);
             ]
            @ json_attributes_arg args
             @ json_attributes_contains_arg args))
  | "inn_get_trace" -> (
      match json_required_string "traceId" args with
      | Ok trace_id ->
          http_tool ~request ~base_url ("/traces/" ^ percent_encode trace_id)
      | Error message -> Error message)
  | "inn_get_trace_spans" -> (
      match json_required_string "traceId" args with
      | Ok trace_id ->
          http_tool ~request ~base_url
            ("/traces/" ^ percent_encode trace_id ^ "/spans"
            ^ query
                [
                  optional_arg "lookback" "lookback" args;
                  optional_arg "cursor" "cursor" args;
                  ("limit", json_limit_arg args);
                ])
      | Error message -> Error message)
  | "inn_get_trace_logs" -> (
      match json_required_string "traceId" args with
      | Ok trace_id ->
          http_tool ~request ~base_url
            ("/traces/" ^ percent_encode trace_id ^ "/logs"
            ^ query
                ([
                  optional_arg "lookback" "lookback" args;
                  optional_arg "cursor" "cursor" args;
                  ("limit", json_limit_arg args);
                ] @ json_attributes_arg args
                  @ json_attributes_contains_arg args))
      | Error message -> Error message)
  | "inn_search_spans" ->
      http_tool ~request ~base_url
        ("/spans/search"
        ^ query
            ([
               optional_arg "service" "service" args;
               optional_arg "traceId" "traceId" args;
               optional_arg "operation" "operation" args;
               optional_arg "parentOperation" "parentOperation" args;
               optional_arg "status" "status" args;
                ("minDurationMs", json_number_arg "minDurationMs" args);
               optional_arg "lookback" "lookback" args;
               optional_arg "cursor" "cursor" args;
               ("limit", json_limit_arg args);
             ]
            @ json_attributes_arg args
             @ json_attributes_contains_arg args))
  | "inn_get_span" -> (
      match json_required_string "spanId" args with
      | Ok span_id ->
          http_tool ~request ~base_url ("/spans/" ^ percent_encode span_id)
      | Error message -> Error message)
  | "inn_get_span_logs" -> (
      match json_required_string "spanId" args with
      | Ok span_id ->
          http_tool ~request ~base_url
            ("/spans/" ^ percent_encode span_id ^ "/logs"
            ^ query
                ([
                  optional_arg "lookback" "lookback" args;
                  optional_arg "cursor" "cursor" args;
                  ("limit", json_limit_arg args);
                ] @ json_attributes_arg args
                  @ json_attributes_contains_arg args))
      | Error message -> Error message)
  | "inn_search_logs" ->
      http_tool ~request ~base_url
        ("/logs/search"
        ^ query
            ([
               optional_arg "service" "service" args;
               optional_arg "severity" "severity" args;
               optional_arg "traceId" "traceId" args;
               optional_arg "spanId" "spanId" args;
               optional_arg "body" "body" args;
                optional_arg "minSeverity" "minSeverity" args;
               optional_arg "lookback" "lookback" args;
               optional_arg "cursor" "cursor" args;
               ("limit", json_limit_arg args);
             ]
            @ json_attributes_arg args
             @ json_attributes_contains_arg args))
  | "inn_trace_stats" -> (
      match
        (json_required_string "groupBy" args, json_required_string "agg" args)
      with
      | Ok group_by, Ok agg ->
          http_tool ~request ~base_url
            ("/traces/stats"
            ^ query
                ([
                   ("groupBy", Some group_by);
                   ("agg", Some agg);
                   optional_arg "service" "service" args;
                   optional_arg "operation" "operation" args;
                   optional_arg "status" "status" args;
                ("minDurationMs", json_number_arg "minDurationMs" args);
                   optional_arg "lookback" "lookback" args;
                   ("limit", json_limit_arg ~default:20 args);
                 ]
                @ json_attributes_arg args
             @ json_attributes_contains_arg args))
      | Error message, _ | _, Error message -> Error message)
  | "inn_log_stats" -> (
      match json_required_string "groupBy" args with
      | Ok group_by ->
          http_tool ~request ~base_url
            ("/logs/stats"
            ^ query
                ([
                   ("groupBy", Some group_by);
                   ("agg", Some "count");
                   optional_arg "service" "service" args;
                   optional_arg "severity" "severity" args;
                   optional_arg "traceId" "traceId" args;
                   optional_arg "spanId" "spanId" args;
                   optional_arg "body" "body" args;
                optional_arg "minSeverity" "minSeverity" args;
                   optional_arg "lookback" "lookback" args;
                   ("limit", json_limit_arg ~default:20 args);
                 ]
                @ json_attributes_arg args
             @ json_attributes_contains_arg args))
      | Error message -> Error message)
  | "inn_facets" -> (
      match
        (json_required_string "type" args, json_required_string "field" args)
      with
      | Ok kind, Ok field ->
          http_tool ~request ~base_url
            ("/facets"
            ^ query
                [
                  ("type", Some kind);
                  ("field", Some field);
                  optional_arg "key" "key" args;
                  optional_arg "service" "service" args;
                  optional_arg "lookback" "lookback" args;
                  ("limit", json_limit_arg ~default:20 args);
                ])
      | Error message, _ | _, Error message -> Error message)
  | "inn_search_ai_calls" ->
      http_tool ~request ~base_url
        ("/ai/calls"
        ^ query
            [
              optional_arg "service" "service" args;
              optional_arg "traceId" "traceId" args;
              optional_arg "sessionId" "sessionId" args;
              optional_arg "functionId" "functionId" args;
              optional_arg "provider" "provider" args;
              optional_arg "model" "model" args;
              optional_arg "operation" "operation" args;
              optional_arg "status" "status" args;
              optional_arg "finishReason" "finishReason" args;
              optional_arg "text" "text" args;
                ("minDurationMs", json_number_arg "minDurationMs" args);
              optional_arg "lookback" "lookback" args;
              optional_arg "cursor" "cursor" args;
              ("limit", json_limit_arg args);
            ])
  | "inn_get_ai_call" -> (
      match json_required_string "spanId" args with
      | Ok span_id ->
          http_tool ~request ~base_url ("/ai/calls/" ^ percent_encode span_id)
      | Error message -> Error message)
  | "inn_ai_stats" -> (
      match
        (json_required_string "groupBy" args, json_required_string "agg" args)
      with
      | Ok group_by, Ok agg ->
          http_tool ~request ~base_url
            ("/ai/stats"
            ^ query
                [
                  ("groupBy", Some group_by);
                  ("agg", Some agg);
                  optional_arg "service" "service" args;
                  optional_arg "traceId" "traceId" args;
                  optional_arg "sessionId" "sessionId" args;
                  optional_arg "functionId" "functionId" args;
                  optional_arg "provider" "provider" args;
                  optional_arg "model" "model" args;
                  optional_arg "operation" "operation" args;
                  optional_arg "status" "status" args;
                  optional_arg "finishReason" "finishReason" args;
                  optional_arg "text" "text" args;
                ("minDurationMs", json_number_arg "minDurationMs" args);
                  optional_arg "lookback" "lookback" args;
                  ("limit", json_limit_arg ~default:20 args);
                ])
      | Error message, _ | _, Error message -> Error message)
  | "inn_metrics" ->
      http_tool ~request ~base_url
        ("/metrics"
        ^ query
            [
              optional_arg "service" "service" args;
              optional_arg "name" "name" args;
              optional_arg "lookback" "lookback" args;
              optional_arg "cursor" "cursor" args;
              ("limit", json_limit_arg args);
            ])
  | "inn_stats" ->
      http_tool ~request ~base_url
        ("/stats" ^ query [ optional_arg "lookback" "lookback" args ])
  | "inn_endpoints" -> http_tool ~request ~base_url "/endpoints"
  | "inn_instructions" -> http_tool ~request ~base_url "/instructions"
  | "inn_openapi" -> http_tool ~request ~base_url "/openapi.json"
  | "inn_docs_index" -> http_tool ~request ~base_url "/docs"
  | "inn_get_doc" -> (
      match json_required_string "name" args with
      | Ok name -> http_tool ~request ~base_url ("/docs/" ^ percent_encode name)
      | Error message -> Error message)
  | _ -> Error ("unknown tool: " ^ name)

let mcp_content text is_error =
  `Assoc
    [
      ( "content",
        `List [ `Assoc [ ("type", `String "text"); ("text", `String text) ] ] );
      ("isError", `Bool is_error);
    ]

let success id result =
  `Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ]

let error id code message =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", id);
      ("error", `Assoc [ ("code", `Int code); ("message", `String message) ]);
    ]

let supported_versions =
  [ "2025-11-25"; "2025-06-18"; "2025-03-26"; "2024-11-05" ]

(* mcp-v9fl: protocol decisions are independent of stdio; tool execution is injected. *)
let handle_request ~tool_call request =
  match request with
  | `Assoc fields -> (
      let id = List.assoc_opt "id" fields in
      let valid_id = function
        | `String _ | `Int _ | `Null -> true
        | _ -> false
      in
      let method_ = json_string_arg "method" request in
      let valid_jsonrpc =
        json_member "jsonrpc" request = Some (`String "2.0")
      in
      match id with
      | Some id when not (valid_id id) ->
          Some (error `Null (-32600) "invalid request id")
      | None -> None
      | _ when not valid_jsonrpc ->
          Some
            (error
               (Option.value id ~default:`Null)
               (-32600) "invalid JSON-RPC version")
      | Some id -> (
          match method_ with
          | None -> Some (error id (-32600) "missing method")
          | Some "initialize" ->
              let params =
                Option.value (json_member "params" request) ~default:(`Assoc [])
              in
              let requested = json_string_arg "protocolVersion" params in
              let protocol_version =
                match requested with
                | Some version when List.mem version supported_versions ->
                    version
                | _ -> List.hd supported_versions
              in
              Some
                (success id
                   (`Assoc
                      [
                        ("protocolVersion", `String protocol_version);
                        ("capabilities", `Assoc [ ("tools", `Assoc []) ]);
                        ( "serverInfo",
                          `Assoc
                            [
                              ("name", `String "inn");
                              ("version", `String Version.value);
                            ] );
                      ]))
          | Some "ping" -> Some (success id (`Assoc []))
          | Some "tools/list" ->
              Some (success id (`Assoc [ ("tools", `List mcp_tools) ]))
          | Some "tools/call" -> (
              let params =
                Option.value (json_member "params" request) ~default:(`Assoc [])
              in
              let args =
                Option.value
                  (json_member "arguments" params)
                  ~default:(`Assoc [])
              in
              match json_string_arg "name" params with
              | None -> Some (error id (-32602) "missing tool name")
              | Some name -> (
                  match tool_call name args with
                  | Ok text -> Some (success id (mcp_content text false))
                  | Error message ->
                      Some (success id (mcp_content message true))))
          | Some method_ ->
              Some (error id (-32601) ("unknown method: " ^ method_))))
  | _ -> Some (error `Null (-32600) "invalid request")

let handle_line ~tool_call line =
  match Yojson.Safe.from_string line with
  | request -> handle_request ~tool_call request
  | exception Yojson.Json_error _ -> Some (error `Null (-32700) "parse error")

(* mcp-dgq3, mcp-seqk, mcp-jovg: each response is exactly one flushed line. *)
let run ~tool_call () =
  let rec loop () =
    match input_line stdin with
    | exception End_of_file -> ()
    | line ->
        (if String.trim line <> "" then
           match handle_line ~tool_call line with
           | None -> ()
           | Some response ->
               print_endline (Yojson.Safe.to_string response);
               flush stdout);
        loop ()
  in
  loop ()
