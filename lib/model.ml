type attrs = (string * Yojson.Safe.t) list

type span_kind = Internal | Server | Client | Producer | Consumer
type span_status = Unset | Ok | Error

type span_link = { trace_id : string; span_id : string; attributes : attrs }

type span_event = {
  name : string;
  timestamp_ns : int;
  attributes : attrs;
}

type span = {
  trace_id : string;
  span_id : string;
  parent_span_id : string option;
  service_name : string;
  scope_name : string option;
  operation_name : string;
  kind : span_kind option;
  start_time_ns : int;
  end_time_ns : int;
  duration_ms : float;
  status : span_status;
  status_message : string option;
  attributes : attrs;
  resource : attrs;
  events : span_event list;
  links : span_link list;
}

type log_record = {
  id : string;
  trace_id : string option;
  span_id : string option;
  service_name : string;
  scope_name : string option;
  severity_text : string;
  severity_number : int option;
  timestamp_ns : int;
  observed_timestamp_ns : int option;
  body : string;
  attributes : attrs;
  resource : attrs;
}

type metric_point = {
  service_name : string;
  scope_name : string option;
  name : string;
  description : string option;
  unit_ : string option;
  kind : string;
  start_time_ns : int option;
  timestamp_ns : int;
  value : string;
  attributes : attrs;
  resource : attrs;
  raw_json : Yojson.Safe.t;
}

type trace_summary = {
  trace_id : string;
  service_name : string;
  root_operation_name : string;
  started_at_ns : int;
  ended_at_ns : int;
  duration_ms : float;
  span_count : int;
  error_count : int;
  is_running : bool;
  warning_count : int;
}

type span_node = {
  span : span;
  depth : int;
  parent_operation_name : string option;
  root_operation_name : string;
  is_running : bool;
  warnings : string list;
}

type trace = {
  summary : trace_summary;
  spans : span_node list;
  logs : log_record list;
  warnings : string list;
}

type token_usage = {
  input_tokens : int option;
  output_tokens : int option;
  total_tokens : int option;
  cached_input_tokens : int option;
  reasoning_tokens : int option;
}

type ai_call = {
  span_id : string;
  trace_id : string;
  service_name : string;
  operation : string;
  provider : string option;
  model : string option;
  status : string;
  start_time_ns : int;
  duration_ms : float option;
  is_running : bool;
  finish_reason : string option;
  session_id : string option;
  function_id : string option;
  user_id : string option;
  tool_call_count : int;
  usage : token_usage;
  prompt_preview : string option;
  response_preview : string option;
}

type ai_tool_call = {
  tool_name : string;
  tool_span_id : string option;
  tool_status : string;
  tool_duration_ms : float option;
  tool_arguments : string option;
  tool_result : string option;
}

type ai_prompt = { messages : Yojson.Safe.t list; raw : string option }

type ai_timing = {
  time_to_first_chunk_ms : float option;
  time_to_finish_ms : float option;
  output_tokens_per_second : float option;
}

type ai_call_detail = {
  call : ai_call;
  prompt : ai_prompt;
  response_text : string option;
  response_raw : string option;
  tool_calls : ai_tool_call list;
  tools : Yojson.Safe.t list;
  provider_metadata : Yojson.Safe.t option;
  timing : ai_timing;
}

type prune_report = {
  pruned_at_ms : int;
  traces : int;
  spans : int;
  logs : int;
  metric_points : int;
  size_cap_triggered : bool;
}

type retention_stats = {
  traces_ttl_hours : int;
  logs_ttl_hours : int;
  metrics_ttl_hours : int;
  prune_interval_seconds : int;
  max_db_size_mb : int;
  live_bytes : int;
  last_prune : prune_report option;
}

type stats = {
  spans : int;
  logs : int;
  metric_points : int;
  traces : int;
  services : int;
  retention : retention_stats;
}

type stat_item = {
  group : string;
  value : float;
  count : int;
}

type facet_item = {
  value : string;
  count : int;
}

type window = { start_ms : int option }

type cursor_position = { sort_key_ns : int; tie_breaker : string }

let window_all = { start_ms = None }
let window_lookback ~now_ms ~ms = { start_ms = Some (now_ms - ms) }

let option_string name = function
  | None -> []
  | Some value -> [ (name, `String value) ]

let option_int name = function
  | None -> []
  | Some value -> [ (name, `Int value) ]

let attr_string_value = function
  | `String value -> value
  | `Int value -> string_of_int value
  | `Intlit value -> value
  | `Float value -> string_of_float value
  | `Bool value -> string_of_bool value
  | `Null -> ""
  | value -> Yojson.Safe.to_string value

(* A span with no end time, or an end before its start, has not finished
   (tree-78hm). *)
let span_is_running (span : span) =
  span.end_time_ns = 0 || span.end_time_ns < span.start_time_ns

let span_kind_to_string = function
  | Internal -> "internal" | Server -> "server" | Client -> "client"
  | Producer -> "producer" | Consumer -> "consumer"

let span_kind_of_string = function
  | "internal" -> Some Internal | "server" -> Some Server
  | "client" -> Some Client | "producer" -> Some Producer
  | "consumer" -> Some Consumer | _ -> None

let span_status_to_string = function
  | Unset -> "unset" | Ok -> "ok" | Error -> "error"

let span_status_of_string = function
  | "unset" -> Some Unset | "ok" -> Some Ok | "error" -> Some Error
  | _ -> None

let milliseconds ns = float_of_int ns /. 1_000_000.
let nano_fields prefix ns =
  [ (prefix ^ "Ms", `Float (milliseconds ns));
    (prefix ^ "UnixNano", `String (string_of_int ns)) ]

let attrs_to_json attrs = `Assoc attrs

let attrs_json_string attrs = Yojson.Safe.to_string (attrs_to_json attrs)

let event_to_json (event : span_event) =
  `Assoc
    [
      ("name", `String event.name);
      ("timestampMs", `Float (milliseconds event.timestamp_ns));
      ("timestampUnixNano", `String (string_of_int event.timestamp_ns));
      ("attributes", attrs_to_json event.attributes);
    ]

let span_to_json (span : span) =
  `Assoc
    ([
       ("traceId", `String span.trace_id);
       ("spanId", `String span.span_id);
       ("serviceName", `String span.service_name);
       ("operationName", `String span.operation_name);
       ("startTimeMs", `Float (milliseconds span.start_time_ns));
       ("startTimeUnixNano", `String (string_of_int span.start_time_ns));
       ("endTimeMs", `Float (milliseconds span.end_time_ns));
       ("endTimeUnixNano", `String (string_of_int span.end_time_ns));
       ( "durationMs",
         if span_is_running span then `Null else `Float span.duration_ms );
       ("isRunning", `Bool (span_is_running span));
       ("status", `String (span_status_to_string span.status));
       ("links", `List (List.map (fun (link : span_link) -> `Assoc [ ("traceId", `String link.trace_id); ("spanId", `String link.span_id); ("attributes", attrs_to_json link.attributes) ]) span.links));
       ("attributes", attrs_to_json span.attributes);
       ("resource", attrs_to_json span.resource);
       ("events", `List (List.map event_to_json span.events));
     ]
    @ option_string "parentSpanId" span.parent_span_id
    @ option_string "scopeName" span.scope_name
    @ (match span.kind with None -> [ ("kind", `Null) ] | Some kind -> [ ("kind", `String (span_kind_to_string kind)) ])
    @ option_string "statusMessage" span.status_message)

let span_node_to_json (node : span_node) =
  match span_to_json node.span with
  | `Assoc fields ->
      `Assoc
        (fields
        @ [
            ("depth", `Int node.depth);
            ( "parentOperationName",
              match node.parent_operation_name with
              | None -> `Null
              | Some name -> `String name );
            ("rootOperationName", `String node.root_operation_name);
            ( "warnings",
              `List (List.map (fun warning -> `String warning) node.warnings) );
          ])
  | json -> json

let log_to_json (log : log_record) =
  `Assoc
    ([
       ("id", `String log.id);
       ("serviceName", `String log.service_name);
       ("severityText", `String log.severity_text);
       ("timestampMs", `Float (milliseconds log.timestamp_ns));
       ("timestampUnixNano", `String (string_of_int log.timestamp_ns));
       ("body", `String log.body);
       ("attributes", attrs_to_json log.attributes);
       ("resource", attrs_to_json log.resource);
     ]
    @ option_string "traceId" log.trace_id
    @ option_string "spanId" log.span_id
    @ option_string "scopeName" log.scope_name
    @ option_int "severityNumber" log.severity_number
    @ (match log.observed_timestamp_ns with None -> [] | Some ns -> nano_fields "observedTimestamp" ns))

let metric_point_to_json (point : metric_point) =
  `Assoc
    ([
       ("serviceName", `String point.service_name);
       ("name", `String point.name);
       ("kind", `String point.kind);
       ("timestampMs", `Float (milliseconds point.timestamp_ns));
       ("timestampUnixNano", `String (string_of_int point.timestamp_ns));
       ("value", `String point.value);
       ("attributes", attrs_to_json point.attributes);
       ("resource", attrs_to_json point.resource);
       ("raw", point.raw_json);
     ]
    @ option_string "scopeName" point.scope_name
    @ option_string "description" point.description
    @ option_string "unit" point.unit_
    @ (match point.start_time_ns with None -> [] | Some ns -> nano_fields "startTime" ns))

let trace_summary_to_json (summary : trace_summary) =
  `Assoc
    [
      ("traceId", `String summary.trace_id);
      ("serviceName", `String summary.service_name);
      ("rootOperationName", `String summary.root_operation_name);
      ("startedAtMs", `Float (milliseconds summary.started_at_ns));
      ("startedAtUnixNano", `String (string_of_int summary.started_at_ns));
      ("endedAtMs", `Float (milliseconds summary.ended_at_ns));
      ("endedAtUnixNano", `String (string_of_int summary.ended_at_ns));
      ("durationMs", `Float summary.duration_ms);
      ("spanCount", `Int summary.span_count);
      ("errorCount", `Int summary.error_count);
      ("isRunning", `Bool summary.is_running);
      ("warningCount", `Int summary.warning_count);
    ]

let trace_to_json (trace : trace) =
  `Assoc
    [
      ("summary", trace_summary_to_json trace.summary);
      ("spans", `List (List.map span_node_to_json trace.spans));
      ("logs", `List (List.map log_to_json trace.logs));
      ( "warnings",
        `List (List.map (fun warning -> `String warning) trace.warnings) );
    ]

let optional_string name = function
  | None -> (name, `Null)
  | Some value -> (name, `String value)

let optional_int name = function
  | None -> (name, `Null)
  | Some value -> (name, `Int value)

let optional_float name = function
  | None -> (name, `Null)
  | Some value -> (name, `Float value)

let token_usage_to_json (usage : token_usage) =
  `Assoc
    [
      optional_int "inputTokens" usage.input_tokens;
      optional_int "outputTokens" usage.output_tokens;
      optional_int "totalTokens" usage.total_tokens;
      optional_int "cachedInputTokens" usage.cached_input_tokens;
      optional_int "reasoningTokens" usage.reasoning_tokens;
    ]

let ai_call_to_json (call : ai_call) =
  `Assoc
    [
      ("spanId", `String call.span_id);
      ("traceId", `String call.trace_id);
      ("serviceName", `String call.service_name);
      ("operation", `String call.operation);
      optional_string "provider" call.provider;
      optional_string "model" call.model;
      ("status", `String call.status);
      ("startTimeMs", `Float (milliseconds call.start_time_ns));
      ("startTimeUnixNano", `String (string_of_int call.start_time_ns));
      optional_float "durationMs" call.duration_ms;
      ("isRunning", `Bool call.is_running);
      optional_string "finishReason" call.finish_reason;
      optional_string "sessionId" call.session_id;
      optional_string "functionId" call.function_id;
      optional_string "userId" call.user_id;
      ("toolCallCount", `Int call.tool_call_count);
      ("usage", token_usage_to_json call.usage);
      optional_string "promptPreview" call.prompt_preview;
      optional_string "responsePreview" call.response_preview;
    ]

let ai_tool_call_to_json (call : ai_tool_call) =
  `Assoc
    [
      ("name", `String call.tool_name);
      optional_string "spanId" call.tool_span_id;
      ("status", `String call.tool_status);
      optional_float "durationMs" call.tool_duration_ms;
      optional_string "arguments" call.tool_arguments;
      optional_string "result" call.tool_result;
    ]

let ai_timing_to_json (timing : ai_timing) =
  `Assoc
    [
      optional_float "timeToFirstChunkMs" timing.time_to_first_chunk_ms;
      optional_float "timeToFinishMs" timing.time_to_finish_ms;
      optional_float "outputTokensPerSecond" timing.output_tokens_per_second;
    ]

let ai_call_detail_to_json (detail : ai_call_detail) =
  `Assoc
    [
      ("call", ai_call_to_json detail.call);
      ( "prompt",
        `Assoc
          [
            ("messages", `List detail.prompt.messages);
            optional_string "raw" detail.prompt.raw;
          ] );
      ( "response",
        `Assoc
          [
            optional_string "text" detail.response_text;
            optional_string "raw" detail.response_raw;
          ] );
      ("toolCalls", `List (List.map ai_tool_call_to_json detail.tool_calls));
      ("tools", `List detail.tools);
      ( "providerMetadata",
        match detail.provider_metadata with None -> `Null | Some json -> json );
      ("timing", ai_timing_to_json detail.timing);
    ]

let prune_report_to_json (report : prune_report) =
  `Assoc
    [
      ("prunedAtMs", `Int report.pruned_at_ms);
      ("traces", `Int report.traces);
      ("spans", `Int report.spans);
      ("logs", `Int report.logs);
      ("metricPoints", `Int report.metric_points);
      ("sizeCapTriggered", `Bool report.size_cap_triggered);
    ]

let retention_stats_to_json (retention : retention_stats) =
  `Assoc
    [
      ("tracesTtlHours", `Int retention.traces_ttl_hours);
      ("logsTtlHours", `Int retention.logs_ttl_hours);
      ("metricsTtlHours", `Int retention.metrics_ttl_hours);
      ("pruneIntervalSeconds", `Int retention.prune_interval_seconds);
      ("maxDbSizeMb", `Int retention.max_db_size_mb);
      ("liveBytes", `Int retention.live_bytes);
      ( "lastPrune",
        match retention.last_prune with
        | None -> `Null
        | Some report -> prune_report_to_json report );
    ]

let stats_to_json (stats : stats) =
  `Assoc
    [
      ("spans", `Int stats.spans);
      ("logs", `Int stats.logs);
      ("metricPoints", `Int stats.metric_points);
      ("traces", `Int stats.traces);
      ("services", `Int stats.services);
      ("retention", retention_stats_to_json stats.retention);
    ]

let stat_item_to_json (item : stat_item) =
  `Assoc
    [
      ("group", `String item.group);
      ("value", `Float item.value);
      ("count", `Int item.count);
    ]

let facet_item_to_json (item : facet_item) =
  `Assoc [ ("value", `String item.value); ("count", `Int item.count) ]
