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
  (** Stable id assigned when the record is stored. It is empty on a record
      that has only been decoded. *)
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
(** [is_running] and [warning_count] are maintained with the summary, so a
    broken or in-flight trace is visible from the trace list (tree-6vac). *)

type span_node = {
  span : span;
  depth : int;
  parent_operation_name : string option;
  root_operation_name : string;
  is_running : bool;
  warnings : string list;
}
(** [parent_operation_name] is [None] for a root and for a span whose parent id
    is not in the trace. *)
(** One span in trace-tree order with its context (tree-3w92, tree-sih1). *)

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
(** Token counts, each absent when the span does not report it (aic-q5qt). *)

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
(** The AI call summary both the list and the detail carry (aic-q5qt,
    aic-kqhv). [duration_ms] is [None] while the call is running. *)

type ai_tool_call = {
  tool_name : string;
  tool_span_id : string option;
  tool_status : string;
  tool_duration_ms : float option;
  tool_arguments : string option;
  tool_result : string option;
}

type ai_prompt = { messages : Yojson.Safe.t list; raw : string option }
(** Parsed prompt messages when the attribute value is valid JSON; otherwise the
    raw value is kept as it was stored. *)

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
(** Everything the AI call detail adds to the summary (aic-fy0u). *)

type window = { start_ms : int option }
(** A resolved query window. [None] is the whole retained history. *)

type cursor_position = { sort_key_ns : int; tie_breaker : string }
(** The sort key and the unique tie-breaker of one row, so a keyset cursor can
    resume strictly after it. *)

val window_all : window
(** The whole retained history. *)

val window_lookback : now_ms:int -> ms:int -> window
(** A window that starts [ms] milliseconds before [now_ms]. *)

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

val attr_string_value : Yojson.Safe.t -> string
val span_is_running : span -> bool
(** A span with no end time (zero) or an end before its start is still running
    (tree-78hm). *)
val span_kind_to_string : span_kind -> string
val span_kind_of_string : string -> span_kind option
val span_status_to_string : span_status -> string
val span_status_of_string : string -> span_status option
val attrs_to_json : attrs -> Yojson.Safe.t
val attrs_json_string : attrs -> string
val span_to_json : span -> Yojson.Safe.t
val span_node_to_json : span_node -> Yojson.Safe.t
(** A span plus [depth], [parentOperationName], [rootOperationName], and its
    own warnings (tree-3w92, tree-sih1). *)
val ai_call_to_json : ai_call -> Yojson.Safe.t
val ai_call_detail_to_json : ai_call_detail -> Yojson.Safe.t
val log_to_json : log_record -> Yojson.Safe.t
val metric_point_to_json : metric_point -> Yojson.Safe.t
val trace_summary_to_json : trace_summary -> Yojson.Safe.t
val trace_to_json : trace -> Yojson.Safe.t
val prune_report_to_json : prune_report -> Yojson.Safe.t
val stats_to_json : stats -> Yojson.Safe.t
val stat_item_to_json : stat_item -> Yojson.Safe.t
val facet_item_to_json : facet_item -> Yojson.Safe.t
