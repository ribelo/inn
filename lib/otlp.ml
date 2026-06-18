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

let ns_to_ms json =
  match int64_of_json json with
  | None -> 0
  | Some ns -> Int64.(to_int (div ns 1_000_000L))

let time_member_ms name json =
  match member name json with
  | Some value -> ns_to_ms value
  | None -> 0

let optional_time_member_ms name json =
  match member name json with
  | Some value -> Some (ns_to_ms value)
  | None -> None

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
      | _, Some (`String value), _, _, _, _, _ -> `String value
      | _, Some (`Int value), _, _, _, _, _ -> `Int value
      | _, Some (`Intlit value), _, _, _, _, _ -> `String value
      | _, _, Some (`Float value), _, _, _, _ -> `Float value
      | _, _, Some (`Int value), _, _, _, _ -> `Int value
      | _, _, Some (`String value), _, _, _, _ -> `String value
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

let any_value_to_string json =
  match any_value_to_json json with
  | `String value -> value
  | `Int value -> string_of_int value
  | `Intlit value -> value
  | `Float value -> string_of_float value
  | `Bool value -> string_of_bool value
  | `Null -> ""
  | value -> Yojson.Safe.to_string value

let attrs json =
  list_member "attributes" json
  |> List.filter_map (fun attr ->
         match (string_member "key" attr, member "value" attr) with
         | Some key, Some value -> Some (key, any_value_to_string value)
         | _ -> None)

let service_name resource_attrs =
  let value =
    match List.assoc_opt "service.name" resource_attrs with
    | Some _ as value -> value
    | None -> List.assoc_opt "service_name" resource_attrs
  in
  match value with
  | Some value when value <> "" -> value
  | _ -> "unknown"

let scope_name scope =
  match member "scope" scope with
  | Some scope_json -> string_member "name" scope_json
  | None -> None

let span_status span =
  match member "status" span with
  | Some status -> (
      let message = string_member "message" status in
      match int_member "code" status with
      | Some 2 -> ("error", message)
      | _ -> ("ok", message))
  | None -> ("ok", None)

let span_event event =
  {
    Model.name = Option.value (string_member "name" event) ~default:"event";
    timestamp_ms = time_member_ms "timeUnixNano" event;
    attributes = attrs event;
  }

let decode_span ~resource ~service_name ~scope_name span =
  let trace_id = Option.value (string_member "traceId" span) ~default:"" in
  let span_id = Option.value (string_member "spanId" span) ~default:"" in
  let start_time_ms = time_member_ms "startTimeUnixNano" span in
  let end_time_ms = time_member_ms "endTimeUnixNano" span in
  let status, status_message = span_status span in
  {
    Model.trace_id = trace_id;
    span_id;
    parent_span_id = string_member "parentSpanId" span;
    service_name;
    scope_name;
    operation_name = Option.value (string_member "name" span) ~default:"";
    kind = string_member "kind" span;
    start_time_ms;
    end_time_ms;
    duration_ms = float_of_int (max 0 (end_time_ms - start_time_ms));
    status;
    status_message;
    attributes = attrs span;
    resource;
    events = List.map span_event (list_member "events" span);
  }

let decode_traces json =
  list_member "resourceSpans" json
  |> List.concat_map (fun resource_spans ->
         let resource =
           match member "resource" resource_spans with
           | Some resource -> attrs resource
           | None -> []
         in
         let service_name = service_name resource in
         list_member "scopeSpans" resource_spans
         |> List.concat_map (fun scope_spans ->
                let scope_name = scope_name scope_spans in
                list_member "spans" scope_spans
                |> List.map (decode_span ~resource ~service_name ~scope_name)))

let decode_log ~resource ~service_name ~scope_name log =
  let body =
    match member "body" log with
    | Some body -> any_value_to_string body
    | None -> ""
  in
  {
    Model.trace_id = string_member "traceId" log;
    span_id = string_member "spanId" log;
    service_name;
    scope_name;
    severity_text =
      Option.value (string_member "severityText" log) ~default:"UNSPECIFIED";
    severity_number = int_member "severityNumber" log;
    timestamp_ms =
      (match member "timeUnixNano" log with
      | Some value -> ns_to_ms value
      | None -> time_member_ms "observedTimeUnixNano" log);
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
        start_time_ms = optional_time_member_ms "startTimeUnixNano" point;
        timestamp_ms = time_member_ms "timeUnixNano" point;
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

let require_non_empty kind values =
  match values with
  | [] -> Error ("OTLP payload contained no " ^ kind)
  | _ -> Ok values

let decode_traces_json text =
  match parse_json text with
  | Error _ as error -> error
  | Ok json -> require_non_empty "spans" (decode_traces json)

let decode_logs_json text =
  match parse_json text with
  | Error _ as error -> error
  | Ok json -> require_non_empty "logs" (decode_logs json)

let decode_metrics_json text =
  match parse_json text with
  | Error _ as error -> error
  | Ok json -> require_non_empty "metric points" (decode_metrics json)
