type attrs = (string * string) list

type span_event = {
  name : string;
  timestamp_ms : int;
  attributes : attrs;
}

type span = {
  trace_id : string;
  span_id : string;
  parent_span_id : string option;
  service_name : string;
  scope_name : string option;
  operation_name : string;
  kind : string option;
  start_time_ms : int;
  end_time_ms : int;
  duration_ms : float;
  status : string;
  status_message : string option;
  attributes : attrs;
  resource : attrs;
  events : span_event list;
}

type log_record = {
  trace_id : string option;
  span_id : string option;
  service_name : string;
  scope_name : string option;
  severity_text : string;
  severity_number : int option;
  timestamp_ms : int;
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
  start_time_ms : int option;
  timestamp_ms : int;
  value : string;
  attributes : attrs;
  resource : attrs;
  raw_json : Yojson.Safe.t;
}

type trace_summary = {
  trace_id : string;
  service_name : string;
  root_operation_name : string;
  started_at_ms : int;
  ended_at_ms : int;
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

let option_string name = function
  | None -> []
  | Some value -> [ (name, `String value) ]

let option_int name = function
  | None -> []
  | Some value -> [ (name, `Int value) ]

let attrs_to_json attrs =
  `Assoc (List.map (fun (key, value) -> (key, `String value)) attrs)

let attrs_json_string attrs = Yojson.Safe.to_string (attrs_to_json attrs)

let event_to_json (event : span_event) =
  `Assoc
    [
      ("name", `String event.name);
      ("timestampMs", `Int event.timestamp_ms);
      ("attributes", attrs_to_json event.attributes);
    ]

let span_to_json (span : span) =
  `Assoc
    ([
       ("traceId", `String span.trace_id);
       ("spanId", `String span.span_id);
       ("serviceName", `String span.service_name);
       ("operationName", `String span.operation_name);
       ("startTimeMs", `Int span.start_time_ms);
       ("endTimeMs", `Int span.end_time_ms);
       ("durationMs", `Float span.duration_ms);
       ("status", `String span.status);
       ("attributes", attrs_to_json span.attributes);
       ("resource", attrs_to_json span.resource);
       ("events", `List (List.map event_to_json span.events));
     ]
    @ option_string "parentSpanId" span.parent_span_id
    @ option_string "scopeName" span.scope_name
    @ option_string "kind" span.kind
    @ option_string "statusMessage" span.status_message)

let log_to_json (log : log_record) =
  `Assoc
    ([
       ("serviceName", `String log.service_name);
       ("severityText", `String log.severity_text);
       ("timestampMs", `Int log.timestamp_ms);
       ("body", `String log.body);
       ("attributes", attrs_to_json log.attributes);
       ("resource", attrs_to_json log.resource);
     ]
    @ option_string "traceId" log.trace_id
    @ option_string "spanId" log.span_id
    @ option_string "scopeName" log.scope_name
    @ option_int "severityNumber" log.severity_number)

let metric_point_to_json (point : metric_point) =
  `Assoc
    ([
       ("serviceName", `String point.service_name);
       ("name", `String point.name);
       ("kind", `String point.kind);
       ("timestampMs", `Int point.timestamp_ms);
       ("value", `String point.value);
       ("attributes", attrs_to_json point.attributes);
       ("resource", attrs_to_json point.resource);
       ("raw", point.raw_json);
     ]
    @ option_string "scopeName" point.scope_name
    @ option_string "description" point.description
    @ option_string "unit" point.unit_
    @ option_int "startTimeMs" point.start_time_ms)

let trace_summary_to_json (summary : trace_summary) =
  `Assoc
    [
      ("traceId", `String summary.trace_id);
      ("serviceName", `String summary.service_name);
      ("rootOperationName", `String summary.root_operation_name);
      ("startedAtMs", `Int summary.started_at_ms);
      ("endedAtMs", `Int summary.ended_at_ms);
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
