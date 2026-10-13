module Q = Ox_sql
module Sqlite = Ox_sql.Sqlite
module String_set = Set.Make (String)

type error =
  [ Q.Pool.error
  | `Invalid_store of string
  ]

(* The store is a ring of [segment_count] SQLite files (bcache-f1le). One
   connection writes to the active segment. When the active segment reaches
   its share of the budget, the next file in the ring is deleted, created
   empty, and becomes active: the oldest data goes by deleting one file. One
   reader connection attaches every segment and defines temporary views with
   the table names the queries use, so the queries do not know about
   segments. *)
type segment = {
  slot : int;
  path : string;
  mutable sequence : int;
  mutable started_at_ms : int;
  mutable bytes : int;
}

type t = {
  config : Config.t;
  now_ms : unit -> int;
  wall_now : unit -> int;
  segments : segment array;
  mutable active : int;
  mutable writer : Q.Pool.t;
  reader : Q.Pool.t;
  mutable generation : int;
  mutable reader_generation : int;
  write_lock : Eio.Mutex.t;
  reader_lock : Eio.Mutex.t;
  open_writer : string -> (Q.Pool.t, error) result;
  create_segment : segment -> sequence:int -> (unit, error) result;
  report : string -> unit;
  mutable ingest_failures : int;
  mutable last_ingest_failure : Model.ingest_failure option;
}

type ingest_counts = {
  spans : int;
  logs : int;
  metric_points : int;
}

type 'a page = {
  items : 'a list;
  next : Model.cursor_position option;
}

type log_filter = {
  service : string option;
  severity : string option;
  contains : string option;
  window : Model.window;
  cursor : Model.cursor_position option;
  limit : int;
}

type span_search_filter = {
  service : string option;
  trace_id : string option;
  operation : string option;
  parent_operation : string option;
  status : string option;
  attrs : (string * string) list;
  window : Model.window;
  cursor : Model.cursor_position option;
  limit : int;
}

type trace_search_filter = {
  service : string option;
  operation : string option;
  status : string option;
  attrs : (string * string) list;
  window : Model.window;
  cursor : Model.cursor_position option;
  limit : int;
}

type log_search_filter = {
  service : string option;
  trace_id : string option;
  span_id : string option;
  severity : string option;
  body : string option;
  attrs : (string * string) list;
  window : Model.window;
  cursor : Model.cursor_position option;
  limit : int;
}

type trace_stats_filter = {
  group_by : string;
  agg : string;
  service : string option;
  operation : string option;
  status : string option;
  attrs : (string * string) list;
  window : Model.window;
  limit : int;
}

type log_stats_filter = {
  group_by : string;
  service : string option;
  trace_id : string option;
  span_id : string option;
  severity : string option;
  body : string option;
  attrs : (string * string) list;
  window : Model.window;
  limit : int;
}

type facet_filter = {
  kind : string;
  field : string;
  key : string option;
  service : string option;
  window : Model.window;
  limit : int;
}

type metric_filter = {
  service : string option;
  name : string option;
  window : Model.window;
  cursor : Model.cursor_position option;
  limit : int;
}

(* Bump this constant, and the fingerprint recorded in the schema test, with
   every change to the statements in [schemas]. [open_] recreates any segment
   whose stored version differs, so a schema change without a bump would be
   silently skipped on an existing segment (schm-hnis). *)
let schema_version = 7

let schema_version_text = string_of_int schema_version

(* Eight segments keep the attached databases under SQLite's default limit of
   ten, and keep the share of the budget lost at one rotation at one eighth. *)
let segment_count = 8

(* At most this many spans of one trace go into one segment; later spans of
   that trace are counted as dropped in its trace part (bcache-s5kc). *)
let max_trace_spans_per_segment = 5_000

(* Only attribute values up to this length go into the attribute index tables.
   The record keeps every attribute in its JSON column (bcache-a1x1). *)
let max_indexed_value_bytes = 256

module Meta = struct
  module T = Q.Table.Make (struct
    let name = "inn_meta"
  end)

  include T

  let key = column "key" Q.text
  let value = column "value" Q.text
end

module Spans = struct
  module T = Q.Table.Make (struct
    let name = "spans"
  end)

  include T

  let id = column "id" Q.text
  let trace_id = column "trace_id" Q.text
  let span_id = column "span_id" Q.text
  let parent_span_id = column "parent_span_id" (Q.nullable Q.text)
  let service_name = column "service_name" Q.text
  let scope_name = column "scope_name" (Q.nullable Q.text)
  let operation_name = column "operation_name" Q.text
  let kind = column "kind" (Q.nullable Q.text)
  let start_time_ns = column "start_time_ns" Q.int
  let end_time_ns = column "end_time_ns" Q.int
  let duration_ms = column "duration_ms" Q.float
  let status = column "status" Q.text
  let status_message = column "status_message" (Q.nullable Q.text)
  let attributes_json = column "attributes_json" Q.text
  let resource_json = column "resource_json" Q.text
  let events_json = column "events_json" Q.text
  let links_json = column "links_json" Q.text
  let ingested_at_ms = column "ingested_at_ms" Q.int
end

module Span_attributes = struct
  module T = Q.Table.Make (struct
    let name = "span_attributes"
  end)

  include T

  let owner_id = column "owner_id" Q.text
  let key = column "key" Q.text
  let value = column "value" Q.text
end

module Logs = struct
  module T = Q.Table.Make (struct
    let name = "logs"
  end)

  include T

  let id = column "id" Q.text
  let trace_id = column "trace_id" (Q.nullable Q.text)
  let span_id = column "span_id" (Q.nullable Q.text)
  let service_name = column "service_name" Q.text
  let scope_name = column "scope_name" (Q.nullable Q.text)
  let severity_text = column "severity_text" Q.text
  let severity_normalized = column "severity_normalized" Q.text
  let severity_number = column "severity_number" (Q.nullable Q.int)
  let timestamp_ns = column "timestamp_ns" Q.int
  let observed_timestamp_ns = column "observed_timestamp_ns" (Q.nullable Q.int)
  let body = column "body" Q.text
  let attributes_json = column "attributes_json" Q.text
  let resource_json = column "resource_json" Q.text
  let ingested_at_ms = column "ingested_at_ms" Q.int
end

module Log_attributes = struct
  module T = Q.Table.Make (struct
    let name = "log_attributes"
  end)

  include T

  let owner_id = column "owner_id" Q.text
  let key = column "key" Q.text
  let value = column "value" Q.text
end

(* One row per trace and segment, for the spans of that trace in that
   segment. The reader's [trace_summaries] view combines the parts of every
   segment. *)
module Trace_parts = struct
  module T = Q.Table.Make (struct
    let name = "trace_parts"
  end)

  include T

  let trace_id = column "trace_id" Q.text
  let service_name = column "service_name" Q.text
  let root_operation_name = column "root_operation_name" Q.text
  let has_root = column "has_root" Q.bool
  let started_at_ns = column "started_at_ns" Q.int
  let ended_at_ns = column "ended_at_ns" Q.int
  let span_count = column "span_count" Q.int
  let error_count = column "error_count" Q.int
  let running_count = column "running_count" Q.int
  let root_count = column "root_count" Q.int
  let missing_parent_count = column "missing_parent_count" Q.int
  let dropped_span_count = column "dropped_span_count" Q.int
  let updated_at_ms = column "updated_at_ms" Q.int
end

(* The reader's view over [trace_parts] in every segment. *)
module Trace_summaries = struct
  module T = Q.Table.Make (struct
    let name = "trace_summaries"
  end)

  include T

  let trace_id = column "trace_id" Q.text
  let service_name = column "service_name" Q.text
  let root_operation_name = column "root_operation_name" Q.text
  let started_at_ns = column "started_at_ns" Q.int
  let ended_at_ns = column "ended_at_ns" Q.int
  let duration_ms = column "duration_ms" Q.float
  let span_count = column "span_count" Q.int
  let error_count = column "error_count" Q.int
  let is_running = column "is_running" Q.bool
  let warning_count = column "warning_count" Q.int
  let dropped_span_count = column "dropped_span_count" Q.int
  let updated_at_ms = column "updated_at_ms" Q.int
end

module Trace_services = struct
  module T = Q.Table.Make (struct
    let name = "trace_services"
  end)

  include T

  let trace_id = column "trace_id" Q.text
  let service_name = column "service_name" Q.text
end

module Metric_points = struct
  module T = Q.Table.Make (struct
    let name = "metric_points"
  end)

  include T

  let id = column "id" Q.text
  let service_name = column "service_name" Q.text
  let scope_name = column "scope_name" (Q.nullable Q.text)
  let name = column "name" Q.text
  let description = column "description" (Q.nullable Q.text)
  let unit_ = column "unit" (Q.nullable Q.text)
  let kind = column "kind" Q.text
  let start_time_ns = column "start_time_ns" (Q.nullable Q.int)
  let timestamp_ns = column "timestamp_ns" Q.int
  let value = column "value" Q.text
  let attributes_json = column "attributes_json" Q.text
  let resource_json = column "resource_json" Q.text
  let raw_json = column "raw_json" Q.text
  let ingested_at_ms = column "ingested_at_ms" Q.int
end

module Metric_attributes = struct
  module T = Q.Table.Make (struct
    let name = "metric_attributes"
  end)

  include T

  let owner_id = column "owner_id" Q.text
  let key = column "key" Q.text
  let value = column "value" Q.text
end

let pp_error ppf = function
  | `Ox_sql error -> Q.pp_error ppf error
  | `Pool_shutdown -> Format.pp_print_string ppf "pool shutdown"
  | `Timeout -> Format.pp_print_string ppf "timeout"
  | `Invalid_store message -> Format.fprintf ppf "invalid store: %s" message

let error_message error = Format.asprintf "%a" pp_error error

let widen_pool_error (error : Q.Pool.error) : error = (error :> error)

let rec mkdir_p ~caps path =
  if path = "" || path = "." || Sys.file_exists path then ()
  else (
    mkdir_p ~caps (Filename.dirname path);
    Ox_caps.Cap_unix.mkdir ~caps path 0o700)

let wall_now_ms ~caps () =
  int_of_float (Ox_caps.Cap_unix.gettimeofday ~caps () *. 1000.)

let id_counter = Atomic.make 0

let fresh_id wall_now prefix =
  let seq = Atomic.fetch_and_add id_counter 1 in
  Printf.sprintf "%s-%d-%d-%d" prefix (Unix.getpid ()) (wall_now ()) seq

let span_row_id (span : Model.span) = span.trace_id ^ ":" ^ span.span_id

let event_to_json (event : Model.span_event) =
  `Assoc
    [
      ("name", `String event.Model.name);
      ("timestampUnixNano", `String (string_of_int event.timestamp_ns));
      ("attributes", Model.attrs_to_json event.attributes);
    ]

let events_json events = Yojson.Safe.to_string (`List (List.map event_to_json events))

let attrs_of_json text =
  match Yojson.Safe.from_string text with
  | `Assoc fields ->
      fields
  | _ -> []
  | exception Yojson.Json_error _ -> []

let links_of_json text =
  match Yojson.Safe.from_string text with
  | `List links -> List.filter_map (function
      | `Assoc fields -> (match List.assoc_opt "traceId" fields, List.assoc_opt "spanId" fields with
          | Some (`String trace_id), Some (`String span_id) ->
              let attributes = match List.assoc_opt "attributes" fields with
                | Some json -> attrs_of_json (Yojson.Safe.to_string json) | None -> [] in
              Some { Model.trace_id; span_id; attributes }
          | _ -> None)
      | _ -> None) links
  | _ -> []
  | exception Yojson.Json_error _ -> []

let links_json links =
  Yojson.Safe.to_string (`List (List.map (fun (link : Model.span_link) ->
    `Assoc [ ("traceId", `String link.trace_id); ("spanId", `String link.span_id);
             ("attributes", Model.attrs_to_json link.attributes) ]) links))

let events_of_json text =
  match Yojson.Safe.from_string text with
  | `List events ->
      List.filter_map
        (function
          | `Assoc fields ->
              let find key = List.assoc_opt key fields in
              let name =
                match find "name" with
                | Some (`String value) -> value
                | _ -> "event"
              in
              let timestamp_ns =
                match find "timestampUnixNano" with
                | Some (`String value) -> Option.value (int_of_string_opt value) ~default:0
                | Some (`Int value) -> value
                | _ -> 0
              in
              let attributes =
                match find "attributes" with
                | Some json -> attrs_of_json (Yojson.Safe.to_string json)
                | None -> []
              in
              Some { Model.name; timestamp_ns; attributes }
          | _ -> None)
        events
  | _ -> []
  | exception Yojson.Json_error _ -> []

let q_exec_pool runner query = Q.Pool.Typed.execute_compiled runner query

let q_select_pool runner query =
  Q.Pool.Typed.select runner (Q.Select.compile query)

let q_exec runner query =
  Q.Pool.Typed.execute_compiled runner query |> Result.map_error widen_pool_error

let q_select runner query =
  Q.Pool.Typed.select runner (Q.Select.compile query)
  |> Result.map_error widen_pool_error

let rec result_iter list f =
  let open Result.Syntax in
  match list with
  | [] -> Ok ()
  | item :: rest ->
      let* () = f item in
      result_iter rest f

let one_or_none operation rows =
  match rows with
  | [] -> Ok None
  | [ row ] -> Ok (Some row)
  | _ -> Error (`Invalid_store (operation ^ " returned more than one row"))

let scalar operation rows =
  match rows with
  | [ row ] -> Ok row
  | [] -> Error (`Invalid_store (operation ^ " returned no rows"))
  | _ -> Error (`Invalid_store (operation ^ " returned more than one row"))

(* The schema of one segment. *)
let schemas =
  let open Q.Ox_schema in
  [
    create_table ~if_not_exists:true Meta.table
      [ column ~primary_key:true Meta.key; column ~not_null:true Meta.value ];
    create_table ~if_not_exists:true Spans.table
      [
        column ~primary_key:true Spans.id;
        column ~not_null:true Spans.trace_id;
        column ~not_null:true Spans.span_id;
        column Spans.parent_span_id;
        column ~not_null:true Spans.service_name;
        column Spans.scope_name;
        column ~not_null:true Spans.operation_name;
        column Spans.kind;
        column ~not_null:true Spans.start_time_ns;
        column ~not_null:true Spans.end_time_ns;
        column ~not_null:true Spans.duration_ms;
        column ~not_null:true Spans.status;
        column Spans.status_message;
        column ~not_null:true Spans.attributes_json;
        column ~not_null:true Spans.resource_json;
        column ~not_null:true Spans.events_json;
        column ~not_null:true Spans.links_json;
        column ~not_null:true Spans.ingested_at_ms;
      ];
    create_index ~if_not_exists:true ~name:"idx_spans_start_time" Spans.table
      [ Q.Column.any Spans.start_time_ns ];
    create_index ~if_not_exists:true ~name:"idx_spans_service_start" Spans.table
      [ Q.Column.any Spans.service_name; Q.Column.any Spans.start_time_ns ];
    create_index ~if_not_exists:true ~name:"idx_spans_trace_parent" Spans.table
      [ Q.Column.any Spans.trace_id; Q.Column.any Spans.parent_span_id ];
    create_index ~if_not_exists:true ~name:"idx_spans_span_id" Spans.table
      [ Q.Column.any Spans.span_id ];
    create_table ~if_not_exists:true Span_attributes.table
      [
        column ~not_null:true Span_attributes.owner_id;
        column ~not_null:true Span_attributes.key;
        column ~not_null:true Span_attributes.value;
      ];
    create_index ~if_not_exists:true ~name:"idx_span_attributes_key_value"
      Span_attributes.table
      [ Q.Column.any Span_attributes.key; Q.Column.any Span_attributes.value ];
    create_index ~if_not_exists:true ~name:"idx_span_attributes_owner"
      Span_attributes.table [ Q.Column.any Span_attributes.owner_id ];
    create_table ~if_not_exists:true Logs.table
      [
        column ~primary_key:true Logs.id;
        column Logs.trace_id;
        column Logs.span_id;
        column ~not_null:true Logs.service_name;
        column Logs.scope_name;
        column ~not_null:true Logs.severity_text;
        column ~not_null:true Logs.severity_normalized;
        column Logs.severity_number;
        column ~not_null:true Logs.timestamp_ns;
        column Logs.observed_timestamp_ns;
        column ~not_null:true Logs.body;
        column ~not_null:true Logs.attributes_json;
        column ~not_null:true Logs.resource_json;
        column ~not_null:true Logs.ingested_at_ms;
      ];
    create_index ~if_not_exists:true ~name:"idx_logs_service_timestamp" Logs.table
      [ Q.Column.any Logs.service_name; Q.Column.any Logs.timestamp_ns ];
    create_index ~if_not_exists:true ~name:"idx_logs_timestamp" Logs.table
      [ Q.Column.any Logs.timestamp_ns ];
    create_index ~if_not_exists:true ~name:"idx_logs_trace" Logs.table
      [ Q.Column.any Logs.trace_id ];
    create_index ~if_not_exists:true ~name:"idx_logs_span" Logs.table
      [ Q.Column.any Logs.span_id ];
    create_table ~if_not_exists:true Log_attributes.table
      [
        column ~not_null:true Log_attributes.owner_id;
        column ~not_null:true Log_attributes.key;
        column ~not_null:true Log_attributes.value;
      ];
    create_index ~if_not_exists:true ~name:"idx_log_attributes_key_value"
      Log_attributes.table
      [ Q.Column.any Log_attributes.key; Q.Column.any Log_attributes.value ];
    create_index ~if_not_exists:true ~name:"idx_log_attributes_owner"
      Log_attributes.table [ Q.Column.any Log_attributes.owner_id ];
    create_table ~if_not_exists:true Trace_parts.table
      [
        column ~primary_key:true Trace_parts.trace_id;
        column ~not_null:true Trace_parts.service_name;
        column ~not_null:true Trace_parts.root_operation_name;
        column ~not_null:true Trace_parts.has_root;
        column ~not_null:true Trace_parts.started_at_ns;
        column ~not_null:true Trace_parts.ended_at_ns;
        column ~not_null:true Trace_parts.span_count;
        column ~not_null:true Trace_parts.error_count;
        column ~not_null:true Trace_parts.running_count;
        column ~not_null:true Trace_parts.root_count;
        column ~not_null:true Trace_parts.missing_parent_count;
        column ~not_null:true Trace_parts.dropped_span_count;
        column ~not_null:true Trace_parts.updated_at_ms;
      ];
    create_table ~if_not_exists:true Trace_services.table
      [ column ~not_null:true Trace_services.trace_id;
        column ~not_null:true Trace_services.service_name ];
    create_index ~if_not_exists:true ~unique:true ~name:"idx_trace_services_pair"
      Trace_services.table
      [ Q.Column.any Trace_services.trace_id; Q.Column.any Trace_services.service_name ];
    create_index ~if_not_exists:true ~name:"idx_trace_services_service"
      Trace_services.table [ Q.Column.any Trace_services.service_name ];
    create_table ~if_not_exists:true Metric_points.table
      [
        column ~primary_key:true Metric_points.id;
        column ~not_null:true Metric_points.service_name;
        column Metric_points.scope_name;
        column ~not_null:true Metric_points.name;
        column Metric_points.description;
        column Metric_points.unit_;
        column ~not_null:true Metric_points.kind;
        column Metric_points.start_time_ns;
        column ~not_null:true Metric_points.timestamp_ns;
        column ~not_null:true Metric_points.value;
        column ~not_null:true Metric_points.attributes_json;
        column ~not_null:true Metric_points.resource_json;
        column ~not_null:true Metric_points.raw_json;
        column ~not_null:true Metric_points.ingested_at_ms;
      ];
    create_index ~if_not_exists:true ~name:"idx_metric_points_service"
      Metric_points.table [ Q.Column.any Metric_points.service_name ];
    create_index ~if_not_exists:true ~name:"idx_metric_points_timestamp"
      Metric_points.table [ Q.Column.any Metric_points.timestamp_ns ];
    create_index ~if_not_exists:true ~name:"idx_metric_points_name"
      Metric_points.table [ Q.Column.any Metric_points.name ];
    create_table ~if_not_exists:true Metric_attributes.table
      [
        column ~not_null:true Metric_attributes.owner_id;
        column ~not_null:true Metric_attributes.key;
        column ~not_null:true Metric_attributes.value;
      ];
    create_index ~if_not_exists:true ~name:"idx_metric_attributes_key_value"
      Metric_attributes.table
      [ Q.Column.any Metric_attributes.key; Q.Column.any Metric_attributes.value ];
    create_index ~if_not_exists:true ~name:"idx_metric_attributes_owner"
      Metric_attributes.table [ Q.Column.any Metric_attributes.owner_id ];
  ]

(* The compiled statements are what actually runs, so the fingerprint covers
   them rather than the declarations. The schema test records this value next
   to [schema_version]: a schema edit without a version bump fails it
   (schm-hnis). *)
let schema_statements =
  List.map
    (fun schema -> Q.Compiled.schema_sql (Q.Ox_schema.compile schema))
    schemas

let schema_fingerprint =
  Digest.to_hex (Digest.string (String.concat "\n" schema_statements))

let meta_upsert key text =
  Q.Insert.(
    into Meta.table
    |> value Meta.key key
    |> value Meta.value text
    |> on_conflict_update [ Q.Column.any Meta.key ] ~set:[ Q.Column.any Meta.value ]
    |> compile)

let sqlite_config path =
  {
    Sqlite.path;
    mode = Read_write_create;
    busy_timeout_ms = Some 5000;
    foreign_keys = true;
    journal_mode = Some `Wal;
    synchronous = Some `Normal;
    cache_size = Some (-20_000);
  }

(* The reader's own database is an empty in-memory database; everything it
   reads comes from the attached segments. *)
let reader_config =
  {
    Sqlite.path = ":memory:";
    mode = Read_write_create;
    busy_timeout_ms = Some 5000;
    foreign_keys = false;
    journal_mode = None;
    synchronous = None;
    cache_size = Some (-20_000);
  }

let pool_timeout = Ox.Duration.seconds 30

(* Ox SQL has no typed pragma, attach, or view API. Ox_sql.mli documents
   [Pool.Raw] as the escape hatch for "migrations, pragmas, diagnostics, and
   backend-specific SQL". Every raw statement below is a literal; schema names
   and paths are bound as values. *)
let first_int operation rows =
  let column_value row =
    match Q.Row.fields row with
    | name :: _ -> Q.Row.int name row
    | [] -> None
  in
  match List.filter_map column_value rows with
  | value :: _ -> Ok value
  | [] -> Error (`Invalid_store (operation ^ " did not return an integer value"))

let database_bytes runner =
  let open Result.Syntax in
  let* pages =
    Q.Pool.Raw.query runner "PRAGMA page_count" [] |> Result.map_error widen_pool_error
  in
  let* page_count = first_int "PRAGMA page_count" pages in
  let* sizes =
    Q.Pool.Raw.query runner "PRAGMA page_size" [] |> Result.map_error widen_pool_error
  in
  let* page_size = first_int "PRAGMA page_size" sizes in
  Ok (page_count * page_size)

let slot_names = [| "s0"; "s1"; "s2"; "s3"; "s4"; "s5"; "s6"; "s7" |]

(* The views of the reader connection. They name the eight slots s0..s7, so
   every slot is always attached, and an empty segment answers with no rows. *)
let reader_views_sql = {sql|CREATE TEMP VIEW IF NOT EXISTS spans AS
  SELECT * FROM s0.spans UNION ALL
  SELECT * FROM s1.spans UNION ALL
  SELECT * FROM s2.spans UNION ALL
  SELECT * FROM s3.spans UNION ALL
  SELECT * FROM s4.spans UNION ALL
  SELECT * FROM s5.spans UNION ALL
  SELECT * FROM s6.spans UNION ALL
  SELECT * FROM s7.spans;
CREATE TEMP VIEW IF NOT EXISTS span_attributes AS
  SELECT * FROM s0.span_attributes UNION ALL
  SELECT * FROM s1.span_attributes UNION ALL
  SELECT * FROM s2.span_attributes UNION ALL
  SELECT * FROM s3.span_attributes UNION ALL
  SELECT * FROM s4.span_attributes UNION ALL
  SELECT * FROM s5.span_attributes UNION ALL
  SELECT * FROM s6.span_attributes UNION ALL
  SELECT * FROM s7.span_attributes;
CREATE TEMP VIEW IF NOT EXISTS logs AS
  SELECT * FROM s0.logs UNION ALL
  SELECT * FROM s1.logs UNION ALL
  SELECT * FROM s2.logs UNION ALL
  SELECT * FROM s3.logs UNION ALL
  SELECT * FROM s4.logs UNION ALL
  SELECT * FROM s5.logs UNION ALL
  SELECT * FROM s6.logs UNION ALL
  SELECT * FROM s7.logs;
CREATE TEMP VIEW IF NOT EXISTS log_attributes AS
  SELECT * FROM s0.log_attributes UNION ALL
  SELECT * FROM s1.log_attributes UNION ALL
  SELECT * FROM s2.log_attributes UNION ALL
  SELECT * FROM s3.log_attributes UNION ALL
  SELECT * FROM s4.log_attributes UNION ALL
  SELECT * FROM s5.log_attributes UNION ALL
  SELECT * FROM s6.log_attributes UNION ALL
  SELECT * FROM s7.log_attributes;
CREATE TEMP VIEW IF NOT EXISTS metric_points AS
  SELECT * FROM s0.metric_points UNION ALL
  SELECT * FROM s1.metric_points UNION ALL
  SELECT * FROM s2.metric_points UNION ALL
  SELECT * FROM s3.metric_points UNION ALL
  SELECT * FROM s4.metric_points UNION ALL
  SELECT * FROM s5.metric_points UNION ALL
  SELECT * FROM s6.metric_points UNION ALL
  SELECT * FROM s7.metric_points;
CREATE TEMP VIEW IF NOT EXISTS metric_attributes AS
  SELECT * FROM s0.metric_attributes UNION ALL
  SELECT * FROM s1.metric_attributes UNION ALL
  SELECT * FROM s2.metric_attributes UNION ALL
  SELECT * FROM s3.metric_attributes UNION ALL
  SELECT * FROM s4.metric_attributes UNION ALL
  SELECT * FROM s5.metric_attributes UNION ALL
  SELECT * FROM s6.metric_attributes UNION ALL
  SELECT * FROM s7.metric_attributes;
CREATE TEMP VIEW IF NOT EXISTS trace_services AS
  SELECT * FROM s0.trace_services UNION ALL
  SELECT * FROM s1.trace_services UNION ALL
  SELECT * FROM s2.trace_services UNION ALL
  SELECT * FROM s3.trace_services UNION ALL
  SELECT * FROM s4.trace_services UNION ALL
  SELECT * FROM s5.trace_services UNION ALL
  SELECT * FROM s6.trace_services UNION ALL
  SELECT * FROM s7.trace_services;
CREATE TEMP VIEW IF NOT EXISTS inn_meta AS SELECT * FROM s0.inn_meta;
CREATE TEMP VIEW IF NOT EXISTS trace_summaries AS
WITH parts AS (
  SELECT * FROM s0.trace_parts UNION ALL
  SELECT * FROM s1.trace_parts UNION ALL
  SELECT * FROM s2.trace_parts UNION ALL
  SELECT * FROM s3.trace_parts UNION ALL
  SELECT * FROM s4.trace_parts UNION ALL
  SELECT * FROM s5.trace_parts UNION ALL
  SELECT * FROM s6.trace_parts UNION ALL
  SELECT * FROM s7.trace_parts
),
roots AS (
  SELECT trace_id, service_name, root_operation_name,
    ROW_NUMBER() OVER (
      PARTITION BY trace_id ORDER BY has_root DESC, started_at_ns ASC
    ) AS root_rank
  FROM parts
)
SELECT
  parts.trace_id AS trace_id,
  roots.service_name AS service_name,
  roots.root_operation_name AS root_operation_name,
  MIN(parts.started_at_ns) AS started_at_ns,
  MAX(parts.ended_at_ns) AS ended_at_ns,
  (MAX(parts.ended_at_ns) - MIN(parts.started_at_ns)) / 1000000.0 AS duration_ms,
  SUM(parts.span_count) AS span_count,
  SUM(parts.error_count) AS error_count,
  MAX(parts.running_count) > 0 AS is_running,
  SUM(parts.missing_parent_count)
    + (CASE WHEN SUM(parts.root_count) + SUM(parts.missing_parent_count) > 1
       THEN 1 ELSE 0 END) AS warning_count,
  SUM(parts.dropped_span_count) AS dropped_span_count,
  MAX(parts.updated_at_ms) AS updated_at_ms
FROM parts
JOIN roots ON roots.trace_id = parts.trace_id AND roots.root_rank = 1
GROUP BY parts.trace_id;|sql}

let attach_segments runner segments =
  let open Result.Syntax in
  let raw_error result = Result.map_error widen_pool_error result in
  let* attached =
    Q.Pool.Raw.query runner "PRAGMA database_list" [] |> raw_error
  in
  let attached_names =
    List.filter_map (fun row -> Q.Row.string "name" row) attached
  in
  let* () =
    result_iter
      (List.filter (fun name -> Array.mem name slot_names) attached_names)
      (fun name ->
        let* _ =
          Q.Pool.Raw.execute runner "DETACH DATABASE ?" [ Q.Value.string name ]
          |> raw_error
        in
        Ok ())
  in
  let* () =
    result_iter (Array.to_list segments) (fun segment ->
        let* _ =
          Q.Pool.Raw.execute runner "ATTACH DATABASE ? AS ?"
            [ Q.Value.string segment.path; Q.Value.string slot_names.(segment.slot) ]
          |> raw_error
        in
        Ok ())
  in
  Q.Pool.Raw.execute_script runner reader_views_sql |> raw_error

(* Before a read, the reader attaches the current files when a rotation
   changed them; a failed read makes the next one attach again, so a reader
   connection that the pool replaced gets its attachments back. *)
let ensure_reader t =
  if t.reader_generation = t.generation then Ok ()
  else
    Eio.Mutex.use_rw ~protect:true t.reader_lock (fun () ->
        if t.reader_generation = t.generation then Ok ()
        else
          let generation = t.generation in
          match attach_segments t.reader t.segments with
          | Ok () ->
              t.reader_generation <- generation;
              Ok ()
          | Error _ as error -> error)

let read t f =
  match ensure_reader t with
  | Error _ as error -> error
  | Ok () -> (
      match f t.reader with
      | Ok _ as ok -> ok
      | Error _ as error ->
          t.reader_generation <- -1;
          error)

let segment_bytes config =
  config.Config.max_db_size_mb * 1024 * 1024 / segment_count

let segment_path config slot =
  Filename.concat config.Config.data_dir (Printf.sprintf "segment-%d.sqlite" slot)

let remove_if_exists ~caps path =
  if Sys.file_exists path then Ox_caps.Cap_sys.remove ~caps path

let remove_segment_files ~caps path =
  try
    List.iter (remove_if_exists ~caps) [ path; path ^ "-wal"; path ^ "-shm" ];
    Ok ()
  with Sys_error message -> Error (`Invalid_store message)

let default_report ~caps line =
  Ox_caps.Cap_stdlib.prerr_endline ~caps ("inn: " ^ line)

type segment_state =
  | Segment_absent
  | Segment_current of { sequence : int; started_at_ms : int; bytes : int }
  | Segment_unusable of string

let meta_value pool key =
  let open Result.Syntax in
  let* rows =
    q_select pool
      Q.Select.(
        from Meta.table Q.Projection.(one Meta.value)
        |> where Q.Expr.(eq Meta.key key)
        |> limit 1)
  in
  Ok (match rows with value :: _ -> Some value | [] -> None)

let with_segment_pool ~caps path f =
  Eio.Switch.run (fun sw ->
      let open Result.Syntax in
      let* pool =
        Q.Pool.create ~caps ~sw ~default_timeout:pool_timeout ~max_size:1
          (sqlite_config path)
        |> Result.map_error widen_pool_error
      in
      let result = f pool in
      let closed = Q.Pool.shutdown pool |> Result.map_error widen_pool_error in
      match result with Error _ -> result | Ok value -> Result.map (fun () -> value) closed)

let read_segment_state ~caps path =
  if not (Sys.file_exists path) then Segment_absent
  else
    let state =
      with_segment_pool ~caps path (fun pool ->
          let open Result.Syntax in
          let* version = meta_value pool "schema_version" in
          let* sequence = meta_value pool "sequence" in
          let* started_at = meta_value pool "started_at_ms" in
          let* bytes = database_bytes pool in
          match
            ( version,
              Option.bind sequence int_of_string_opt,
              Option.bind started_at int_of_string_opt )
          with
          | Some version, Some sequence, Some started_at_ms
            when String.equal version schema_version_text ->
              Ok (Segment_current { sequence; started_at_ms; bytes })
          | Some version, _, _ when not (String.equal version schema_version_text) ->
              Ok
                (Segment_unusable
                   (Printf.sprintf "schema version %s does not match version %d"
                      version schema_version))
          | _ -> Ok (Segment_unusable "its inn_meta rows are missing"))
    in
    match state with
    | Ok state -> state
    | Error error -> Segment_unusable (error_message error)

let create_segment_file ~caps ~now segment ~sequence =
  let open Result.Syntax in
  let* () = remove_segment_files ~caps segment.path in
  let started_at_ms = now () in
  let* bytes =
    with_segment_pool ~caps segment.path (fun pool ->
        let* () =
          result_iter schemas (fun schema ->
              Q.Pool.Typed.run_schema pool (Q.Ox_schema.compile schema)
              |> Result.map_error widen_pool_error)
        in
        let* _ = q_exec pool (meta_upsert "schema_version" schema_version_text) in
        let* _ = q_exec pool (meta_upsert "sequence" (string_of_int sequence)) in
        let* _ =
          q_exec pool (meta_upsert "started_at_ms" (string_of_int started_at_ms))
        in
        database_bytes pool)
  in
  segment.sequence <- sequence;
  segment.started_at_ms <- started_at_ms;
  segment.bytes <- bytes;
  Ok ()

let open_ ~caps ~sw ?(now_ms = wall_now_ms ~caps) ?(report = default_report ~caps) config =
  let wall_now = wall_now_ms ~caps in
  let open Result.Syntax in
  let* () =
    try
      mkdir_p ~caps config.Config.data_dir;
      Ok ()
    with Unix.Unix_error (error, operation, path) ->
      Error
        (`Invalid_store
          (Printf.sprintf "%s %s: %s" operation path (Unix.error_message error)))
  in
  let create_segment segment ~sequence =
    create_segment_file ~caps ~now:wall_now segment ~sequence
  in
  let segments =
    Array.init segment_count (fun slot ->
        { slot; path = segment_path config slot; sequence = 0; started_at_ms = 0; bytes = 0 })
  in
  (* Every slot file exists and has the current schema; a file that does not
     is deleted and created empty (bcache-f1le). *)
  let* () =
    result_iter (Array.to_list segments) (fun segment ->
        match read_segment_state ~caps segment.path with
        | Segment_current { sequence; started_at_ms; bytes } ->
            segment.sequence <- sequence;
            segment.started_at_ms <- started_at_ms;
            segment.bytes <- bytes;
            Ok ()
        | Segment_absent -> create_segment segment ~sequence:0
        | Segment_unusable reason ->
            report
              (Printf.sprintf "segment %s is unusable (%s); deleting it and creating an empty one"
                 segment.path reason);
            create_segment segment ~sequence:0)
  in
  let active =
    Array.fold_left
      (fun best segment ->
        if segment.sequence > segments.(best).sequence then segment.slot else best)
      0 segments
  in
  let* () =
    if segments.(active).sequence = 0 then create_segment segments.(active) ~sequence:1
    else Ok ()
  in
  let open_writer path =
    Q.Pool.create ~caps ~sw ~default_timeout:pool_timeout ~max_size:1 (sqlite_config path)
    |> Result.map_error widen_pool_error
  in
  let* writer = open_writer segments.(active).path in
  let* reader =
    Q.Pool.create ~caps ~sw ~default_timeout:pool_timeout ~max_size:1 reader_config
    |> Result.map_error widen_pool_error
  in
  let t =
    {
      config;
      now_ms;
      wall_now;
      segments;
      active;
      writer;
      reader;
      generation = 0;
      reader_generation = -1;
      write_lock = Eio.Mutex.create ();
      reader_lock = Eio.Mutex.create ();
      open_writer;
      create_segment;
      report;
      ingest_failures = 0;
      last_ingest_failure = None;
    }
  in
  let* () = ensure_reader t in
  Ok t

let close t =
  let writer = Q.Pool.shutdown t.writer |> Result.map_error widen_pool_error in
  let reader = Q.Pool.shutdown t.reader |> Result.map_error widen_pool_error in
  match writer with Error _ -> writer | Ok () -> reader

(* The query window is resolved against this clock, so handler tests can drive
   both ingestion and lookback with the same injected time. *)
let now_ms t = t.now_ms ()

(* A cheap liveness read for GET /ready: one row of the metadata view proves
   the reader still answers without scanning any telemetry table. *)
let ping t =
  read t (fun runner ->
      q_select runner
        Q.Select.(
          from Meta.table Q.Projection.(one Meta.value)
          |> where Q.Expr.(eq Meta.key "schema_version")
          |> limit 1))
  |> Result.map (fun _ -> ())

let with_db ~caps ~sw ?now_ms ?report config f =
  let open Result.Syntax in
  let* store = open_ ~caps ~sw ?now_ms ?report config in
  let result = f store in
  let closed = close store in
  match result with Error _ -> result | Ok value -> Result.map (fun () -> value) closed

(* Writes ------------------------------------------------------------------ *)

let note_failure t message =
  t.ingest_failures <- t.ingest_failures + 1;
  t.last_ingest_failure <- Some { Model.failed_at_ms = t.wall_now (); message }

(* After a write, the active segment is measured; when it holds its share of
   the budget, the next slot becomes active and its old data is deleted
   with its file (bcache-r1ng, bcache-f1le). *)
let rotate t =
  let open Result.Syntax in
  let next = (t.active + 1) mod segment_count in
  let segment = t.segments.(next) in
  let sequence = t.segments.(t.active).sequence + 1 in
  let* () = t.create_segment segment ~sequence in
  let* writer = t.open_writer segment.path in
  let previous = t.writer in
  t.writer <- writer;
  t.active <- next;
  t.generation <- t.generation + 1;
  Q.Pool.shutdown previous |> Result.map_error widen_pool_error

let after_write t =
  let open Result.Syntax in
  let* bytes = database_bytes t.writer in
  let active = t.segments.(t.active) in
  active.bytes <- bytes;
  if bytes >= segment_bytes t.config then rotate t else Ok ()

(* Every write holds the write lock, so a rotation never runs inside another
   write. A failed write is returned to the exporter and counted; a failed
   rotation is counted and retried after the next write (bcache-s7at). *)
let write t f =
  Eio.Mutex.use_rw ~protect:true t.write_lock (fun () ->
      let result = f t.writer in
      (match result with
      | Error error -> note_failure t (error_message error)
      | Ok _ -> (
          match after_write t with
          | Ok () -> ()
          | Error error ->
              let message = "segment rotation failed: " ^ error_message error in
              t.report message;
              note_failure t message));
      result)

let span_projection =
  Q.Projection.(
    map
      (fun ( ( trace_id,
               span_id,
               parent_span_id,
               service_name,
               scope_name,
               operation_name,
               kind,
               start_time_ns ),
             ( end_time_ns,
               duration_ms,
               status,
               status_message,
               attributes_json,
               resource_json,
               events_json, links_json ) ) ->
        {
          Model.trace_id;
          span_id;
          parent_span_id;
          service_name;
          scope_name;
          operation_name;
          kind = Option.bind kind Model.span_kind_of_string;
          start_time_ns;
          end_time_ns;
          duration_ms;
          status = Option.value (Model.span_status_of_string status) ~default:Model.Unset;
          status_message;
          attributes = attrs_of_json attributes_json;
          resource = attrs_of_json resource_json;
          events = events_of_json events_json;
          links = links_of_json links_json;
        })
      (t2
         (t8 (one Spans.trace_id) (one Spans.span_id) (one Spans.parent_span_id)
            (one Spans.service_name) (one Spans.scope_name)
            (one Spans.operation_name) (one Spans.kind) (one Spans.start_time_ns))
         (t8 (one Spans.end_time_ns) (one Spans.duration_ms) (one Spans.status)
            (one Spans.status_message) (one Spans.attributes_json)
            (one Spans.resource_json) (one Spans.events_json)
            (one Spans.links_json))))

let log_projection =
  Q.Projection.(
    map
      (fun ( id,
             ( ( trace_id,
                 span_id,
                 service_name,
                 scope_name,
                 severity_text,
                 severity_number,
                 timestamp_ns,
                 body ),
               (attributes_json, resource_json, observed_timestamp_ns) ) ) ->
        {
          Model.id;
          trace_id;
          span_id;
          service_name;
          scope_name;
          severity_text;
          severity_number;
          timestamp_ns;
          observed_timestamp_ns;
          body;
          attributes = attrs_of_json attributes_json;
          resource = attrs_of_json resource_json;
        })
      (t2 (one Logs.id)
         (t2
            (t8 (one Logs.trace_id) (one Logs.span_id) (one Logs.service_name)
               (one Logs.scope_name) (one Logs.severity_text)
               (one Logs.severity_number) (one Logs.timestamp_ns) (one Logs.body))
            (t3 (one Logs.attributes_json) (one Logs.resource_json)
              (one Logs.observed_timestamp_ns)))))

let metric_projection =
  Q.Projection.(
    map
      (fun ( ( service_name,
               scope_name,
               name,
               description,
               unit_,
               kind,
               start_time_ns,
               timestamp_ns ),
             (value, attributes_json, resource_json, raw_json) ) ->
        let raw_json =
          match Yojson.Safe.from_string raw_json with
          | json -> json
          | exception Yojson.Json_error _ -> `Assoc []
        in
        {
          Model.service_name;
          scope_name;
          name;
          description;
          unit_;
          kind;
          start_time_ns;
          timestamp_ns;
          value;
          attributes = attrs_of_json attributes_json;
          resource = attrs_of_json resource_json;
          raw_json;
        })
      (t2
         (t8 (one Metric_points.service_name) (one Metric_points.scope_name)
            (one Metric_points.name) (one Metric_points.description)
            (one Metric_points.unit_) (one Metric_points.kind)
            (one Metric_points.start_time_ns) (one Metric_points.timestamp_ns))
         (t4 (one Metric_points.value) (one Metric_points.attributes_json)
            (one Metric_points.resource_json) (one Metric_points.raw_json))))

let trace_summary_projection =
  Q.Projection.(
    map
      (fun ( ( trace_id,
               service_name,
               root_operation_name,
               started_at_ns,
               ended_at_ns,
               duration_ms,
               span_count,
               error_count ),
             (is_running, warning_count, dropped_span_count) ) ->
        {
          Model.trace_id;
          service_name;
          root_operation_name;
          started_at_ns;
          ended_at_ns;
          duration_ms;
          span_count;
          error_count;
          is_running;
          warning_count;
          dropped_span_count;
        })
      (t2
         (t8 (one Trace_summaries.trace_id) (one Trace_summaries.service_name)
            (one Trace_summaries.root_operation_name)
            (one Trace_summaries.started_at_ns) (one Trace_summaries.ended_at_ns)
            (one Trace_summaries.duration_ms) (one Trace_summaries.span_count)
            (one Trace_summaries.error_count))
         (t3 (one Trace_summaries.is_running)
            (one Trace_summaries.warning_count)
            (one Trace_summaries.dropped_span_count))))

let span_query trace_id =
    Q.Select.(
      from Spans.table span_projection
      |> where Q.Expr.(eq Spans.trace_id trace_id)
      |> order_by Spans.start_time_ns)

let select_spans_for_trace_pool runner trace_id =
  q_select_pool runner (span_query trace_id)

let select_spans_for_trace runner trace_id =
  q_select runner (span_query trace_id)

let span_id_query span_id =
  Q.Select.(
    from Spans.table span_projection
    |> where Q.Expr.(eq Spans.span_id span_id)
    |> order_by ~desc:true Spans.start_time_ns
    |> limit 1)

let logs_for_trace_query trace_id =
  Q.Select.(
    from Logs.table log_projection
    |> where Q.Expr.(eq Logs.trace_id (Some trace_id))
    |> order_by Logs.timestamp_ns)

let logs_for_span_query span_id =
  Q.Select.(
    from Logs.table log_projection
    |> where Q.Expr.(eq Logs.span_id (Some span_id))
    |> order_by Logs.timestamp_ns)

let sorted_unique values = List.sort_uniq String.compare values

let rec take count values =
  if count <= 0 then []
  else
    match values with
    | [] -> []
    | value :: rest -> value :: take (count - 1) rest

let rec drop count values =
  if count <= 0 then values
  else
    match values with
    | [] -> []
    | _ :: rest -> drop (count - 1) rest

(* Keyset pagination and resolved windows (win-edze, win-7xet, win-xi3q). The
   HTTP layer resolves the window and decodes the cursor; the store only
   compares rows against them, fetching one row past the page size so
   truncation is exact. *)

let window_predicate column (window : Model.window) =
  match window.start_ms with
  | None -> Q.Expr.true_
  | Some start_ms -> Q.Expr.ge column (start_ms * 1_000_000)

let keyset_predicate ~sort_key ~tie_breaker cursor =
  match cursor with
  | None -> Q.Expr.true_
  | Some position ->
      Q.Expr.or_
        (Q.Expr.lt sort_key position.Model.sort_key_ns)
        (Q.Expr.and_
           (Q.Expr.eq sort_key position.Model.sort_key_ns)
           (Q.Expr.lt tie_breaker position.Model.tie_breaker))

let page_of_rows ~limit ~position rows =
  if List.length rows > limit then
    let items = take limit rows in
    { items; next = Some (position (List.nth items (limit - 1))) }
  else { items = rows; next = None }

let empty_page = { items = []; next = None }

let span_position (span : Model.span) =
  { Model.sort_key_ns = span.start_time_ns; tie_breaker = span_row_id span }

let log_position (log : Model.log_record) =
  { Model.sort_key_ns = log.timestamp_ns; tie_breaker = log.id }

let trace_position (summary : Model.trace_summary) =
  { Model.sort_key_ns = summary.started_at_ns; tie_breaker = summary.trace_id }

let logs_for_trace_page_query ~window ~cursor ~limit trace_id =
  let max_rows = limit + 1 in
  Q.Select.(
    from Logs.table log_projection
    |> where
         Q.Expr.(
           and_ (eq Logs.trace_id (Some trace_id))
             (and_
                (window_predicate Logs.timestamp_ns window)
                (keyset_predicate ~sort_key:Logs.timestamp_ns
                   ~tie_breaker:Logs.id cursor)))
    |> order_by ~desc:true Logs.timestamp_ns
    |> order_by ~desc:true Logs.id
    |> limit max_rows)

let logs_for_span_page_query ~window ~cursor ~limit span_id =
  let max_rows = limit + 1 in
  Q.Select.(
    from Logs.table log_projection
    |> where
         Q.Expr.(
           and_ (eq Logs.span_id (Some span_id))
             (and_
                (window_predicate Logs.timestamp_ns window)
                (keyset_predicate ~sort_key:Logs.timestamp_ns
                   ~tie_breaker:Logs.id cursor)))
    |> order_by ~desc:true Logs.timestamp_ns
    |> order_by ~desc:true Logs.id
    |> limit max_rows)

let intersect_sorted left right =
  let right = String_set.of_list right in
  List.filter (fun value -> String_set.mem value right) left

let owner_trace_id owner_id =
  match String.index_opt owner_id ':' with
  | None -> owner_id
  | Some index -> String.sub owner_id 0 index

let attr_group_prefix = "attr."

let attr_group_key group_by =
  if String.starts_with ~prefix:attr_group_prefix group_by then
    Some
      (String.sub group_by (String.length attr_group_prefix)
         (String.length group_by - String.length attr_group_prefix))
  else None

let attr_value key attrs = Option.map Model.attr_string_value (List.assoc_opt key attrs)

let add_count table key =
  let count = Option.value (Hashtbl.find_opt table key) ~default:0 in
  Hashtbl.replace table key (count + 1)

let facet_items_from_counts limit table : Model.facet_item list =
  Hashtbl.fold
    (fun value count acc -> { Model.value; count } :: acc)
    table []
  |> List.sort (fun (left : Model.facet_item) (right : Model.facet_item) ->
         let by_count = compare right.Model.count left.Model.count in
         if by_count <> 0 then by_count else String.compare left.value right.value)
  |> take limit

let percentile p values =
  match List.sort Float.compare values with
  | [] -> 0.0
  | sorted ->
      let len = List.length sorted in
      let raw_index = int_of_float (ceil ((float_of_int len *. p) -. 1.0)) in
      let index = max 0 (min (len - 1) raw_index) in
      List.nth sorted index

let sort_stat_items limit (items : Model.stat_item list) =
  items
  |> List.sort (fun (left : Model.stat_item) (right : Model.stat_item) ->
         let by_value = Float.compare right.Model.value left.Model.value in
         if by_value <> 0 then by_value else String.compare left.group right.group)
  |> take limit

(* LIKE's pattern is built from literal user text; '%' and '_' have no wildcard
   meaning in filters (srch-zjff). Ox renders ESCAPE through its typed API. *)
let literal_like_pattern text =
  let b = Buffer.create (String.length text + 2) in
  Buffer.add_char b '%';
  String.iter (fun c ->
    if c = '%' || c = '_' || c = '\\' then Buffer.add_char b '\\';
    Buffer.add_char b c) text;
  Buffer.add_char b '%';
  Buffer.contents b

let span_attrs_predicate ?(contains = []) owner attrs =
  let exact = List.map (fun (key, value) -> (key, value, false)) attrs in
  let partial = List.map (fun (key, value) -> (key, value, true)) contains in
  List.fold_left (fun predicate (key, value, substring) ->
    let value_predicate =
      if substring then Q.Expr.like ~escape:'\\' Span_attributes.value
        (literal_like_pattern value)
      else Q.Expr.eq Span_attributes.value value in
    let owners = Q.Select.(
      from Span_attributes.table Q.Projection.(one Span_attributes.owner_id)
      |> where Q.Expr.(and_ (eq Span_attributes.key key) value_predicate)
      |> compile) in
    Q.Expr.and_ predicate (Q.Expr.in_select owner owners))
    Q.Expr.true_ (exact @ partial)

let log_attrs_predicate ?(contains = []) owner attrs =
  let exact = List.map (fun (key, value) -> (key, value, false)) attrs in
  let partial = List.map (fun (key, value) -> (key, value, true)) contains in
  List.fold_left (fun predicate (key, value, substring) ->
    let value_predicate =
      if substring then Q.Expr.like ~escape:'\\' Log_attributes.value
        (literal_like_pattern value)
      else Q.Expr.eq Log_attributes.value value in
    let owners = Q.Select.(
      from Log_attributes.table Q.Projection.(one Log_attributes.owner_id)
      |> where Q.Expr.(and_ (eq Log_attributes.key key) value_predicate)
      |> compile) in
    Q.Expr.and_ predicate (Q.Expr.in_select owner owners))
    Q.Expr.true_ (exact @ partial)

let span_attr_values_for_key runner key =
  q_select runner Q.Select.(
    from Span_attributes.table
      Q.Projection.(t2 (one Span_attributes.owner_id) (one Span_attributes.value))
    |> where Q.Expr.(eq Span_attributes.key key))

let parent_span_ids_for_operation runner ?service operation =
  let predicate =
    match service with
    | None -> Q.Expr.eq Spans.operation_name operation
    | Some service ->
        Q.Expr.and_ (Q.Expr.eq Spans.operation_name operation)
          (Q.Expr.eq Spans.service_name service)
  in
  q_select runner
    Q.Select.(
      from Spans.table Q.Projection.(one Spans.span_id)
      |> where predicate)

let short_attr_values attrs =
  List.filter_map
    (fun (key, attr_value) ->
      let text = Model.attr_string_value attr_value in
      if String.length text <= max_indexed_value_bytes then Some (key, text) else None)
    attrs

(* Ingest builds every statement with the pure functions below and runs them
   inside one transaction callback that touches only its own runner, through
   local closures and loops, so the transaction-runner gate can follow every
   statement to the callback's runner. *)

let span_attrs_delete owner_id =
  Q.Delete.(
    from Span_attributes.table
    |> where Q.Expr.(eq Span_attributes.owner_id owner_id)
    |> compile)

let span_attr_insert owner_id (key, text) =
  Q.Insert.(
    into Span_attributes.table
    |> value Span_attributes.owner_id owner_id
    |> value Span_attributes.key key
    |> value Span_attributes.value text
    |> compile)

let log_attr_insert owner_id (key, text) =
  Q.Insert.(
    into Log_attributes.table
    |> value Log_attributes.owner_id owner_id
    |> value Log_attributes.key key
    |> value Log_attributes.value text
    |> compile)

let metric_attr_insert owner_id (key, text) =
  Q.Insert.(
    into Metric_attributes.table
    |> value Metric_attributes.owner_id owner_id
    |> value Metric_attributes.key key
    |> value Metric_attributes.value text
    |> compile)

(* The part of one trace in the active segment, computed from a light
   projection of its spans there: ids, parent, names, times, and status. The
   span cap bounds that projection, so the memory of a write depends on the
   batch, not on the length of the trace (bcache-m3m0). *)
type part_span = {
  part_span_id : string;
  part_parent : string option;
  part_service : string;
  part_operation : string;
  part_start : int;
  part_end : int;
  part_status : string;
}

let part_span_projection =
  Q.Projection.(
    map
      (fun ((part_span_id, part_parent, part_service, part_operation),
            (part_start, part_end, part_status)) ->
        { part_span_id; part_parent; part_service; part_operation; part_start;
          part_end; part_status })
      (t2
         (t4 (one Spans.span_id) (one Spans.parent_span_id)
            (one Spans.service_name) (one Spans.operation_name))
         (t3 (one Spans.start_time_ns) (one Spans.end_time_ns) (one Spans.status))))

let part_spans_select trace_id =
  Q.Select.(
    from Spans.table part_span_projection
    |> where Q.Expr.(eq Spans.trace_id trace_id)
    |> compile)

let stored_part_select trace_id =
  Q.Select.(
    from Trace_parts.table
      Q.Projection.(t2 (one Trace_parts.span_count) (one Trace_parts.dropped_span_count))
    |> where Q.Expr.(eq Trace_parts.trace_id trace_id)
    |> limit 1
    |> compile)

type part = {
  service_name : string;
  root_operation_name : string;
  has_root : bool;
  started_at_ns : int;
  ended_at_ns : int;
  span_count : int;
  error_count : int;
  running_count : int;
  root_count : int;
  missing_parent_count : int;
}

let part_running span = span.part_end = 0 || span.part_end < span.part_start

(* The first root in tree order: a span without a parent, else a span whose
   parent is not in the segment, by start time and then span id, as in
   [Trace_tree.assemble]. *)
let part_of_spans spans =
  let ids = Hashtbl.create (List.length spans) in
  List.iter (fun span -> Hashtbl.replace ids span.part_span_id ()) spans;
  let missing span =
    match span.part_parent with
    | Some parent -> not (Hashtbl.mem ids parent)
    | None -> false
  in
  let order left right =
    let by_start = compare left.part_start right.part_start in
    if by_start <> 0 then by_start else String.compare left.part_span_id right.part_span_id
  in
  let roots = List.filter (fun span -> span.part_parent = None) spans in
  let orphans = List.filter missing spans in
  let first = function [] -> None | spans -> Some (List.hd (List.sort order spans)) in
  let root =
    match first (roots @ orphans) with
    | Some span -> Some span
    | None -> first spans
  in
  let count predicate = List.length (List.filter predicate spans) in
  let started_at_ns =
    List.fold_left (fun acc span -> min acc span.part_start) max_int spans
  in
  let ended_at_ns =
    List.fold_left
      (fun acc span ->
        max acc (if part_running span then span.part_start else span.part_end))
      started_at_ns spans
  in
  match root with
  | None -> None
  | Some root ->
      Some
        {
          service_name = root.part_service;
          root_operation_name = root.part_operation;
          has_root = roots <> [];
          started_at_ns;
          ended_at_ns;
          span_count = List.length spans;
          error_count = count (fun span -> String.equal span.part_status "error");
          running_count = count part_running;
          root_count = List.length roots;
          missing_parent_count = List.length orphans;
        }

let part_upsert ~now_ms trace_id ~dropped part =
  Q.Insert.(
    into Trace_parts.table
    |> value Trace_parts.trace_id trace_id
    |> value Trace_parts.service_name part.service_name
    |> value Trace_parts.root_operation_name part.root_operation_name
    |> value Trace_parts.has_root part.has_root
    |> value Trace_parts.started_at_ns part.started_at_ns
    |> value Trace_parts.ended_at_ns part.ended_at_ns
    |> value Trace_parts.span_count part.span_count
    |> value Trace_parts.error_count part.error_count
    |> value Trace_parts.running_count part.running_count
    |> value Trace_parts.root_count part.root_count
    |> value Trace_parts.missing_parent_count part.missing_parent_count
    |> value Trace_parts.dropped_span_count dropped
    |> value Trace_parts.updated_at_ms now_ms
    |> on_conflict_update [ Q.Column.any Trace_parts.trace_id ]
         ~set:[ Q.Column.any Trace_parts.service_name;
                Q.Column.any Trace_parts.root_operation_name;
                Q.Column.any Trace_parts.has_root;
                Q.Column.any Trace_parts.started_at_ns;
                Q.Column.any Trace_parts.ended_at_ns;
                Q.Column.any Trace_parts.span_count;
                Q.Column.any Trace_parts.error_count;
                Q.Column.any Trace_parts.running_count;
                Q.Column.any Trace_parts.root_count;
                Q.Column.any Trace_parts.missing_parent_count;
                Q.Column.any Trace_parts.dropped_span_count;
                Q.Column.any Trace_parts.updated_at_ms ]
    |> compile)

let span_upsert ~now_ms (span : Model.span) =
  Q.Insert.(
    into Spans.table
    |> value Spans.id (span_row_id span)
    |> value Spans.trace_id span.trace_id
    |> value Spans.span_id span.span_id
    |> value Spans.parent_span_id span.parent_span_id
    |> value Spans.service_name span.service_name
    |> value Spans.scope_name span.scope_name
    |> value Spans.operation_name span.operation_name
    |> value Spans.kind (Option.map Model.span_kind_to_string span.kind)
    |> value Spans.start_time_ns span.start_time_ns
    |> value Spans.end_time_ns span.end_time_ns
    |> value Spans.duration_ms span.duration_ms
    |> value Spans.status (Model.span_status_to_string span.status)
    |> value Spans.status_message span.status_message
    |> value Spans.attributes_json (Model.attrs_json_string span.attributes)
    |> value Spans.resource_json (Model.attrs_json_string span.resource)
    |> value Spans.events_json (events_json span.events)
    |> value Spans.links_json (links_json span.links)
    |> value Spans.ingested_at_ms now_ms
    |> on_conflict_update [ Q.Column.any Spans.id ]
         ~set:[ Q.Column.any Spans.trace_id; Q.Column.any Spans.span_id;
                Q.Column.any Spans.parent_span_id;
                Q.Column.any Spans.service_name; Q.Column.any Spans.scope_name;
                Q.Column.any Spans.operation_name; Q.Column.any Spans.kind;
                Q.Column.any Spans.start_time_ns; Q.Column.any Spans.end_time_ns;
                Q.Column.any Spans.duration_ms; Q.Column.any Spans.status;
                Q.Column.any Spans.status_message;
                Q.Column.any Spans.attributes_json; Q.Column.any Spans.resource_json;
                Q.Column.any Spans.events_json; Q.Column.any Spans.links_json;
                Q.Column.any Spans.ingested_at_ms ]
    |> compile)

let trace_service_insert (span : Model.span) =
  Q.Insert.(
    into Trace_services.table
    |> value Trace_services.trace_id span.trace_id
    |> value Trace_services.service_name span.service_name
    |> on_conflict_do_nothing
         [ Q.Column.any Trace_services.trace_id;
           Q.Column.any Trace_services.service_name ]
    |> compile)

(* Spans of one trace keep their batch order. *)
let group_by_trace (spans : Model.span list) =
  let order = ref [] in
  let groups = Hashtbl.create 16 in
  List.iter
    (fun (span : Model.span) ->
      match Hashtbl.find_opt groups span.trace_id with
      | Some spans -> Hashtbl.replace groups span.trace_id (span :: spans)
      | None ->
          order := span.trace_id :: !order;
          Hashtbl.replace groups span.trace_id [ span ])
    spans;
  List.rev_map (fun trace_id -> (trace_id, List.rev (Hashtbl.find groups trace_id))) !order

(* The statements of one trace: kept spans with their short attribute values
   and services, before the trace part is computed. *)
type trace_statements = {
  trace_id : string;
  spans : (Q.Compiled.change * Q.Compiled.change * Q.Compiled.change array * Q.Compiled.change) array;
  received : int;
}

let trace_statements ~now_ms (trace_id, (spans : Model.span list)) =
  {
    trace_id;
    received = List.length spans;
    spans =
      Array.of_list
        (List.map
           (fun (span : Model.span) ->
             let owner_id = span_row_id span in
             ( span_upsert ~now_ms span,
               span_attrs_delete owner_id,
               Array.of_list
                 (List.map (span_attr_insert owner_id)
                    (short_attr_values (span.resource @ span.attributes))),
               trace_service_insert span ))
           spans);
  }

let ingest_traces t spans =
  let spans = List.map Ingest_limits.span spans in
  let now_ms = t.now_ms () in
  let traces = Array.of_list (List.map (trace_statements ~now_ms) (group_by_trace spans)) in
  write t (fun writer ->
      Q.Pool.with_transaction writer (fun tx ->
          let failure = ref None in
          let accepted = ref 0 in
          let run statement =
            match !failure with
            | Some _ -> ()
            | None -> (
                match Q.Pool.Typed.execute_compiled tx statement with
                | Ok _ -> ()
                | Error error -> failure := Some error)
          in
          let ingest trace =
            match Q.Pool.Typed.select tx (stored_part_select trace.trace_id) with
            | Error error -> failure := Some error
            | Ok stored -> (
                let stored_count, stored_dropped =
                  match stored with row :: _ -> row | [] -> (0, 0)
                in
                let kept =
                  min (Array.length trace.spans)
                    (max 0 (max_trace_spans_per_segment - stored_count))
                in
                for index = 0 to kept - 1 do
                  let span, delete_attrs, attrs, service = trace.spans.(index) in
                  run span;
                  run delete_attrs;
                  for attr = 0 to Array.length attrs - 1 do
                    run attrs.(attr)
                  done;
                  run service
                done;
                accepted := !accepted + kept;
                match !failure with
                | Some _ -> ()
                | None -> (
                    match Q.Pool.Typed.select tx (part_spans_select trace.trace_id) with
                    | Error error -> failure := Some error
                    | Ok part_spans -> (
                        match part_of_spans part_spans with
                        | None -> ()
                        | Some part ->
                            run
                              (part_upsert ~now_ms trace.trace_id
                                 ~dropped:(stored_dropped + trace.received - kept)
                                 part))))
          in
          for index = 0 to Array.length traces - 1 do
            if Option.is_none !failure then ingest traces.(index)
          done;
          match !failure with Some error -> Error error | None -> Ok !accepted)
      |> Result.map_error widen_pool_error)

let log_insert ~now_ms id (log : Model.log_record) =
  let timestamp_ns = if log.timestamp_ns = 0 then now_ms * 1_000_000 else log.timestamp_ns in
  Q.Insert.(
    into Logs.table
    |> value Logs.id id
    |> value Logs.trace_id log.trace_id
    |> value Logs.span_id log.span_id
    |> value Logs.service_name log.service_name
    |> value Logs.scope_name log.scope_name
    |> value Logs.severity_text log.severity_text
    |> value Logs.severity_normalized (String.uppercase_ascii log.severity_text)
    |> value Logs.severity_number log.severity_number
    |> value Logs.timestamp_ns timestamp_ns
    |> value Logs.observed_timestamp_ns log.observed_timestamp_ns
    |> value Logs.body log.body
    |> value Logs.attributes_json (Model.attrs_json_string log.attributes)
    |> value Logs.resource_json (Model.attrs_json_string log.resource)
    |> value Logs.ingested_at_ms now_ms
    |> compile)

let metric_insert ~now_ms id (point : Model.metric_point) =
  Q.Insert.(
    into Metric_points.table
    |> value Metric_points.id id
    |> value Metric_points.service_name point.service_name
    |> value Metric_points.scope_name point.scope_name
    |> value Metric_points.name point.name
    |> value Metric_points.description point.description
    |> value Metric_points.unit_ point.unit_
    |> value Metric_points.kind point.kind
    |> value Metric_points.start_time_ns point.start_time_ns
    |> value Metric_points.timestamp_ns point.timestamp_ns
    |> value Metric_points.value point.value
    |> value Metric_points.attributes_json
         (Model.attrs_json_string point.attributes)
    |> value Metric_points.resource_json (Model.attrs_json_string point.resource)
    |> value Metric_points.raw_json (Yojson.Safe.to_string point.raw_json)
    |> value Metric_points.ingested_at_ms now_ms
    |> compile)

(* Run a list of independent statements in one transaction. *)
let write_statements t statements =
  let statements = Array.of_list statements in
  write t (fun writer ->
      Q.Pool.with_transaction writer (fun tx ->
          let failure = ref None in
          for index = 0 to Array.length statements - 1 do
            if Option.is_none !failure then
              match Q.Pool.Typed.execute_compiled tx statements.(index) with
              | Ok _ -> ()
              | Error error -> failure := Some error
          done;
          match !failure with Some error -> Error error | None -> Ok ())
      |> Result.map_error widen_pool_error)

let ingest_logs t logs =
  let logs = List.map Ingest_limits.log logs in
  let now_ms = t.now_ms () in
  let statements =
    List.concat_map
      (fun (log : Model.log_record) ->
        let id = fresh_id t.wall_now "log" in
        log_insert ~now_ms id log
        :: List.map (log_attr_insert id) (short_attr_values (log.resource @ log.attributes)))
      logs
  in
  write_statements t statements |> Result.map (fun () -> List.length logs)

let ingest_metrics t points =
  let points = List.map Ingest_limits.metric_point points in
  let now_ms = t.now_ms () in
  let statements =
    List.concat_map
      (fun (point : Model.metric_point) ->
        let id = fresh_id t.wall_now "metric" in
        metric_insert ~now_ms id point
        :: List.map (metric_attr_insert id)
             (short_attr_values (point.resource @ point.attributes)))
      points
  in
  write_statements t statements |> Result.map (fun () -> List.length points)

let trace_service_predicate trace_id service =
  let participating = Q.Select.(
    from Trace_services.table Q.Projection.(one Trace_services.trace_id)
    |> where Q.Expr.(eq Trace_services.service_name service)
    |> compile) in
  Q.Expr.in_select trace_id participating

let list_services_runner ?window ?(include_metrics = false) runner =
  let window = Option.value window ~default:Model.window_all in
  let open Result.Syntax in
  let* span_services =
    q_select runner
      Q.Select.(
        from Spans.table Q.Projection.(one Spans.service_name)
        |> where (window_predicate Spans.start_time_ns window)
        |> distinct
        |> order_by Spans.service_name)
  in
  let* log_services =
    q_select runner
      Q.Select.(
        from Logs.table Q.Projection.(one Logs.service_name)
        |> where (window_predicate Logs.timestamp_ns window)
        |> distinct
        |> order_by Logs.service_name)
  in
  let* metric_services =
    if include_metrics then
      q_select runner Q.Select.(
        from Metric_points.table Q.Projection.(one Metric_points.service_name)
        |> where (window_predicate Metric_points.timestamp_ns window)
        |> distinct
        |> order_by Metric_points.service_name)
    else Ok []
  in
  Ok
    (List.sort_uniq String.compare
       (span_services @ log_services @ metric_services))

let list_services ?window ?include_metrics t =
  read t (list_services_runner ?window ?include_metrics)

let list_trace_summaries ?service ~window ?cursor ~limit t =
  read t @@ fun runner ->
  let predicate =
    match service with
    | None -> Q.Expr.true_
    | Some service -> trace_service_predicate Trace_summaries.trace_id service
  in
  let predicate =
    Q.Expr.and_ predicate
      (window_predicate Trace_summaries.started_at_ns window)
  in
  let predicate =
    Q.Expr.and_ predicate
      (keyset_predicate ~sort_key:Trace_summaries.started_at_ns
         ~tie_breaker:Trace_summaries.trace_id cursor)
  in
  let max_rows = limit + 1 in
  let query =
    Q.Select.(
      from Trace_summaries.table trace_summary_projection
      |> where predicate
      |> order_by ~desc:true Trace_summaries.started_at_ns
      |> order_by ~desc:true Trace_summaries.trace_id
      |> limit max_rows)
  in
  q_select runner query
  |> Result.map (page_of_rows ~limit ~position:trace_position)

let summary_of_tree trace_id (tree : Trace_tree.t) : Model.trace_summary =
  {
    Model.trace_id;
    service_name = tree.root_service_name;
    root_operation_name = tree.root_operation_name;
    started_at_ns = tree.started_at_ns;
    ended_at_ns = tree.ended_at_ns;
    duration_ms = tree.duration_ms;
    span_count = tree.span_count;
    error_count = tree.error_count;
    is_running = tree.is_running;
    warning_count = List.length tree.warnings;
    dropped_span_count = 0;
  }

(* A trace is served whenever it has spans (tree-ddll). The detail computes
   its summary from the complete span tree; only the dropped span count comes
   from the stored trace parts (bcache-s5kc). *)
let get_trace t trace_id =
  read t @@ fun runner ->
  let open Result.Syntax in
  let* summaries =
    q_select runner
      Q.Select.(
        from Trace_summaries.table trace_summary_projection
        |> where Q.Expr.(eq Trace_summaries.trace_id trace_id)
        |> limit 1)
  in
  let* stored = one_or_none "trace summary lookup" summaries in
  let* spans = select_spans_for_trace runner trace_id in
  match spans with
  | [] -> Ok None
  | spans ->
      let tree = Trace_tree.assemble spans in
      let summary = summary_of_tree trace_id tree in
      let summary =
        match stored with
        | Some (stored : Model.trace_summary) ->
            { summary with dropped_span_count = stored.dropped_span_count }
        | None -> summary
      in
      let* logs = q_select runner (logs_for_trace_query trace_id) in
      Ok
        (Some
           {
             Model.summary;
             spans = tree.nodes;
             logs;
             warnings = tree.warnings;
           })

let get_span t span_id =
  read t @@ fun runner ->
  let open Result.Syntax in
  let* spans = q_select runner (span_id_query span_id) in
  one_or_none "span lookup" spans

(* The span detail carries the same tree context as the trace it belongs to, so
   one lookup is enough to place a span (tree-o79f). *)
let get_span_node t span_id =
  read t @@ fun runner ->
  let open Result.Syntax in
  let* spans = q_select runner (span_id_query span_id) in
  match spans with
  | [] -> Ok None
  | span :: _ ->
      let* siblings = select_spans_for_trace runner span.Model.trace_id in
      let tree = Trace_tree.assemble siblings in
      let node =
        List.find_opt
          (fun (node : Model.span_node) -> node.span.span_id = span_id)
          tree.nodes
      in
      (match node with
      | Some node -> Ok (Some node)
      | None ->
          Ok
            (Some
               {
                 Model.span;
                 depth = 0;
                 parent_operation_name = None;
                 root_operation_name = span.operation_name;
                 is_running = Trace_tree.is_running_span span;
                 warnings = [];
               }))

(* The tree-ordered trace span list filters on the same window as every other
   list query, then orders in the tree module (tree-uv04). *)
let select_spans_for_trace_in_window trace_id window =
  Q.Select.(
    from Spans.table span_projection
    |> where
         Q.Expr.(
           and_ (eq Spans.trace_id trace_id)
             (window_predicate Spans.start_time_ns window))
    |> order_by Spans.start_time_ns)

(* [/traces/{id}/spans] returns the same tree order as the trace detail
   (tree-uv04). A trace is small, so the page is sliced from the assembled
   tree; the cursor carries the position in that tree order. *)
let list_trace_spans t ~window ?cursor ~limit trace_id =
  read t @@ fun runner ->
  let open Result.Syntax in
  let* spans = q_select runner (select_spans_for_trace_in_window trace_id window) in
  let tree = Trace_tree.assemble spans in
  let nodes = tree.nodes in
  let start = match cursor with
    | None -> 0
    | Some position -> max 0 (position.Model.sort_key_ns + 1) in
  let remaining = drop start nodes in
  let items = take limit remaining in
  let next =
    match items with
    | [] -> None
    | _ when List.length remaining > limit ->
        let last = List.nth items (List.length items - 1) in
        Some
          {
            Model.sort_key_ns = start + List.length items - 1;
            tie_breaker = last.Model.span.span_id;
          }
    | _ -> None
  in
  Ok { items; next }

let list_trace_logs t ~window ?cursor ~limit trace_id =
  read t @@ fun runner ->
  q_select runner (logs_for_trace_page_query ~window ~cursor ~limit trace_id)
  |> Result.map (page_of_rows ~limit ~position:log_position)

let list_span_logs t ~window ?cursor ~limit span_id =
  read t @@ fun runner ->
  q_select runner (logs_for_span_page_query ~window ~cursor ~limit span_id)
  |> Result.map (page_of_rows ~limit ~position:log_position)

(* The self-join tests both span and trace IDs; an unrelated trace's matching
   operation cannot qualify a child (srch-ypr2). *)
let parent_operation_predicate operation =
  let parent_table = Q.Table.alias Spans.table "parent" in
  let parent_trace = Q.Table.column parent_table "trace_id" Q.text in
  let parent_span = Q.Table.column parent_table "span_id" Q.text in
  let parent_operation = Q.Table.column parent_table "operation_name" Q.text in
  let child col = Q.Scope.column (Q.Scope.left Q.Scope.self) col in
  let parent col = Q.Scope.column Q.Scope.right col in
  let on = Q.Expr.(and_
    (eq_col (child Spans.trace_id) (parent parent_trace))
    (eq_expr (col (child Spans.parent_span_id))
      (col (Q.Scope.nullable_column Q.Scope.right parent_span)))) in
  let source = Q.Source.(join ~on parent_table (from Spans.table)) in
  let ids = Q.Select.(
    from_source source Q.Projection.(one (child Spans.id))
    |> where (Q.Expr.like ~escape:'\\' (parent parent_operation)
      (literal_like_pattern operation))
    |> compile) in
  Q.Expr.in_select Spans.id ids

let span_search_predicate ?(attr_contains = []) ?min_duration_ms
    (filter : span_search_filter) =
  let p = Q.Expr.and_ (span_attrs_predicate ~contains:attr_contains Spans.id filter.attrs)
      (window_predicate Spans.start_time_ns filter.window) in
  let p = match filter.service with None -> p | Some x -> Q.Expr.and_ p (Q.Expr.eq Spans.service_name x) in
  let p = match filter.trace_id with None -> p | Some x -> Q.Expr.and_ p (Q.Expr.eq Spans.trace_id x) in
  let p = match filter.operation with None -> p | Some x ->
    Q.Expr.and_ p (Q.Expr.like ~escape:'\\' Spans.operation_name (literal_like_pattern x)) in
  let p = match filter.parent_operation with None -> p | Some x ->
    Q.Expr.and_ p (parent_operation_predicate x) in
  let p = match min_duration_ms with None -> p | Some x ->
    Q.Expr.and_ p (Q.Expr.ge Spans.duration_ms x) in
  let p = match filter.status with
    | None -> p
    | Some "ok" -> Q.Expr.and_ p Q.Expr.(not_ (eq Spans.status "error"))
    | Some x -> Q.Expr.and_ p (Q.Expr.eq Spans.status x) in
  Q.Expr.and_ p (keyset_predicate ~sort_key:Spans.start_time_ns ~tie_breaker:Spans.id filter.cursor)

let search_spans ?(attr_contains = []) ?min_duration_ms (filter : span_search_filter) t =
  read t @@ fun runner ->
  q_select runner Q.Select.(
    from Spans.table span_projection
    |> where (span_search_predicate ~attr_contains ?min_duration_ms filter)
    |> order_by ~desc:true Spans.start_time_ns
    |> order_by ~desc:true Spans.id
    |> limit (filter.limit + 1))
  |> Result.map (page_of_rows ~limit:filter.limit ~position:span_position)

let trace_summary_predicate ?(attr_contains = []) ?min_duration_ms
    (filter : trace_search_filter) =
  let p = Q.Expr.and_ (window_predicate Trace_summaries.started_at_ns filter.window)
      (keyset_predicate ~sort_key:Trace_summaries.started_at_ns ~tie_breaker:Trace_summaries.trace_id filter.cursor) in
  let p = match filter.service with None -> p | Some x -> Q.Expr.and_ p (trace_service_predicate Trace_summaries.trace_id x) in
  let p = match filter.status with
    | None -> p
    | Some "error" -> Q.Expr.and_ p (Q.Expr.gt Trace_summaries.error_count 0)
    | Some "ok" -> Q.Expr.and_ p (Q.Expr.eq Trace_summaries.error_count 0)
    | Some _ -> p in
  let p = match min_duration_ms with None -> p | Some x ->
    Q.Expr.and_ p (Q.Expr.ge Trace_summaries.duration_ms x) in
  if Option.is_none filter.operation && filter.attrs = [] && attr_contains = [] then p
  else
    let span_p = Q.Expr.and_ (window_predicate Spans.start_time_ns filter.window)
        (span_attrs_predicate ~contains:attr_contains Spans.id filter.attrs) in
    let span_p = match filter.operation with None -> span_p | Some x ->
      Q.Expr.and_ span_p (Q.Expr.like ~escape:'\\' Spans.operation_name (literal_like_pattern x)) in
    let matching = Q.Select.(from Spans.table Q.Projection.(one Spans.trace_id)
      |> where span_p |> compile) in
    Q.Expr.and_ p (Q.Expr.in_select Trace_summaries.trace_id matching)

let trace_summary_search_query ?(attr_contains = []) ?min_duration_ms
    (filter : trace_search_filter) =
  Q.Select.(from Trace_summaries.table trace_summary_projection
    |> where (trace_summary_predicate ~attr_contains ?min_duration_ms filter)
    |> order_by ~desc:true Trace_summaries.started_at_ns
    |> order_by ~desc:true Trace_summaries.trace_id
    |> limit (filter.limit + 1))

let search_traces ?(attr_contains = []) ?min_duration_ms
    (filter : trace_search_filter) t =
  read t @@ fun runner ->
  q_select runner (trace_summary_search_query ~attr_contains ?min_duration_ms filter)
  |> Result.map (page_of_rows ~limit:filter.limit ~position:trace_position)

let severity_predicate ?min_severity severity =
  let p = match severity with None -> Q.Expr.true_ | Some x ->
    Q.Expr.eq Logs.severity_normalized (String.uppercase_ascii x) in
  match min_severity with
  | None -> p
  | Some minimum ->
      let text_levels =
        [ (1, [ "TRACE"; "TRACE2"; "TRACE3"; "TRACE4" ]);
          (5, [ "DEBUG"; "DEBUG2"; "DEBUG3"; "DEBUG4" ]);
          (9, [ "INFO"; "INFO2"; "INFO3"; "INFO4" ]);
          (13, [ "WARN"; "WARNING"; "WARN2"; "WARN3"; "WARN4" ]);
          (17, [ "ERROR"; "ERROR2"; "ERROR3"; "ERROR4" ]);
          (21, [ "FATAL"; "FATAL2"; "FATAL3"; "FATAL4" ]) ]
        |> List.filter_map (fun (level, names) ->
             if level >= minimum then Some names else None)
        |> List.concat in
      Q.Expr.and_ p Q.Expr.(or_
        (ge Logs.severity_number (Some minimum))
        (and_ (is_null Logs.severity_number)
          (in_values Logs.severity_normalized text_levels)))

let log_predicate ?min_severity (filter : log_filter) =
  let predicate = Q.Expr.true_ in
  let predicate =
    match filter.service with
    | None -> predicate
    | Some service -> Q.Expr.and_ predicate (Q.Expr.eq Logs.service_name service)
  in
  let predicate =
    match filter.severity with
    | None -> predicate
    | Some severity -> Q.Expr.and_ predicate (severity_predicate (Some severity))
  in
  let predicate =
    match filter.contains with
    | None -> predicate
    | Some contains ->
        Q.Expr.and_ predicate (Q.Expr.like ~escape:'\\' Logs.body (literal_like_pattern contains))
  in
  let predicate = Q.Expr.and_ predicate (severity_predicate ?min_severity None) in
  let predicate =
    Q.Expr.and_ predicate (window_predicate Logs.timestamp_ns filter.window)
  in
  Q.Expr.and_ predicate
    (keyset_predicate ~sort_key:Logs.timestamp_ns ~tie_breaker:Logs.id
       filter.cursor)

let list_logs ?min_severity (filter : log_filter) t =
  read t @@ fun runner ->
  q_select runner
    Q.Select.(
      from Logs.table log_projection
      |> where (log_predicate ?min_severity filter)
      |> order_by ~desc:true Logs.timestamp_ns
      |> order_by ~desc:true Logs.id
      |> limit (filter.limit + 1))
  |> Result.map (page_of_rows ~limit:filter.limit ~position:log_position)

let log_search_predicate ?(attr_contains = []) ?min_severity
    (filter : log_search_filter) =
  let p = Q.Expr.and_ (window_predicate Logs.timestamp_ns filter.window)
      (log_attrs_predicate ~contains:attr_contains Logs.id filter.attrs) in
  let p = match filter.service with None -> p | Some x -> Q.Expr.and_ p (Q.Expr.eq Logs.service_name x) in
  let p = match filter.trace_id with None -> p | Some x -> Q.Expr.and_ p (Q.Expr.eq Logs.trace_id (Some x)) in
  let p = match filter.span_id with None -> p | Some x -> Q.Expr.and_ p (Q.Expr.eq Logs.span_id (Some x)) in
  let p = Q.Expr.and_ p (severity_predicate ?min_severity filter.severity) in
  let p = match filter.body with None -> p | Some x -> Q.Expr.and_ p (Q.Expr.like ~escape:'\\' Logs.body (literal_like_pattern x)) in
  Q.Expr.and_ p (keyset_predicate ~sort_key:Logs.timestamp_ns ~tie_breaker:Logs.id filter.cursor)

let search_logs ?(attr_contains = []) ?min_severity (filter : log_search_filter) t =
  read t @@ fun runner ->
  q_select runner Q.Select.(from Logs.table log_projection
    |> where (log_search_predicate ~attr_contains ?min_severity filter)
    |> order_by ~desc:true Logs.timestamp_ns
    |> order_by ~desc:true Logs.id
    |> limit (filter.limit + 1))
  |> Result.map (page_of_rows ~limit:filter.limit ~position:log_position)

module Ranked_trace_duration = struct
  module T = Q.Table.Make (struct let name = "ranked_trace_duration" end)
  include T
  let duration_ms = column "duration_ms" Q.float
  let rank = column "rank" Q.int
end

module Trace_stat_pairs = struct
  module T = Q.Table.Make (struct let name = "trace_stat_pairs" end)
  include T
  let owner_id = column "owner_id" Q.text
  let value = column "value" Q.text
end

module Trace_stat_rows = struct
  module T = Q.Table.Make (struct let name = "trace_stat_rows" end)
  include T
  let value = column "value" Q.text
  let duration_ms = column "duration_ms" Q.float
  let error_flag = column "error_flag" Q.int
end

let trace_stats ?(attr_contains = []) ?min_duration_ms (filter : trace_stats_filter) t =
  read t @@ fun runner ->
  let open Result.Syntax in
  let search_filter : trace_search_filter = {
    service = filter.service; operation = filter.operation;
    status = filter.status; attrs = filter.attrs;
    window = filter.window; cursor = None; limit = filter.limit;
  } in
  let predicate = trace_summary_predicate ~attr_contains ?min_duration_ms search_filter in
  let stat_for_group group count avg error_count group_pred =
    let* value =
      if filter.agg <> "p95_duration" || count = 0 then
        Ok (match filter.agg with
          | "avg_duration" -> Option.value avg ~default:0.
          | "error_rate" -> float_of_int error_count /. float_of_int (max 1 count)
          | _ -> float_of_int count)
      else
        (* The CTE projects only durations; SQLite computes ROW_NUMBER over the
           complete filtered group, never a sampled span page (acc-7kkc). *)
        let ranked = Q.Select.(
          from Trace_summaries.table Q.Projection.(t2
            (one Trace_summaries.duration_ms)
            (row_number ~as_:"rank" ~order_by:Trace_summaries.duration_ms ()))
          |> where Q.Expr.(and_ predicate (group_pred ()))
          |> compile) in
        let wanted = int_of_float (ceil (0.95 *. float_of_int count)) in
        let* durations = q_select runner Q.Select.(
          from Ranked_trace_duration.table Q.Projection.(one Ranked_trace_duration.duration_ms)
          |> with_cte ~name:"ranked_trace_duration" ranked
          |> where Q.Expr.(eq Ranked_trace_duration.rank wanted)) in
        Ok ((match durations with duration :: _ -> duration | [] -> 0.)) in
    Ok { Model.group; value; count } in
  let summaries col =
    q_select runner Q.Select.(
      from Trace_summaries.table Q.Projection.(t3
        (one col) (count ()) (avg Q.Numeric.float Trace_summaries.duration_ms))
      |> where predicate |> group_by col) in
  let errors col =
    q_select runner Q.Select.(
      from Trace_summaries.table Q.Projection.(t2 (one col) (count ()))
      |> where Q.Expr.(and_ predicate (gt Trace_summaries.error_count 0))
      |> group_by col) in
  let by_column col =
    let* groups = summaries col in
    let* error_groups = if filter.agg = "error_rate" then errors col
      else Ok [] in
    let error_counts = Hashtbl.create (List.length error_groups) in
    List.iter (fun (group, count) -> Hashtbl.replace error_counts group count) error_groups;
    let rec collect = function
      | [] -> Ok []
      | (group, count, avg) :: rest ->
          let* item = stat_for_group group count avg
            (Option.value (Hashtbl.find_opt error_counts group) ~default:0)
            (fun () -> Q.Expr.eq col group) in
          let* others = collect rest in
          Ok (item :: others) in
    let* items = collect groups in
    Ok (sort_stat_items filter.limit items) in
  match filter.group_by with
  | "service" -> by_column Trace_summaries.service_name
  | "operation" -> by_column Trace_summaries.root_operation_name
  | "status" ->
      let per_status group status_pred =
        let group_pred = Q.Expr.and_ predicate status_pred in
        let* counts = q_select runner Q.Select.(
          from Trace_summaries.table Q.Projection.(t2
            (count ()) (avg Q.Numeric.float Trace_summaries.duration_ms))
          |> where group_pred) in
        let count, avg = List.hd counts in
        if count = 0 then Ok None else
        let* item = stat_for_group group count avg
          (if group = "error" then count else 0) (fun () -> status_pred) in
        Ok (Some item) in
      let* ok = per_status "ok" Q.Expr.(eq Trace_summaries.error_count 0) in
      let* error = per_status "error" Q.Expr.(gt Trace_summaries.error_count 0) in
      Ok (sort_stat_items filter.limit (List.filter_map Fun.id [ok; error]))
  | group_by -> (match attr_group_key group_by with
      | None -> Ok []
      | Some key ->
          let filtered_trace_ids = Q.Select.(
            from Trace_summaries.table Q.Projection.(one Trace_summaries.trace_id)
            |> where predicate |> compile) in
          let left col = Q.Scope.column (Q.Scope.left Q.Scope.self) col in
          let right col = Q.Scope.column Q.Scope.right col in
          let source = Q.Source.(join Spans.table
            ~on:Q.Expr.(eq_col (left Span_attributes.owner_id) (right Spans.id))
            (from Span_attributes.table)) in
          let base_pred = Q.Expr.(and_
            (eq (left Span_attributes.key) key)
            (in_select (right Spans.trace_id) filtered_trace_ids)) in
           (* Distinct (trace, value) pairs prevent duplicate span attributes
              from multiplying trace totals. Group counts and errors in SQL;
              only exact p95 reads durations per group (acc-1ccu). *)
           let pairs = Q.Select.(
             from_source source Q.Projection.(t2
               (expr ~as_:"owner_id" Q.Expr.(col (right Spans.trace_id)))
               (expr ~as_:"value" Q.Expr.(col (left Span_attributes.value))))
             |> where base_pred |> distinct |> compile) in
           let pair_left col = Q.Scope.column (Q.Scope.left Q.Scope.self) col in
           let summary_right col = Q.Scope.column Q.Scope.right col in
           let pair_source = Q.Source.(join Trace_summaries.table
             ~on:Q.Expr.(eq_col (pair_left Trace_stat_pairs.owner_id)
               (summary_right Trace_summaries.trace_id))
             (from Trace_stat_pairs.table)) in
           let rows = Q.Select.(
             from_source pair_source Q.Projection.(t3
               (expr ~as_:"value" Q.Expr.(col (pair_left Trace_stat_pairs.value)))
               (expr ~as_:"duration_ms"
                 Q.Expr.(col (summary_right Trace_summaries.duration_ms)))
               (expr ~as_:"error_flag" Q.Expr.(case
                 [gt (summary_right Trace_summaries.error_count) 0, int_lit 1]
                 ~default:(int_lit 0))))
             |> with_cte ~name:"trace_stat_pairs" pairs |> compile) in
           let* groups = q_select runner Q.Select.(
             from Trace_stat_rows.table Q.Projection.(t4
               (one Trace_stat_rows.value) (count ())
               (avg Q.Numeric.float Trace_stat_rows.duration_ms)
               (sum_int Trace_stat_rows.error_flag))
             |> with_cte ~name:"trace_stat_rows" rows
             |> group_by Trace_stat_rows.value) in
           let rec collect = function
             | [] -> Ok []
             | (value, count, avg, error_count) :: rest ->
                  let group_pred () =
                    let matching_trace_ids = Q.Select.(
                      from_source source Q.Projection.(one (right Spans.trace_id))
                      |> where Q.Expr.(and_ base_pred
                        (eq (left Span_attributes.value) value))
                      |> compile) in
                    Q.Expr.(in_select
                      Trace_summaries.trace_id matching_trace_ids) in
                 let* item = stat_for_group value count avg
                   (Option.value error_count ~default:0) group_pred in
                 let* tail = collect rest in
                 Ok (item :: tail) in
           let* items = collect groups in
           Ok (sort_stat_items filter.limit items))

let log_stats ?(attr_contains = []) ?min_severity
    (filter : log_stats_filter) t =
  read t @@ fun runner ->
  let open Result.Syntax in
  let search_filter : log_search_filter = {
    service = filter.service; trace_id = filter.trace_id;
    span_id = filter.span_id; severity = filter.severity;
    body = filter.body; attrs = filter.attrs;
    window = filter.window; cursor = None; limit = filter.limit;
  } in
  let predicate = log_search_predicate ~attr_contains ?min_severity search_filter in
  let as_items groups =
    groups |> List.map (fun (group, count) ->
      { Model.group; count; value = float_of_int count })
    |> sort_stat_items filter.limit in
  let by_column col =
    let* groups = q_select runner Q.Select.(
      from Logs.table Q.Projection.(t2 (one col) (count ()))
      |> where predicate |> group_by col) in
    Ok (as_items groups) in
  match filter.group_by with
  | "service" -> by_column Logs.service_name
  | "severity" -> by_column Logs.severity_text
  | "scope" ->
      let* groups = q_select runner Q.Select.(
        from Logs.table Q.Projection.(t2 (one Logs.scope_name) (count ()))
        |> where predicate |> group_by Logs.scope_name) in
      Ok (as_items (List.map (fun (name,count) ->
        (Option.value name ~default:"unknown", count)) groups))
  | group_by ->
      (match attr_group_key group_by with
      | None ->
          let* count = q_select runner Q.Select.(
            from Logs.table Q.Projection.(count ()) |> where predicate) in
          Ok (as_items ["unknown", List.hd count])
      | Some key ->
          let filtered_ids = Q.Select.(
            from Logs.table Q.Projection.(one Logs.id)
            |> where predicate |> compile) in
          let left col = Q.Scope.column (Q.Scope.left Q.Scope.self) col in
          let right col = Q.Scope.column Q.Scope.right col in
          let source = Q.Source.(join Logs.table
            ~on:Q.Expr.(eq_col (left Log_attributes.owner_id) (right Logs.id))
            (from Log_attributes.table)) in
          let* groups = q_select runner Q.Select.(
            from_source source Q.Projection.(t2
              (one (left Log_attributes.value)) (count ()))
            |> where Q.Expr.(and_ (eq (left Log_attributes.key) key)
              (in_select (right Logs.id) filtered_ids))
            |> group_by (left Log_attributes.value)) in
          Ok (as_items groups))

module Facet_pairs = struct
  module T = Q.Table.Make (struct let name = "facet_pairs" end)
  include T
  let owner_id = column "owner_id" Q.text
  let value = column "value" Q.text
end

let facets (filter : facet_filter) t =
  read t @@ fun runner ->
  let open Result.Syntax in
  let to_items ?(short_values = false) rows =
    rows
    |> List.filter (fun (value, _) ->
         not short_values || String.length value <= 512)
    |> List.map (fun (value, count) -> { Model.value; count })
    |> List.sort (fun (a : Model.facet_item) b ->
         let n = compare b.count a.count in
         if n <> 0 then n else String.compare a.value b.value)
    |> take filter.limit in
  let trace_predicate =
    let p = window_predicate Trace_summaries.started_at_ns filter.window in
    match filter.service with None -> p | Some service ->
      Q.Expr.and_ p (trace_service_predicate Trace_summaries.trace_id service) in
  let log_predicate =
    let p = window_predicate Logs.timestamp_ns filter.window in
    match filter.service with None -> p | Some service ->
      Q.Expr.and_ p (Q.Expr.eq Logs.service_name service) in
  let trace_col col = q_select runner Q.Select.(
    from Trace_summaries.table Q.Projection.(t2 (one col) (count ()))
    |> where trace_predicate |> group_by col) in
  let log_col col = q_select runner Q.Select.(
    from Logs.table Q.Projection.(t2 (one col) (count ()))
    |> where log_predicate |> group_by col) in
  let grouped_pairs pairs =
    q_select runner Q.Select.(
      from Facet_pairs.table Q.Projection.(t2 (one Facet_pairs.value) (count ()))
      |> with_cte ~name:"facet_pairs" pairs
      |> group_by Facet_pairs.value) in
  let trace_attributes () =
    let trace_ids = Q.Select.(
      from Trace_summaries.table Q.Projection.(one Trace_summaries.trace_id)
      |> where trace_predicate |> compile) in
    let left col = Q.Scope.column (Q.Scope.left Q.Scope.self) col in
    let right col = Q.Scope.column Q.Scope.right col in
    let source = Q.Source.(join Spans.table
      ~on:Q.Expr.(eq_col (left Span_attributes.owner_id) (right Spans.id))
      (from Span_attributes.table)) in
    let attr_value = match filter.field with
      | "attribute_keys" -> left Span_attributes.key
      | _ -> left Span_attributes.value in
    let attr_predicate = match filter.field, filter.key with
      | "attribute_values", Some key -> Q.Expr.eq (left Span_attributes.key) key
      | _ -> Q.Expr.true_ in
    let pairs = Q.Select.(
      from_source source Q.Projection.(t2
        (expr ~as_:"owner_id" Q.Expr.(col (right Spans.trace_id)))
        (expr ~as_:"value" Q.Expr.(col attr_value)))
      |> where Q.Expr.(and_ attr_predicate
        (in_select (right Spans.trace_id) trace_ids))
      |> distinct |> compile) in
    grouped_pairs pairs in
  let log_attributes () =
    let log_ids = Q.Select.(
      from Logs.table Q.Projection.(one Logs.id)
      |> where log_predicate |> compile) in
    let attr_value = match filter.field with
      | "attribute_keys" -> Log_attributes.key
      | _ -> Log_attributes.value in
    let attr_predicate = match filter.field, filter.key with
      | "attribute_values", Some key -> Q.Expr.eq Log_attributes.key key
      | _ -> Q.Expr.true_ in
    let pairs = Q.Select.(
      from Log_attributes.table Q.Projection.(t2
        (expr ~as_:"owner_id" Q.Expr.(col Log_attributes.owner_id))
        (expr ~as_:"value" Q.Expr.(col attr_value)))
      |> where Q.Expr.(and_ attr_predicate
        (in_select Log_attributes.owner_id log_ids))
      |> distinct |> compile) in
    grouped_pairs pairs in
  match filter.kind, filter.field with
  | "traces", "service" ->
      let* rows = trace_col Trace_summaries.service_name in
      Ok (to_items rows)
  | "traces", "operation" ->
      let* rows = trace_col Trace_summaries.root_operation_name in
      Ok (to_items rows)
  | "traces", "status" ->
      let count pred = q_select runner Q.Select.(
        from Trace_summaries.table Q.Projection.(count ())
        |> where Q.Expr.(and_ trace_predicate pred)) in
      let* ok = count Q.Expr.(eq Trace_summaries.error_count 0) in
      let* error = count Q.Expr.(gt Trace_summaries.error_count 0) in
      Ok (to_items ["ok", List.hd ok; "error", List.hd error]
        |> List.filter (fun item -> item.Model.count > 0))
  | "logs", "service" ->
      let* rows = log_col Logs.service_name in Ok (to_items rows)
  | "logs", "severity" ->
      let* rows = log_col Logs.severity_text in Ok (to_items rows)
  | "logs", "scope" ->
      let* rows = log_col Logs.scope_name in
      Ok (to_items (List.map (fun (v,n) ->
        Option.value v ~default:"unknown", n) rows))
  | ("traces" | "logs"), ("attribute_keys" | "attribute_values")
      when filter.field <> "attribute_values" || Option.is_some filter.key ->
      let* rows = if filter.kind = "traces" then trace_attributes ()
        else log_attributes () in
      Ok (to_items ~short_values:(filter.field = "attribute_values") rows)
  | _ -> Ok []

let metric_predicate (filter : metric_filter) =
  let predicate = Q.Expr.true_ in
  let predicate =
    match filter.service with
    | None -> predicate
    | Some service ->
        Q.Expr.and_ predicate (Q.Expr.eq Metric_points.service_name service)
  in
  let predicate =
    match filter.name with
    | None -> predicate
    | Some name -> Q.Expr.and_ predicate (Q.Expr.eq Metric_points.name name)
  in
  let predicate =
    Q.Expr.and_ predicate
      (window_predicate Metric_points.timestamp_ns filter.window)
  in
  Q.Expr.and_ predicate
    (keyset_predicate ~sort_key:Metric_points.timestamp_ns
       ~tie_breaker:Metric_points.id filter.cursor)

let list_metric_points (filter : metric_filter) t =
  read t @@ fun runner ->
  q_select runner
    Q.Select.(
      from Metric_points.table
        (Q.Projection.t2 (Q.Projection.one Metric_points.id) metric_projection)
      |> where (metric_predicate filter)
      |> order_by ~desc:true Metric_points.timestamp_ns
      |> order_by ~desc:true Metric_points.id
      |> limit (filter.limit + 1))
  |> Result.map (fun rows ->
         let page =
           page_of_rows ~limit:filter.limit
             ~position:(fun (id, (point : Model.metric_point)) ->
               {
                 Model.sort_key_ns = point.timestamp_ns;
                 tie_breaker = id;
               })
             rows
         in
         { items = List.map snd page.items; next = page.next })

let count_rows runner table =
  let open Result.Syntax in
  let* rows = q_select runner Q.Select.(from table Q.Projection.(count ())) in
  scalar "count" rows

let count_windowed_rows runner table sort_key window =
  let open Result.Syntax in
  let* rows =
    q_select runner
      Q.Select.(
        from table Q.Projection.(count ())
        |> where (window_predicate sort_key window))
  in
  scalar "count" rows

let storage t =
  let open Result.Syntax in
  let* bytes = database_bytes t.writer in
  t.segments.(t.active).bytes <- bytes;
  let segments =
    Array.to_list t.segments
    |> List.filter (fun segment -> segment.sequence > 0)
    |> List.sort (fun left right -> compare left.sequence right.sequence)
    |> List.map (fun segment ->
           {
             Model.slot = segment.slot;
             sequence = segment.sequence;
             bytes = segment.bytes;
             started_at_ms = segment.started_at_ms;
             active = segment.slot = t.active;
           })
  in
  Ok
    {
      Model.max_bytes = t.config.Config.max_db_size_mb * 1024 * 1024;
      segment_bytes = segment_bytes t.config;
      used_bytes =
        Array.fold_left (fun total segment -> total + segment.bytes) 0 t.segments;
      segments;
      ingest_failures = t.ingest_failures;
      last_ingest_failure = t.last_ingest_failure;
    }

let stats ?window t =
  let open Result.Syntax in
  let* storage = storage t in
  read t @@ fun runner ->
  let window = Option.value window ~default:Model.window_all in
  let* spans = count_windowed_rows runner Spans.table Spans.start_time_ns window in
  let* logs = count_windowed_rows runner Logs.table Logs.timestamp_ns window in
  let* metric_points =
    count_windowed_rows runner Metric_points.table Metric_points.timestamp_ns window
  in
  let* traces =
    count_windowed_rows runner Trace_summaries.table Trace_summaries.started_at_ns
      window
  in
  let* services = list_services_runner ~window runner in
  Ok
    {
      Model.spans;
      logs;
      metric_points;
      traces;
      services = List.length services;
      storage;
    }
