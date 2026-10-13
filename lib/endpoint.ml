(* One declaration per endpoint. The HTTP router, the [/endpoints] inventory,
   and the OpenAPI 3.1 document are all rendered from this list, and the query
   parser validates every request against its declaration, so documentation
   cannot drift from behavior (desc-iduq, desc-de6o, desc-dmuw).

   The allowed-value lists below are the single source for both the
   declarations and the handler errors, so a documented value set and an
   enforced one cannot diverge. *)

type method_ = Get | Post

let method_to_string = function Get -> "GET" | Post -> "POST"

let method_to_lowercase = function Get -> "get" | Post -> "post"

type location = Query | Path
(** Query parameters are matched against the request query string; path
    parameters are matched by the router template. *)

type kind = String | Integer | Number

let kind_to_string = function
  | String -> "string"
  | Integer -> "integer"
  | Number -> "number"

type param = {
  name : string;
  location : location;
  kind : kind;
  default : string option;
  allowed : string list;
  required : bool;
  minimum : float option;
  maximum : float option;
  dynamic : bool;
  description : string;
}
(** One declared parameter. [dynamic] marks a prefix such as [attr.<key>]:
    every query key with that prefix is accepted. [allowed] is the documented
    value set; an empty list means free text. *)

type response = {
  status : int;
  description : string;
  content_type : string;
  schema : Yojson.Safe.t;
}
(** One declared response. [schema] is a JSON Schema fragment and
    [content_type] is the response body media type. *)

type t = {
  id : string;
  method_ : method_;
  path : string;
  summary : string;
  description : string;
  group : string;
  params : param list;
  responses : response list;
  request_body : string option;
}

let param ?(location = Query) ?default ?(allowed = []) ?(required = false)
    ?minimum ?maximum ?(dynamic = false) name kind description =
  {
    name;
    location;
    kind;
    default;
    allowed;
    required;
    minimum;
    maximum;
    dynamic;
    description;
  }

(* The allowed-value catalog shared by the declarations and the handlers. *)

let trace_agg = [ "count"; "avg_duration"; "p95_duration"; "error_rate" ]
let log_agg = [ "count" ]
let log_group_by = [ "service"; "severity"; "scope"; "attr.<key>" ]

let severity_levels = [ "trace"; "debug"; "info"; "warn"; "error"; "fatal" ]
let facet_types = [ "traces"; "logs" ]
let service_signals = [ "metrics" ]
let span_statuses = [ "ok"; "error"; "unset" ]

let allowed_values name values =
  Printf.sprintf "%s must be one of %s" name (String.concat ", " values)

(* Parameter catalog ---------------------------------------------------- *)

let lookback ?(default = List_policy.list_lookback) () =
  param ~default "lookback" String
    (Printf.sprintf
       "Relative time window: a positive integer followed by m, h, or d (15m, \
        2h, 1d), or all for the whole retained history. The window applies to \
        the event timestamp of each signal (span start, log timestamp, metric \
        timestamp), not to ingestion time. Defaults to %s."
       default)

let limit ?(default = List_policy.default_list_limit) () =
  param ~default:(string_of_int default) ~minimum:1. ~maximum:10000. "limit"
    Integer
    (Printf.sprintf "Maximum rows in the response, 1 to 10000. Defaults to %d."
       default)

let cursor =
  param "cursor" String
    "Opaque nextCursor value from the previous page of the same endpoint. \
     Later pages reuse the window resolved for page one, so paging stays \
     stable while new data arrives."

let service =
  param "service" String
    "Exact service.name filter. On traces it matches any service that \
     participated in the trace; the summary still shows the root service."

let attributes =
  [
    param ~dynamic:true "attr.<key>" String
      "Exact attribute filter: any query key with this prefix, for example \
       attr.http.method=GET. Values compare as their string form.";
    param ~dynamic:true "attrContains.<key>" String
      "Literal, case-insensitive substring of the string form of an attribute \
       value, for example attrContains.debug.label=cache.";
  ]

let min_duration =
  param ~minimum:0. "minDurationMs" Number
    "Only rows at least this many milliseconds long. Nonnegative."

let status =
  param ~allowed:span_statuses "status" String
    "ok or error. Trace status describes the whole trace: error means at \
     least one span failed, ok means none failed. A span or AI call whose own \
     status is unset also matches status=unset."

let operation =
  param "operation" String
    "Case-insensitive substring of the span operation name."

let min_severity =
  param ~allowed:severity_levels "minSeverity" String
    "Minimum OTLP severity (trace, debug, info, warn, error, fatal). Compares \
     severity numbers, falling back to severity text when no number is \
     present."

let severity =
  param "severity" String "Exact severity text, compared ignoring case."

let body_param name =
  param name String
    "Literal, case-insensitive substring of the log body. %, _, and backslash \
     are characters, not wildcards."

let group_by_traces =
  param
    ~required:true
    ~allowed:[ "service"; "operation"; "status"; "attr.<key>" ]
    "groupBy" String
    "Group key: service, operation, status, or attr.<key> for an attribute \
     value."

let group_by_logs =
  param ~required:true ~allowed:log_group_by "groupBy" String
    "Group key: service, severity, scope, or attr.<key> for an attribute \
     value."

let agg ?(required = true) name values =
  param ~required ~allowed:values name String
    (Printf.sprintf "Aggregate: %s." (String.concat ", " values))

(* JSON Schema helpers -------------------------------------------------- *)

let schema_object ?(required = []) ?(additional = false) properties =
  `Assoc
    ([
       ("type", `String "object");
       ("properties", `Assoc properties);
     ]
    @ (if required = [] then []
       else
         [ ("required", `List (List.map (fun name -> `String name) required)) ])
    @ (if additional then [ ("additionalProperties", `Bool true) ] else []))

let schema_array items = `Assoc [ ("type", `String "array"); ("items", items) ]

let schema_string = `Assoc [ ("type", `String "string") ]
let schema_number = `Assoc [ ("type", `String "number") ]
let schema_integer = `Assoc [ ("type", `String "integer") ]
let schema_boolean = `Assoc [ ("type", `String "boolean") ]
let schema_any = `Assoc []

let schema_nullable schema =
  match schema with
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
             if String.equal name "type" then
               match value with
               | `String name -> (name, `List [ `String name; `String "null" ])
               | value -> (name, value)
             else (name, value))
           fields)
  | schema -> schema

let schema_enum values =
  `Assoc
    [
      ("type", `String "string");
      ("enum", `List (List.map (fun value -> `String value) values));
    ]

let schema_attrs =
  `Assoc
    [
      ("type", `String "object");
      ( "description",
        `String
          "OpenTelemetry attributes as JSON values; each value keeps its type."
      );
      ("additionalProperties", `Bool true);
    ]

let schema_error =
  schema_object ~additional:true
    [
      ("error", schema_string);
      ("message", schema_string);
      ("available", schema_array schema_string);
    ]

let schema_meta ?(cursor = false) () =
  schema_object
    ([
       ("limit", schema_integer);
       ("lookback", schema_string);
       ("returned", schema_integer);
       ("truncated", schema_boolean);
     ]
    @ if cursor then [ ("nextCursor", schema_string) ] else [])

let span_properties =
  [
    ("traceId", schema_string);
    ("spanId", schema_string);
    ("parentSpanId", schema_nullable schema_string);
    ("serviceName", schema_string);
    ("scopeName", schema_nullable schema_string);
    ("operationName", schema_string);
    ( "kind",
      schema_nullable
        (schema_enum [ "internal"; "server"; "client"; "producer"; "consumer" ])
    );
    ("startTimeMs", schema_number);
    ("startTimeUnixNano", schema_string);
    ("endTimeMs", schema_number);
    ("endTimeUnixNano", schema_string);
    ("durationMs", schema_nullable schema_number);
    ("isRunning", schema_boolean);
    ("status", schema_enum [ "unset"; "ok"; "error" ]);
    ("statusMessage", schema_nullable schema_string);
    ("attributes", schema_attrs);
    ("resource", schema_attrs);
    ( "events",
      schema_array
        (schema_object [
           ("name", schema_string);
           ("timestampMs", schema_number);
           ("timestampUnixNano", schema_string);
           ("attributes", schema_attrs);
         ]) );
    ( "links",
      schema_array
        (schema_object [
           ("traceId", schema_string);
           ("spanId", schema_string);
           ("attributes", schema_attrs);
         ]) );
  ]

let span_node_properties =
  span_properties
  @ [
      ("depth", schema_integer);
      ("parentOperationName", schema_nullable schema_string);
      ("rootOperationName", schema_string);
      ("warnings", schema_array schema_string);
    ]

let log_properties =
  [
    ("id", schema_string);
    ("traceId", schema_nullable schema_string);
    ("spanId", schema_nullable schema_string);
    ("serviceName", schema_string);
    ("scopeName", schema_nullable schema_string);
    ("severityText", schema_string);
    ("severityNumber", schema_nullable schema_integer);
    ("timestampMs", schema_number);
    ("timestampUnixNano", schema_string);
    ("observedTimestampMs", schema_number);
    ("observedTimestampUnixNano", schema_string);
    ("body", schema_string);
    ("attributes", schema_attrs);
    ("resource", schema_attrs);
  ]

let metric_point_properties =
  [
    ("serviceName", schema_string);
    ("scopeName", schema_nullable schema_string);
    ("name", schema_string);
    ("description", schema_nullable schema_string);
    ("unit", schema_nullable schema_string);
    ("kind", schema_string);
    ("startTimeMs", schema_number);
    ("startTimeUnixNano", schema_string);
    ("timestampMs", schema_number);
    ("timestampUnixNano", schema_string);
    ("value", schema_string);
    ("attributes", schema_attrs);
    ("resource", schema_attrs);
    ("raw", schema_any);
  ]

let trace_summary_properties =
  [
    ("traceId", schema_string);
    ("serviceName", schema_string);
    ("rootOperationName", schema_string);
    ("startedAtMs", schema_number);
    ("startedAtUnixNano", schema_string);
    ("endedAtMs", schema_number);
    ("endedAtUnixNano", schema_string);
    ("durationMs", schema_number);
    ("spanCount", schema_integer);
    ("errorCount", schema_integer);
    ("isRunning", schema_boolean);
    ("warningCount", schema_integer);
    ("droppedSpanCount", schema_integer);
  ]

let stat_item_properties =
  [
    ("group", schema_string);
    ("value", schema_number);
    ("count", schema_integer);
  ]

let facet_item_properties =
  [ ("value", schema_string); ("count", schema_integer) ]

let storage_properties =
  [
    ("maxBytes", schema_integer);
    ("segmentBytes", schema_integer);
    ("usedBytes", schema_integer);
    ("oldestDataSinceMs", schema_nullable schema_integer);
    ( "segments",
      schema_array
        (schema_object [
           ("slot", schema_integer);
           ("sequence", schema_integer);
           ("bytes", schema_integer);
           ("startedAtMs", schema_integer);
           ("active", schema_boolean);
         ]) );
    ("ingestFailures", schema_integer);
    ( "lastIngestFailure",
      schema_nullable
        (schema_object [
           ("failedAtMs", schema_integer);
           ("message", schema_string);
         ]) );
  ]

let health_properties =
  [
    ("ok", schema_boolean);
    ("pid", schema_integer);
    ("stateDir", schema_string);
    ("dataDir", schema_string);
    ("baseUrl", schema_string);
    ("version", schema_string);
    ("startedAt", schema_string);
    ("uptimeSeconds", schema_number);
  ]

let ready_properties =
  health_properties
  @ [ ("ready", schema_boolean); ("store", schema_string) ]

let page_schema collection item_properties =
  schema_object
    [
      (collection, schema_array (schema_object item_properties));
      ("meta", schema_meta ~cursor:true ());
    ]

let summary_schema collection item_properties =
  schema_object
    [
      (collection, schema_array (schema_object item_properties));
      ("meta", schema_meta ());
    ]

let json_body ?(status = 200) ?(description = "OK") schema =
  { status; description; content_type = "application/json"; schema }

let invalid_query_response =
  json_body ~status:400 ~description:"Invalid query parameter" schema_error

let not_found_response =
  json_body ~status:404
    ~description:
    "Not found: the drilldown target does not exist, or the AI call detail \
     was asked for a tool execution or a nested provider span"
    schema_error

let store_error_response = json_body ~status:500 ~description:"Store error" schema_error

let text_response ?(status = 200) content_type description =
  { status; description; content_type; schema = schema_string }

let query_responses schema =
  [ json_body schema; invalid_query_response; store_error_response ]

(* Endpoint declarations ------------------------------------------------- *)

let path_param name description =
  param ~location:Path ~required:true name String description

let trace_id_param = path_param "traceId" "32-character hex trace id."
let span_id_param = path_param "spanId" "16-character hex span id."
let docs_name_param = path_param "name" "Guide name from GET /docs."

let query_endpoint ?(group = "query") id path summary description params
    responses =
  {
    id;
    method_ = Get;
    path;
    summary;
    description;
    group;
    params;
    responses;
    request_body = None;
  }

let ingest_endpoint id path summary description =
  {
    id;
    method_ = Post;
    path;
    summary;
    description;
    group = "ingest";
    params = [];
    responses =
      [
        json_body ~description:"OTLP export response: {} or partialSuccess" schema_any;
        json_body ~status:400 ~description:"Malformed OTLP JSON (code 3)" schema_any;
        json_body ~status:413 ~description:"OTLP JSON body exceeds the size limit" schema_any;
        json_body ~status:415 ~description:"Only OTLP JSON is supported" schema_any;
        json_body ~status:503 ~description:"Store unavailable; retry after one second"
          schema_any;
      ];
    request_body = Some "application/json";
  }

let trace_search_params =
  [
    lookback ();
    limit ();
    cursor;
    service;
    operation;
    status;
    min_duration;
  ]
  @ attributes

let trace_stats_params =
  [
    lookback ~default:List_policy.history_lookback ();
    limit ~default:List_policy.default_stats_limit ();
    group_by_traces;
    agg "agg" trace_agg;
    service;
    operation;
    status;
    min_duration;
  ]
  @ attributes

let span_search_params =
  [
    lookback ();
    limit ();
    cursor;
    service;
    param "traceId" String "Only spans of this trace id.";
    operation;
    param "parentOperation" String
      "Case-insensitive substring of the parent span operation name; the \
       parent must belong to the same trace.";
    status;
    min_duration;
  ]
  @ attributes

let log_list_params =
  [
    lookback ();
    limit ();
    cursor;
    service;
    severity;
    body_param "contains";
    min_severity;
  ]
  @ attributes

let log_search_params =
  [
    lookback ();
    limit ();
    cursor;
    service;
    param "traceId" String "Only logs correlated with this trace id.";
    param "spanId" String "Only logs correlated with this span id.";
    severity;
    body_param "body";
    body_param "contains";
    min_severity;
  ]
  @ attributes

let log_stats_params =
  [
    lookback ~default:List_policy.history_lookback ();
    limit ~default:List_policy.default_stats_limit ();
    group_by_logs;
    agg ~required:false "agg" log_agg;
    service;
    param "traceId" String "Only logs correlated with this trace id.";
    param "spanId" String "Only logs correlated with this span id.";
    severity;
    body_param "body";
    body_param "contains";
    min_severity;
  ]
  @ attributes

let all =
  [
    query_endpoint ~group:"discovery" "root" "/" "Server banner"
      "Plain-text endpoint list and the configured state paths." []
      [ text_response "text/plain" "Endpoint list and state paths" ];
    query_endpoint ~group:"discovery" "health" "/health"
      "Liveness and build identity"
      "Reports ok, the process id, the configured state paths, the build \
       version, the ISO 8601 start time, and the uptime."
      []
      [ json_body (schema_object ~required:[ "ok"; "version" ] health_properties) ];
    query_endpoint ~group:"discovery" "healthz" "/healthz" "Liveness probe"
      "Alias of GET /health for probe conventions that use /healthz." []
      [ json_body (schema_object health_properties) ];
    query_endpoint ~group:"discovery" "ready" "/ready" "Readiness probe"
      "Reports whether the server accepts queries and the store answered: 200 \
       with ready=true, or 503 with ready=false and the store error."
      []
      [
        json_body (schema_object ready_properties);
        json_body ~status:503 ~description:"The store did not answer; not ready" schema_error;
      ];
    query_endpoint ~group:"discovery" "status" "/status" "Server and store state"
      "The identity of /health plus the storage section: the budget, the \
       bytes in use, the segments with data, the start time of the oldest \
       data, and the failed ingest batches with the last error."
      []
      [
        json_body
          (schema_object
             (health_properties @ [ ("storage", schema_object storage_properties) ]));
        store_error_response;
      ];
    query_endpoint ~group:"discovery" "instructions" "/instructions"
      "OTLP setup instructions"
      "Copy-paste exporter configuration, the query surface, and pointers to \
       the guides and the OpenAPI document."
      [] [ text_response "text/plain" "Setup instructions" ];
    query_endpoint ~group:"discovery" "endpoints" "/endpoints"
      "Endpoint inventory"
      "Machine-readable inventory of every endpoint with its method, path, \
       parameters, responses, and alias."
      []
      [
        json_body
          (schema_object [
             ("baseUrl", schema_string);
             ("exporterUrl", schema_string);
             ("logsExporterUrl", schema_string);
             ("metricsExporterUrl", schema_string);
             ("dataDir", schema_string);
             ( "aliasPolicy",
               schema_object [
                 ("prefix", schema_string);
                 ("description", schema_string);
               ] );
             ("endpoints", schema_array schema_any);
           ]);
      ];
    query_endpoint ~group:"discovery" "openapi" "/openapi.json"
      "OpenAPI 3.1 document"
      "The complete API description, generated from the same declarations the \
       server uses to parse requests."
      [] [ json_body schema_any ];
    query_endpoint ~group:"docs" "docs_index" "/docs" "Documentation index"
      "Lists the available guides with their name, title, and path. Fetch one \
       guide with GET /docs/{name}."
      []
      [
        json_body
          (schema_object [
             ( "guides",
               schema_array
                 (schema_object [
                    ("name", schema_string);
                    ("title", schema_string);
                    ("path", schema_string);
                  ]) );
           ]);
      ];
    query_endpoint ~group:"docs" "docs_get" "/docs/{name}"
      "One guide as Markdown"
      "Returns one guide as Markdown. An unknown name is a 404 that lists the \
       available names."
      [ docs_name_param ]
      [ text_response "text/markdown" "Guide body"; not_found_response ];
    ingest_endpoint "ingest_traces" "/v1/traces" "OTLP/HTTP JSON trace ingest"
      "Accepts an OTLP/HTTP JSON ExportTraceServiceRequest. An empty export \
       returns {}. Individually rejected spans return 200 with a \
       partialSuccess object.";
    ingest_endpoint "ingest_logs" "/v1/logs" "OTLP/HTTP JSON log ingest"
      "Accepts an OTLP/HTTP JSON ExportLogsServiceRequest. Rejected records \
       use partialSuccess.rejectedLogRecords.";
    ingest_endpoint "ingest_metrics" "/v1/metrics" "OTLP/HTTP JSON metric ingest"
      "Accepts an OTLP/HTTP JSON ExportMetricsServiceRequest. Rejected points \
       use partialSuccess.rejectedDataPoints.";
    query_endpoint "services" "/services" "Services that emitted telemetry"
      "Services seen in span, log, or (with signal=metrics) metric data over \
       the window."
      [
        lookback ~default:List_policy.history_lookback ();
        param ~allowed:service_signals "signal" String
          "Set to metrics to also include services that only emitted metrics.";
      ]
      [
        json_body
          (schema_object [
             ("services", schema_array schema_string);
             ( "meta",
               schema_object [
                 ("lookback", schema_string);
                 ("returned", schema_integer);
               ] );
           ]);
        invalid_query_response;
        store_error_response;
      ];
    query_endpoint "traces" "/traces" "Recent trace summaries"
      "Newest-first trace summaries over the window, with keyset paging."
      [ lookback (); limit (); cursor; service ]
      (query_responses (page_schema "traces" trace_summary_properties));
    query_endpoint "trace_search" "/traces/search" "Search trace summaries"
      "Searches traces by service, operation, status, attribute, and duration. \
       Every filter must match inside the trace."
      trace_search_params
      (query_responses (page_schema "traces" trace_summary_properties));
    query_endpoint "trace_stats" "/traces/stats" "Aggregate trace statistics"
      "Exact SQL aggregates over the whole window, grouped by service, \
       operation, status, or an attribute value."
      trace_stats_params
      (query_responses (summary_schema "stats" stat_item_properties));
    query_endpoint "trace" "/traces/{traceId}" "One trace as a tree"
      "The trace summary, the spans in depth-first tree order with depth and \
       parent annotations, the correlated logs, and the trace warnings."
      [ trace_id_param ]
      [
        json_body
          (schema_object [
             ("summary", schema_object trace_summary_properties);
             ("spans", schema_array (schema_object span_node_properties));
             ("logs", schema_array (schema_object log_properties));
             ("warnings", schema_array schema_string);
           ]);
        not_found_response;
        store_error_response;
      ];
    query_endpoint "trace_spans" "/traces/{traceId}/spans" "Spans of one trace"
      "The same depth-first tree order, annotations, and cursor as the trace \
       detail, paged."
      [ trace_id_param; lookback (); limit (); cursor ]
      (query_responses (page_schema "spans" span_node_properties));
    query_endpoint "trace_logs" "/traces/{traceId}/logs"
      "Logs correlated with one trace"
      "Log records whose trace id is this trace, newest first."
      ([ trace_id_param; lookback (); limit (); cursor ] @ attributes)
      (query_responses (page_schema "logs" log_properties));
    query_endpoint "span_search" "/spans/search" "Search spans"
      "Searches spans by service, trace, operation, parent operation, status, \
       attribute, and duration. A parent must belong to the same trace."
      span_search_params
      (query_responses (page_schema "spans" span_properties));
    query_endpoint "span" "/spans/{spanId}" "One span"
      "The span plus its place in the trace tree: depth, parent operation, \
       root operation, and its own warnings."
      [ span_id_param ]
      [
        json_body (schema_object span_node_properties);
        not_found_response;
        store_error_response;
      ];
    query_endpoint "span_logs" "/spans/{spanId}/logs"
      "Logs correlated with one span"
      "Log records whose span id is this span, newest first."
      ([ span_id_param; lookback (); limit (); cursor ] @ attributes)
      (query_responses (page_schema "logs" log_properties));
    query_endpoint "logs" "/logs" "Recent logs"
      "Newest-first log records over the window, with keyset paging on the \
       stable log id."
      log_list_params (query_responses (page_schema "logs" log_properties));
    query_endpoint "log_search" "/logs/search" "Search logs"
      "Searches logs by service, trace/span correlation, severity, body \
       substring, and attributes."
      log_search_params (query_responses (page_schema "logs" log_properties));
    query_endpoint "log_stats" "/logs/stats" "Aggregate log counts"
      "Exact counts over the whole window, grouped by service, severity, \
       scope, or an attribute value."
      log_stats_params
      (query_responses (summary_schema "stats" stat_item_properties));
    query_endpoint "metrics" "/metrics" "Recent metric points"
      "Newest-first metric points over the window, with keyset paging."
      [
        lookback ();
        limit ();
        cursor;
        service;
        param "name" String "Exact metric name.";
      ]
      (query_responses (page_schema "metrics" metric_point_properties));
    query_endpoint "facets" "/facets" "Facet values and counts"
      "Distinct facet values with their counts over the window. Traces: \
       service, operation, status, attribute_keys, attribute_values. Logs: \
       service, severity, scope, attribute_keys, attribute_values. \
       attribute_values needs key."
      [
        lookback ~default:List_policy.history_lookback ();
        limit ~default:List_policy.default_stats_limit ();
        param ~required:true ~allowed:facet_types "type" String "traces or logs.";
        param
          ~required:true
          ~allowed:
            [
              "service";
              "operation";
              "status";
              "severity";
              "scope";
              "attribute_keys";
              "attribute_values";
            ]
          "field" String
          "Facet field. service, operation, status, attribute_keys, and \
           attribute_values exist for traces; service, severity, scope, \
           attribute_keys, and attribute_values exist for logs.";
        param "key" String "Attribute key for attribute_values facets.";
        service;
      ]
      (query_responses (summary_schema "facets" facet_item_properties));
    query_endpoint "stats" "/stats" "Store row counts and storage"
      "Row counts over the window plus the storage section of GET /status."
      [ lookback ~default:List_policy.history_lookback () ]
      [
        json_body
          (schema_object [
             ("spans", schema_integer);
             ("logs", schema_integer);
             ("metricPoints", schema_integer);
             ("traces", schema_integer);
             ("services", schema_integer);
             ("storage", schema_object storage_properties);
             ("meta", schema_object [ ("lookback", schema_string) ]);
           ]);
        invalid_query_response;
        store_error_response;
      ];
  ]

let alias_prefix = "/api"

let alias_path endpoint =
  if String.equal endpoint.path "/" then alias_prefix
  else alias_prefix ^ endpoint.path

let alias_description =
  "Every declared route is also served under the /api prefix, for example \
   /api/traces is the same handler as /traces. The alias is registered for \
   every method the route accepts."

(* Query validation ----------------------------------------------------- *)

let query_params endpoint =
  List.filter (fun param -> param.location = Query) endpoint.params

(* A dynamic parameter is declared as its documented placeholder, for example
   attr.<key>; the accepted key prefix is everything before the placeholder. *)
let dynamic_prefix name =
  match String.index_opt name '<' with
  | None -> name
  | Some index -> String.sub name 0 index

let key_matches param name =
  if param.dynamic then String.starts_with ~prefix:(dynamic_prefix param.name) name
  else String.equal param.name name

let find_query_param endpoint name =
  List.find_opt (fun param -> key_matches param name) (query_params endpoint)

let unknown_parameter endpoint name =
  match query_params endpoint with
  | [] ->
      Printf.sprintf
        "unknown query parameter %s for %s %s; this endpoint takes no query \
         parameters"
        name (method_to_string endpoint.method_) endpoint.path
  | params ->
      Printf.sprintf
        "unknown query parameter %s for %s %s; supported parameters are %s" name
        (method_to_string endpoint.method_) endpoint.path
        (String.concat ", " (List.map (fun param -> param.name) params))

let is_integer text =
  match int_of_string_opt (String.trim text) with
  | Some _ -> true
  | None -> false

let is_number text =
  match float_of_string_opt (String.trim text) with
  | Some value -> Float.is_finite value
  | None -> false

let validate_param param value =
  match param.kind with
  | String -> Ok ()
  | Integer ->
      if is_integer value then Ok ()
      else Error (Printf.sprintf "%s must be an integer" param.name)
  | Number ->
      if is_number value then Ok ()
      else Error (Printf.sprintf "%s must be a finite number" param.name)

let validate_query endpoint params =
  let missing =
    List.find_opt
      (fun param ->
        param.required && (not param.dynamic) && not (List.mem_assoc param.name params))
      (query_params endpoint)
  in
  match missing with
  | Some param -> Error (param.name ^ " is required")
  | None ->
      let rec check = function
        | [] -> Ok ()
        | (name, value) :: rest -> (
            match find_query_param endpoint name with
            | None -> Error (unknown_parameter endpoint name)
            | Some param -> (
                match validate_param param value with
                | Error message -> Error message
                | Ok () -> check rest))
      in
      check params

(* Rendering ------------------------------------------------------------ *)

let fields_of = function `Assoc fields -> fields | _ -> []

(* A declared default is rendered with the parameter's own type, so an integer
   parameter never carries a string default. *)
let default_json param =
  match param.default with
  | None -> `Null
  | Some value -> (
      match param.kind with
      | Integer -> (
          match int_of_string_opt value with
          | Some number -> `Int number
          | None -> `String value)
      | Number -> (
          match float_of_string_opt value with
          | Some number -> `Float number
          | None -> `String value)
      | String -> `String value)

let param_json param =
  `Assoc
    [
      ("name", `String param.name);
      ( "in",
        `String (match param.location with Query -> "query" | Path -> "path")
      );
      ("type", `String (kind_to_string param.kind));
      ("required", `Bool param.required);
      ("dynamic", `Bool param.dynamic);
      ("default", default_json param);
      ("allowed", `List (List.map (fun value -> `String value) param.allowed));
      ( "minimum",
        match param.minimum with None -> `Null | Some value -> `Float value );
      ( "maximum",
        match param.maximum with None -> `Null | Some value -> `Float value );
      ("description", `String param.description);
    ]

let response_json response =
  `Assoc
    [
      ("status", `Int response.status);
      ("description", `String response.description);
      ("contentType", `String response.content_type);
      ("schema", response.schema);
    ]

let inventory_json endpoint =
  `Assoc
    [
      ("id", `String endpoint.id);
      ("method", `String (method_to_string endpoint.method_));
      ("path", `String endpoint.path);
      ("group", `String endpoint.group);
      ("summary", `String endpoint.summary);
      ("description", `String endpoint.description);
      ("alias", `String (alias_path endpoint));
      ( "filters",
        `List
          (List.map
             (fun param -> `String param.name)
             (query_params endpoint)) );
      ("parameters", `List (List.map param_json endpoint.params));
      ("responses", `List (List.map response_json endpoint.responses));
      ( "requestBody",
        match endpoint.request_body with
        | None -> `Null
        | Some content_type -> `Assoc [ ("contentType", `String content_type) ]
      );
    ]

let parameter_json param =
  let schema =
    `Assoc
      ([ ("type", `String (kind_to_string param.kind)) ]
      @ (match default_json param with
        | `Null -> []
        | json -> [ ("default", json) ])
      @ (match param.allowed with
        | [] -> []
        | values ->
            [ ("enum", `List (List.map (fun value -> `String value) values)) ])
      @ (match param.minimum with
        | None -> []
        | Some value -> [ ("minimum", `Float value) ])
      @
      match param.maximum with
      | None -> []
      | Some value -> [ ("maximum", `Float value) ])
  in
  `Assoc
    ([
       ("name", `String param.name);
       ( "in",
         `String (match param.location with Query -> "query" | Path -> "path")
       );
       ("required", `Bool param.required);
       ("description", `String param.description);
       ("schema", schema);
     ]
    @ if param.dynamic then [ ("x-inn-dynamic", `Bool true) ] else [])

let responses_json responses =
  `Assoc
    (List.map
       (fun response ->
         ( string_of_int response.status,
           `Assoc
             [
               ("description", `String response.description);
               ( "content",
                 `Assoc
                   [
                     ( response.content_type,
                       `Assoc [ ("schema", response.schema) ] );
                   ] );
             ] ))
       responses)

let operation_json ?alias_of endpoint =
  let prefixes =
    List.filter_map
      (fun param -> if param.dynamic then Some param.name else None)
      endpoint.params
  in
  `Assoc
    ([
       ("operationId", `String endpoint.id);
       ("summary", `String endpoint.summary);
       ("description", `String endpoint.description);
       ("tags", `List [ `String endpoint.group ]);
       ("parameters", `List (List.map parameter_json endpoint.params));
       ("responses", responses_json endpoint.responses);
       ( "x-inn-query-prefixes",
         `List (List.map (fun name -> `String name) prefixes) );
       ("x-inn-alias", `String (alias_path endpoint));
     ]
    @ (match endpoint.request_body with
      | None -> []
      | Some content_type ->
          [
            ( "requestBody",
              `Assoc
                [
                  ("required", `Bool true);
                  ( "content",
                    `Assoc
                      [
                        ( content_type,
                          `Assoc [ ("schema", schema_any) ] );
                      ] );
                ] );
          ])
    @
    match alias_of with
    | None -> []
    | Some canonical -> [ ("x-inn-alias-of", `String canonical) ])

let paths_json endpoints =
  let operations =
    List.concat_map
      (fun endpoint ->
        let method_ = method_to_lowercase endpoint.method_ in
        let canonical =
          (endpoint.path, [ (method_, `Assoc (fields_of (operation_json endpoint))) ])
        in
        [
          canonical;
          ( alias_path endpoint,
            [
              ( method_,
                `Assoc
                  (fields_of
                     (operation_json ~alias_of:endpoint.path endpoint)) );
            ] );
        ])
      endpoints
  in
  let add table (path, methods) =
    match List.assoc_opt path table with
    | None -> table @ [ (path, methods) ]
    | Some existing ->
        List.map
          (fun (name, value) ->
            if String.equal name path then (name, existing @ methods)
            else (name, value))
          table
  in
  `Assoc
    (List.map
       (fun (path, methods) -> (path, `Assoc methods))
       (List.fold_left add [] operations))

let document ~base_url endpoints =
  `Assoc
    [
      ("openapi", `String "3.1.0");
      ( "info",
        `Assoc
          [
            ("title", `String "Inn API");
            ("version", `String Version.value);
            ( "description",
              `String
                "Inn is a local OpenTelemetry collector and query service. \
                 Everything below is generated from the same endpoint \
                 declarations the server uses to parse requests." );
          ] );
      ("servers", `List [ `Assoc [ ("url", `String base_url) ] ]);
      ("paths", paths_json endpoints);
      ( "x-inn-alias-policy",
        `Assoc
          [
            ("prefix", `String alias_prefix);
            ("description", `String alias_description);
          ] );
    ]
