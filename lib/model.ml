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
}

type trace = {
  summary : trace_summary;
  spans : span list;
  logs : log_record list;
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
       ("durationMs", `Float span.duration_ms);
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
    ]

let trace_to_json (trace : trace) =
  `Assoc
    [
      ("summary", trace_summary_to_json trace.summary);
      ("spans", `List (List.map span_to_json trace.spans));
      ("logs", `List (List.map log_to_json trace.logs));
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
