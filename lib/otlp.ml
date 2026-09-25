type 'a decoded = { items : 'a list; rejected : int; error_message : string }

type payload = {
  spans : Model.span list;
  logs : Model.log_record list;
  metric_points : Model.metric_point list;
}

let empty = { spans = []; logs = []; metric_points = [] }

let parse_json text =
  try Ok (Yojson.Safe.from_string text) with
  | Yojson.Json_error message -> Error message

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let list_member name json =
  match member name json with
  | Some (`List values) -> values
  | _ -> []

let string_member name json =
  match member name json with
  | Some (`String value) -> Some value
  | Some (`Int value) -> Some (string_of_int value)
  | Some (`Intlit value) -> Some value
  | Some (`Float value) -> Some (string_of_float value)
  | Some (`Bool value) -> Some (string_of_bool value)
  | _ -> None

let int_member name json =
  match member name json with
  | Some (`Int value) -> Some value
  | Some (`Intlit value) -> int_of_string_opt value
  | Some (`String value) -> int_of_string_opt value
  | _ -> None

let int64_of_json = function
  | `String value | `Intlit value -> Int64.of_string_opt value
  | `Int value -> Some (Int64.of_int value)
  | _ -> None

let ns_of_json json =
  match json with
  | `String value | `Intlit value -> Option.value (int_of_string_opt value) ~default:0
  | `Int value -> value
  | _ -> 0

let time_member_ns name json =
  match member name json with Some value -> ns_of_json value | None -> 0

let optional_time_member_ns name json =
  Option.map ns_of_json (member name json)

let rec any_value_to_json json =
  match json with
  | `Assoc _ -> (
      match
        ( member "stringValue" json,
          member "intValue" json,
          member "doubleValue" json,
          member "boolValue" json,
          member "bytesValue" json,
          member "arrayValue" json,
          member "kvlistValue" json )
      with
      | Some (`String value), _, _, _, _, _, _ -> `String value
      | _, Some (`String value), _, _, _, _, _ -> (match int_of_string_opt value with
          | Some number -> `Int number
          | None -> if Option.is_some (Int64.of_string_opt value) then `Intlit value else `String value)
      | _, Some (`Int value), _, _, _, _, _ -> `Int value
      | _, Some (`Intlit value), _, _, _, _, _ -> `Intlit value
      | _, _, Some (`Float value), _, _, _, _ -> `Float value
      | _, _, Some (`Int value), _, _, _, _ -> `Int value
      | _, _, Some (`String value), _, _, _, _ -> (match float_of_string_opt value with Some number -> `Float number | None -> `String value)
      | _, _, _, Some (`Bool value), _, _, _ -> `Bool value
      | _, _, _, _, Some (`String value), _, _ -> `String value
      | _, _, _, _, _, Some array_value, _ ->
          `List (List.map any_value_to_json (list_member "values" array_value))
      | _, _, _, _, _, _, Some kvlist ->
          `Assoc
            (List.filter_map
               (fun entry ->
                 match (string_member "key" entry, member "value" entry) with
                 | Some key, Some value -> Some (key, any_value_to_json value)
                 | _ -> None)
               (list_member "values" kvlist))
      | _ -> json)
  | value -> value

let any_value_to_string json = Model.attr_string_value (any_value_to_json json)

let attrs json =
  list_member "attributes" json
  |> List.filter_map (fun attr ->
         match (string_member "key" attr, member "value" attr) with
         | Some key, Some value -> Some (key, any_value_to_json value)
         | _ -> None)

let service_name resource_attrs =
  let value = match List.assoc_opt "service.name" resource_attrs with
    | Some _ as value -> value
    | None -> List.assoc_opt "service_name" resource_attrs in
  match value with
  | Some value when Model.attr_string_value value <> "" -> Model.attr_string_value value
  | _ -> "unknown"

let valid_id length value =
  String.length value = length
  && String.exists (fun c -> c <> '0') value
  && String.for_all (function
       | '0'..'9' | 'a'..'f' | 'A'..'F' -> true | _ -> false) value

let normalized_id length = function
  | Some value when valid_id length value -> Some (String.lowercase_ascii value)
  | _ -> None

let scope_name scope =
  match member "scope" scope with
  | Some scope_json -> string_member "name" scope_json
  | None -> None

let span_status span =
  match member "status" span with
  | Some status ->
      let message = string_member "message" status in
      let code = match string_member "code" status with
        | Some ("1" | "STATUS_CODE_OK") -> Model.Ok
        | Some ("2" | "STATUS_CODE_ERROR") -> Model.Error
        | _ -> Model.Unset in
      (code, message)
  | None -> (Model.Unset, None)

let span_event event =
  {
    Model.name = Option.value (string_member "name" event) ~default:"event";
    timestamp_ns = time_member_ns "timeUnixNano" event;
    attributes = attrs event;
  }

let span_link link =
  match normalized_id 32 (string_member "traceId" link),
        normalized_id 16 (string_member "spanId" link) with
  | Some trace_id, Some span_id -> Some { Model.trace_id; span_id; attributes = attrs link }
  | _ -> None

let decode_span ~resource ~service_name ~scope_name span =
  match normalized_id 32 (string_member "traceId" span),
        normalized_id 16 (string_member "spanId" span) with
  | Some trace_id, Some span_id ->
      let start_time_ns = time_member_ns "startTimeUnixNano" span in
      let end_time_ns = time_member_ns "endTimeUnixNano" span in
      let status, status_message = span_status span in
      let kind = match string_member "kind" span with
        | Some ("1" | "SPAN_KIND_INTERNAL") -> Some Model.Internal
        | Some ("2" | "SPAN_KIND_SERVER") -> Some Model.Server
        | Some ("3" | "SPAN_KIND_CLIENT") -> Some Model.Client
        | Some ("4" | "SPAN_KIND_PRODUCER") -> Some Model.Producer
        | Some ("5" | "SPAN_KIND_CONSUMER") -> Some Model.Consumer
        | _ -> None in
      Some {
        Model.trace_id; span_id;
        parent_span_id = normalized_id 16 (string_member "parentSpanId" span);
        service_name; scope_name;
        operation_name = Option.value (string_member "name" span) ~default:"";
        kind; start_time_ns; end_time_ns;
        duration_ms = float_of_int (max 0 (end_time_ns - start_time_ns)) /. 1_000_000.;
        status; status_message; attributes = attrs span; resource;
        events = List.map span_event (list_member "events" span);
        links = List.filter_map span_link (list_member "links" span);
      }
  | _ -> None

let decode_traces json =
  let spans = list_member "resourceSpans" json
    |> List.concat_map (fun group ->
      let resource = match member "resource" group with
        | Some resource -> attrs resource | None -> [] in
      let service_name = service_name resource in
      list_member "scopeSpans" group |> List.concat_map (fun scope ->
        let scope_name = scope_name scope in
        list_member "spans" scope
        |> List.map (decode_span ~resource ~service_name ~scope_name))) in
  let accepted = List.filter_map Fun.id spans in
  { items = accepted; rejected = List.length spans - List.length accepted;
    error_message = "span traceId must be 32 hex characters and spanId 16 hex characters, neither all zero" }

let decode_log ~resource ~service_name ~scope_name log =
  let body =
    match member "body" log with
    | Some body -> any_value_to_string body
    | None -> ""
  in
  {
    Model.trace_id = (let id = normalized_id 32 (string_member "traceId" log) in
      match id with Some _ -> id | None ->
        let values = attrs log in
        let attr_id = match List.assoc_opt "traceId" values with
          | Some _ as x -> x | None -> List.assoc_opt "trace_id" values in
        normalized_id 32 (Option.map Model.attr_string_value attr_id));
    span_id = (let id = normalized_id 16 (string_member "spanId" log) in
      match id with Some _ -> id | None ->
        let values = attrs log in
        let attr_id = match List.assoc_opt "spanId" values with
          | Some _ as x -> x | None -> List.assoc_opt "span_id" values in
        normalized_id 16 (Option.map Model.attr_string_value attr_id));
    service_name;
    scope_name;
    severity_text =
      Option.value (string_member "severityText" log) ~default:"UNSPECIFIED";
    severity_number = int_member "severityNumber" log;
    timestamp_ns = (let ns = time_member_ns "timeUnixNano" log in
      if ns <> 0 then ns else time_member_ns "observedTimeUnixNano" log);
    observed_timestamp_ns = optional_time_member_ns "observedTimeUnixNano" log;
    body;
    attributes = attrs log;
    resource;
  }

let decode_logs json =
  list_member "resourceLogs" json
  |> List.concat_map (fun resource_logs ->
         let resource =
           match member "resource" resource_logs with
           | Some resource -> attrs resource
           | None -> []
         in
         let service_name = service_name resource in
         list_member "scopeLogs" resource_logs
         |> List.concat_map (fun scope_logs ->
                let scope_name = scope_name scope_logs in
                list_member "logRecords" scope_logs
                |> List.map (decode_log ~resource ~service_name ~scope_name)))

let point_value point =
  match
    ( member "asDouble" point,
      member "asInt" point,
      member "sum" point,
      member "count" point )
  with
  | Some value, _, _, _ -> any_value_to_string value
  | _, Some value, _, _ -> any_value_to_string value
  | _, _, Some value, _ -> any_value_to_string value
  | _, _, _, Some value -> any_value_to_string value
  | _ -> Yojson.Safe.to_string point

let metric_points_for_data ~resource ~service_name ~scope_name metric kind data =
  let points = list_member "dataPoints" data in
  List.map
    (fun point ->
      {
        Model.service_name = service_name;
        scope_name;
        name = Option.value (string_member "name" metric) ~default:"";
        description = string_member "description" metric;
        unit_ = string_member "unit" metric;
        kind;
        start_time_ns = optional_time_member_ns "startTimeUnixNano" point;
        timestamp_ns = time_member_ns "timeUnixNano" point;
        value = point_value point;
        attributes = attrs point;
        resource;
        raw_json = point;
      })
    points

let decode_metric ~resource ~service_name ~scope_name metric =
  [ "gauge"; "sum"; "histogram"; "exponentialHistogram"; "summary" ]
  |> List.concat_map (fun kind ->
         match member kind metric with
         | Some data ->
             metric_points_for_data ~resource ~service_name ~scope_name metric kind data
         | None -> [])

let decode_metrics json =
  list_member "resourceMetrics" json
  |> List.concat_map (fun resource_metrics ->
         let resource =
           match member "resource" resource_metrics with
           | Some resource -> attrs resource
           | None -> []
         in
         let service_name = service_name resource in
         list_member "scopeMetrics" resource_metrics
         |> List.concat_map (fun scope_metrics ->
                let scope_name = scope_name scope_metrics in
                list_member "metrics" scope_metrics
                |> List.concat_map
                     (decode_metric ~resource ~service_name ~scope_name)))

let decode_traces_json text = Result.map decode_traces (parse_json text)
let decode_logs_json text = Result.map (fun json ->
  { items = decode_logs json; rejected = 0; error_message = "" }) (parse_json text)
let decode_metrics_json text = Result.map (fun json ->
  { items = decode_metrics json; rejected = 0; error_message = "" }) (parse_json text)
