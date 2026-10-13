module Q = Ox_sql
module Sqlite = Ox_sql.Sqlite
module String_set = Set.Make (String)

type error =
  [ Q.Pool.error
  | `Invalid_store of string
  ]

type t = {
  config : Config.t;
  pool : Q.Pool.t;
  now_ms : unit -> int;
  wall_now : unit -> int;
  mutable last_prune : Model.prune_report option;
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

type trace_stat_bucket = {
  mutable stat_count : int;
  mutable total_duration_ms : float;
  mutable durations_ms : float list;
  mutable error_traces : int;
}

type metric_filter = {
  service : string option;
  name : string option;
  window : Model.window;
  cursor : Model.cursor_position option;
  limit : int;
}

(* Bump this constant, and the fingerprint recorded in the schema test, with
   every change to the statements in [schemas]. [open_] recreates any database
   whose stored version differs, so a schema change without a bump would be
   silently skipped on an existing database (schm-hnis). *)
let schema_version = 6

let schema_version_text = string_of_int schema_version

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

  let id = column "id" Q.text
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

  let id = column "id" Q.text
  let owner_id = column "owner_id" Q.text
  let key = column "key" Q.text
  let value = column "value" Q.text
end

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

  let id = column "id" Q.text
  let owner_id = column "owner_id" Q.text
  let key = column "key" Q.text
  let value = column "value" Q.text
end

(* SQLite keeps its schema in [sqlite_master]; the typed builders can read it
   like any other table, which keeps the schema-version check free of raw SQL. *)
module Sqlite_master = struct
  module T = Q.Table.Make (struct
    let name = "sqlite_master"
  end)

  include T

  let type_ = column "type" Q.text
  let name = column "name" Q.text
end

let pp_error ppf = function
  | `Ox_sql error -> Q.pp_error ppf error
  | `Pool_shutdown -> Format.pp_print_string ppf "pool shutdown"
  | `Timeout -> Format.pp_print_string ppf "timeout"
  | `Invalid_store message -> Format.fprintf ppf "invalid store: %s" message

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
let attr_row_id owner_id index key = owner_id ^ ":" ^ string_of_int index ^ ":" ^ key

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

let q_schema_pool runner schema =
  Q.Pool.Typed.run_schema runner (Q.Ox_schema.compile schema)

let q_exec_pool runner query = Q.Pool.Typed.execute_compiled runner query

let q_select_pool runner query =
  Q.Pool.Typed.select runner (Q.Select.compile query)

let q_schema runner schema =
  Q.Pool.Typed.run_schema runner (Q.Ox_schema.compile schema)
  |> Result.map_error widen_pool_error

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

let rec result_fold list init f =
  let open Result.Syntax in
  match list with
  | [] -> Ok init
  | item :: rest ->
      let* init = f init item in
      result_fold rest init f

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
    create_index ~if_not_exists:true ~name:"idx_spans_service" Spans.table
      [ Q.Column.any Spans.service_name ];
    create_index ~if_not_exists:true ~name:"idx_spans_start_time" Spans.table
      [ Q.Column.any Spans.start_time_ns ];
    create_index ~if_not_exists:true ~name:"idx_spans_trace" Spans.table
      [ Q.Column.any Spans.trace_id ];
    create_index ~if_not_exists:true ~name:"idx_spans_span_id" Spans.table
      [ Q.Column.any Spans.span_id ];
    create_index ~if_not_exists:true ~name:"idx_spans_status" Spans.table
      [ Q.Column.any Spans.status ];
    create_index ~if_not_exists:true ~name:"idx_spans_service_start" Spans.table
      [ Q.Column.any Spans.service_name; Q.Column.any Spans.start_time_ns ];
    create_index ~if_not_exists:true ~name:"idx_spans_trace_parent" Spans.table
      [ Q.Column.any Spans.trace_id; Q.Column.any Spans.parent_span_id ];
    create_table ~if_not_exists:true Span_attributes.table
      [
        column ~primary_key:true Span_attributes.id;
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
    create_index ~if_not_exists:true ~name:"idx_logs_service" Logs.table
      [ Q.Column.any Logs.service_name ];
    create_index ~if_not_exists:true ~name:"idx_logs_timestamp" Logs.table
      [ Q.Column.any Logs.timestamp_ns ];
    create_index ~if_not_exists:true ~name:"idx_logs_trace" Logs.table
      [ Q.Column.any Logs.trace_id ];
    create_index ~if_not_exists:true ~name:"idx_logs_span" Logs.table
      [ Q.Column.any Logs.span_id ];
    create_index ~if_not_exists:true ~name:"idx_logs_severity" Logs.table
      [ Q.Column.any Logs.severity_normalized ];
    create_index ~if_not_exists:true ~name:"idx_logs_ingested" Logs.table
      [ Q.Column.any Logs.ingested_at_ms ];
    create_table ~if_not_exists:true Log_attributes.table
      [
        column ~primary_key:true Log_attributes.id;
        column ~not_null:true Log_attributes.owner_id;
        column ~not_null:true Log_attributes.key;
        column ~not_null:true Log_attributes.value;
      ];
    create_index ~if_not_exists:true ~name:"idx_log_attributes_key_value"
      Log_attributes.table
      [ Q.Column.any Log_attributes.key; Q.Column.any Log_attributes.value ];
    create_index ~if_not_exists:true ~name:"idx_log_attributes_owner"
      Log_attributes.table [ Q.Column.any Log_attributes.owner_id ];
    create_table ~if_not_exists:true Trace_summaries.table
      [
        column ~primary_key:true Trace_summaries.trace_id;
        column ~not_null:true Trace_summaries.service_name;
        column ~not_null:true Trace_summaries.root_operation_name;
        column ~not_null:true Trace_summaries.started_at_ns;
        column ~not_null:true Trace_summaries.ended_at_ns;
        column ~not_null:true Trace_summaries.duration_ms;
        column ~not_null:true Trace_summaries.span_count;
        column ~not_null:true Trace_summaries.error_count;
        column ~not_null:true Trace_summaries.is_running;
        column ~not_null:true Trace_summaries.warning_count;
        column ~not_null:true Trace_summaries.updated_at_ms;
      ];
    create_index ~if_not_exists:true ~name:"idx_trace_summaries_service"
      Trace_summaries.table [ Q.Column.any Trace_summaries.service_name ];
    create_index ~if_not_exists:true ~name:"idx_trace_summaries_started"
      Trace_summaries.table [ Q.Column.any Trace_summaries.started_at_ns ];
    create_index ~if_not_exists:true ~name:"idx_trace_summaries_updated"
      Trace_summaries.table [ Q.Column.any Trace_summaries.updated_at_ms ];
    create_table ~if_not_exists:true Trace_services.table
      [ column ~not_null:true Trace_services.trace_id;
        column ~not_null:true Trace_services.service_name ];
    create_index ~if_not_exists:true ~unique:true ~name:"idx_trace_services_pair"
      Trace_services.table
      [ Q.Column.any Trace_services.trace_id; Q.Column.any Trace_services.service_name ];
    create_index ~if_not_exists:true ~name:"idx_trace_services_service"
      Trace_services.table [ Q.Column.any Trace_services.service_name ];
    create_index ~if_not_exists:true ~name:"idx_trace_summaries_service_start"
      Trace_summaries.table
      [ Q.Column.any Trace_summaries.service_name; Q.Column.any Trace_summaries.started_at_ns ];
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
    create_index ~if_not_exists:true ~name:"idx_metric_points_ingested"
      Metric_points.table [ Q.Column.any Metric_points.ingested_at_ms ];
    create_table ~if_not_exists:true Metric_attributes.table
      [
        column ~primary_key:true Metric_attributes.id;
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

let init_schema runner =
  let open Result.Syntax in
  let* () = result_iter schemas (q_schema_pool runner) in
  let query =
    Q.Insert.(
      into Meta.table
      |> value Meta.key "schema_version"
      |> value Meta.value schema_version_text
      |> on_conflict_update [ Q.Column.any Meta.key ] ~set:[ Q.Column.any Meta.value ]
      |> compile)
  in
  let* _ = q_exec_pool runner query in
  Ok ()

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

(* Ox SQL has no typed pragma API. Ox_sql.mli documents [Pool.Raw] as the
   escape hatch for "migrations, pragmas, diagnostics, and backend-specific
   SQL", so every pragma Inn runs goes through these two helpers, and no other
   raw SQL exists in the store. *)
let sqlite_pragma_int runner pragma =
  let open Result.Syntax in
  let* rows =
    Q.Pool.Raw.query runner ("PRAGMA " ^ pragma) []
    |> Result.map_error widen_pool_error
  in
  let column_value row =
    match Q.Row.fields row with
    | name :: _ -> Q.Row.int name row
    | [] -> None
  in
  match List.filter_map column_value rows with
  | value :: _ -> Ok value
  | [] ->
      Error
        (`Invalid_store
          (Printf.sprintf "PRAGMA %s did not return an integer value" pragma))

let sqlite_pragma runner pragma =
  let open Result.Syntax in
  (* [PRAGMA incremental_vacuum] steps once per freed page, so the pragma is
     folded rather than executed; [Raw.execute] rejects a row-returning
     statement. *)
  let* () =
    Q.Pool.Raw.fold runner ("PRAGMA " ^ pragma) [] ~init:()
      ~f:(fun () _ -> ())
    |> Result.map_error widen_pool_error
  in
  Ok ()

(* Live data is the pages in use, not the file size: SQLite never shrinks the
   file on delete alone, so the file size is a poor size-cap input (ret-zjzs). *)
let live_bytes runner =
  let open Result.Syntax in
  let* page_count = sqlite_pragma_int runner "page_count" in
  let* freelist_count = sqlite_pragma_int runner "freelist_count" in
  let* page_size = sqlite_pragma_int runner "page_size" in
  Ok ((page_count - freelist_count) * page_size)

(* Schema state of the file at the configured database path. The check reads
   the file before any schema statement runs, so a database that is not Inn's
   is never modified or deleted (schm-xkk2). *)
type database_state =
  | Database_absent
  | Database_fresh
  | Database_current
  | Database_stale of string
  | Database_foreign

(* Inspecting and preparing a file uses a local, non-WAL connection: [PRAGMA
   journal_mode = WAL] writes the database header, which would both touch a
   foreign file and lock in the default [auto_vacuum] before Inn can set it.
   The remaining settings are per-connection and do not modify the file. *)
let local_sqlite_config ?(mode = Sqlite.Read_write) path =
  { (sqlite_config path) with mode; journal_mode = None }

let with_local_pool ~caps ?mode path f =
  Eio.Switch.run (fun sw ->
      let open Result.Syntax in
      let* pool =
        Q.Pool.create ~caps ~sw ~default_timeout:(Ox.Duration.seconds 5) ~max_size:1
          (local_sqlite_config ?mode path)
        |> Result.map_error widen_pool_error
      in
      let result = f pool in
      let closed = Q.Pool.shutdown pool |> Result.map_error widen_pool_error in
      match result with Error _ -> result | Ok value -> Result.map (fun () -> value) closed)

let sqlite_magic = "SQLite format 3\000"

(* A zero-length file is a valid empty SQLite database; anything else must
   carry the SQLite header. Refusing a file that is not SQLite before opening a
   connection keeps a misconfigured path from being touched at all
   (schm-xkk2). *)
let file_is_sqlite ~caps path =
  let channel = Ox_caps.Cap_stdlib.open_in_bin ~caps path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
      let length = in_channel_length channel in
      if length = 0 then true
      else if length < String.length sqlite_magic then false
      else String.equal (really_input_string channel 16) sqlite_magic)

let read_database_state ~caps path =
  if not (Sys.file_exists path) then Ok Database_absent
  else if not (file_is_sqlite ~caps path) then
    Error
      (`Invalid_store
        (Printf.sprintf "refusing to open %s: it is not an SQLite database" path))
  else
    let open Result.Syntax in
    let result =
      with_local_pool ~caps path (fun pool ->
          let open Result.Syntax in
          let* tables =
            q_select pool
              Q.Select.(
                from Sqlite_master.table Q.Projection.(one Sqlite_master.name)
                |> where Q.Expr.(eq Sqlite_master.type_ "table"))
          in
          let tables =
            List.filter
              (fun name -> not (String.starts_with ~prefix:"sqlite_" name))
              tables
          in
          if not (List.mem "inn_meta" tables) then
            Ok
              (if tables = [] then Database_fresh else Database_foreign)
          else
            let* versions =
              q_select pool
                Q.Select.(
                  from Meta.table Q.Projection.(one Meta.value)
                  |> where Q.Expr.(eq Meta.key "schema_version")
                  |> limit 1)
            in
            match versions with
            | [ stored ] when String.equal stored schema_version_text ->
                Ok Database_current
            | [ stored ] -> Ok (Database_stale stored)
            | [] -> Ok (Database_stale "none")
            | _ ->
                Error
                  (`Invalid_store
                    "inn_meta holds more than one schema_version row"))
    in
    match result with
    | Ok state -> Ok state
    | Error error ->
        Error
          (`Invalid_store
            (Printf.sprintf "cannot read %s as an SQLite database: %s" path
               (Format.asprintf "%a" pp_error error)))

let remove_if_exists ~caps path =
  if Sys.file_exists path then
    try Ox_caps.Cap_sys.remove ~caps path with Sys_error _ -> ()

let remove_database_files ~caps path =
  List.iter (remove_if_exists ~caps) [ path; path ^ "-wal"; path ^ "-shm" ]

let default_report ~caps line =
  Ox_caps.Cap_stdlib.prerr_endline ~caps ("inn: " ^ line)

let open_ ~caps ~sw ?(now_ms = wall_now_ms ~caps) ?(report = default_report ~caps) config =
  let wall_now = wall_now_ms ~caps in
  let open Result.Syntax in
  let path = config.Config.db_path in
  mkdir_p ~caps (Filename.dirname path);
  let* state = read_database_state ~caps path in
  let* () =
    match state with
    | Database_current -> Ok ()
    | Database_foreign ->
        Error
          (`Invalid_store
            (Printf.sprintf
               "refusing to recreate %s: it has tables but no inn_meta table, so it is not an Inn database"
               path))
    | Database_stale stored ->
        report
          (Printf.sprintf
             "schema version %s at %s does not match version %d; deleting the old database and creating a fresh one"
             stored path schema_version);
        remove_database_files ~caps path;
        Ok ()
    | Database_absent | Database_fresh ->
        remove_database_files ~caps path;
        Ok ()
  in
  let* () =
    (* [auto_vacuum] must be set while the database is still empty, and before
       any other connection switches it to WAL, or SQLite ignores it. *)
    match state with
    | Database_current -> Ok ()
    | _ ->
        with_local_pool ~caps ~mode:Sqlite.Read_write_create path (fun pool ->
            sqlite_pragma pool "auto_vacuum = INCREMENTAL")
  in
  let* pool =
    Q.Pool.create ~caps ~sw ~default_timeout:(Ox.Duration.seconds 5) ~max_size:4
      (sqlite_config path)
    |> Result.map_error widen_pool_error
  in
  let* () = init_schema pool |> Result.map_error widen_pool_error in
  Ok { config; pool; now_ms; wall_now; last_prune = None }

let close t = Q.Pool.shutdown t.pool |> Result.map_error widen_pool_error

(* The query window is resolved against this clock, so handler tests can drive
   both ingestion and lookback with the same injected time. *)
let now_ms t = t.now_ms ()

(* A cheap liveness read for GET /ready: one row of the tiny metadata table
   proves the pool still answers without scanning any telemetry table. *)
let ping t =
  q_select t.pool
    Q.Select.(
      from Meta.table Q.Projection.(one Meta.value)
      |> where Q.Expr.(eq Meta.key "schema_version")
      |> limit 1)
  |> Result.map (fun _ -> ())

let with_db ~caps ~sw ?now_ms ?report config f =
  let open Result.Syntax in
  let* store = open_ ~caps ~sw ?now_ms ?report config in
  let result = f store in
  let closed = close store in
  match result with Error _ -> result | Ok value -> Result.map (fun () -> value) closed

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
             (is_running, warning_count) ) ->
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
        })
      (t2
         (t8 (one Trace_summaries.trace_id) (one Trace_summaries.service_name)
            (one Trace_summaries.root_operation_name)
            (one Trace_summaries.started_at_ns) (one Trace_summaries.ended_at_ns)
            (one Trace_summaries.duration_ms) (one Trace_summaries.span_count)
            (one Trace_summaries.error_count))
         (t2 (one Trace_summaries.is_running)
            (one Trace_summaries.warning_count))))

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

let insert_span_attrs runner owner_id attrs =
  let open Result.Syntax in
  let delete =
    Q.Delete.(
      from Span_attributes.table
      |> where Q.Expr.(eq Span_attributes.owner_id owner_id)
      |> compile)
  in
  let* _ = q_exec_pool runner delete in
  let insert index (key, attr_value) =
    Q.Insert.(
      into Span_attributes.table
      |> value Span_attributes.id (attr_row_id owner_id index key)
      |> value Span_attributes.owner_id owner_id
      |> value Span_attributes.key key
      |> value Span_attributes.value (Model.attr_string_value attr_value)
      |> compile)
  in
  let* _ =
    result_fold attrs 0 (fun index attr ->
        let* _ = q_exec_pool runner (insert index attr) in
        Ok (index + 1))
  in
  Ok ()

let insert_log_attrs runner owner_id attrs =
  let open Result.Syntax in
  let insert index (key, attr_value) =
    Q.Insert.(
      into Log_attributes.table
      |> value Log_attributes.id (attr_row_id owner_id index key)
      |> value Log_attributes.owner_id owner_id
      |> value Log_attributes.key key
      |> value Log_attributes.value (Model.attr_string_value attr_value)
      |> compile)
  in
  let* _ =
    result_fold attrs 0 (fun index attr ->
        let* _ = q_exec_pool runner (insert index attr) in
        Ok (index + 1))
  in
  Ok ()

let insert_metric_attrs runner owner_id attrs =
  let open Result.Syntax in
  let insert index (key, attr_value) =
    Q.Insert.(
      into Metric_attributes.table
      |> value Metric_attributes.id (attr_row_id owner_id index key)
      |> value Metric_attributes.owner_id owner_id
      |> value Metric_attributes.key key
      |> value Metric_attributes.value (Model.attr_string_value attr_value)
      |> compile)
  in
  let* _ =
    result_fold attrs 0 (fun index attr ->
        let* _ = q_exec_pool runner (insert index attr) in
        Ok (index + 1))
  in
  Ok ()

(* One trace refresh owns every derived row of a trace: the trace summary
   (tree order, running state, warnings) and the participating services. *)
let refresh_trace ~now_ms runner trace_id =
  let open Result.Syntax in
  let* spans = select_spans_for_trace_pool runner trace_id in
  match spans with
  | [] -> Ok ()
  | spans ->
      let tree = Trace_tree.assemble spans in
      let insert =
        Q.Insert.(
          into Trace_summaries.table
          |> value Trace_summaries.trace_id trace_id
          |> value Trace_summaries.service_name tree.root_service_name
          |> value Trace_summaries.root_operation_name tree.root_operation_name
          |> value Trace_summaries.started_at_ns tree.started_at_ns
          |> value Trace_summaries.ended_at_ns tree.ended_at_ns
          |> value Trace_summaries.duration_ms tree.duration_ms
          |> value Trace_summaries.span_count tree.span_count
          |> value Trace_summaries.error_count tree.error_count
          |> value Trace_summaries.is_running tree.is_running
          |> value Trace_summaries.warning_count (List.length tree.warnings)
          |> value Trace_summaries.updated_at_ms now_ms
          |> on_conflict_update [ Q.Column.any Trace_summaries.trace_id ]
               ~set:[ Q.Column.any Trace_summaries.service_name;
                      Q.Column.any Trace_summaries.root_operation_name;
                      Q.Column.any Trace_summaries.started_at_ns;
                      Q.Column.any Trace_summaries.ended_at_ns;
                      Q.Column.any Trace_summaries.duration_ms;
                      Q.Column.any Trace_summaries.span_count;
                      Q.Column.any Trace_summaries.error_count;
                      Q.Column.any Trace_summaries.is_running;
                      Q.Column.any Trace_summaries.warning_count;
                      Q.Column.any Trace_summaries.updated_at_ms ]
          |> compile)
      in
      let* _ = q_exec_pool runner insert in
      let* _ = q_exec_pool runner Q.Delete.(
        from Trace_services.table
        |> where Q.Expr.(eq Trace_services.trace_id trace_id)
        |> compile) in
      let services = List.sort_uniq String.compare
        (List.map (fun (span : Model.span) -> span.service_name) spans) in
      result_iter services (fun service_name ->
        let* _ = q_exec_pool runner Q.Insert.(
          into Trace_services.table
          |> value Trace_services.trace_id trace_id
          |> value Trace_services.service_name service_name
          |> compile) in
        Ok ())

(* Retention deletes owner rows in bounded batches. Every batch is a
   subquery delete limited to [prune_batch_size] rows, so no statement ever
   binds a list that grows with the backlog (ret-xbij), and attribute rows are
   removed through the same bounded subquery, so no deleted span, log, or
   metric point leaves an orphaned index row (ret-hy7e). *)

let prune_batch_size = 1000
let size_pressure_batch_size = 100

type prune_counts = {
  traces : int;
  spans : int;
  logs : int;
  metric_points : int;
}

let zero_prune_counts = { traces = 0; spans = 0; logs = 0; metric_points = 0 }

let expired_log_ids_select ~batch cutoff =
  Q.Select.(
    from Logs.table Q.Projection.(one Logs.id)
    |> where Q.Expr.(lt Logs.ingested_at_ms cutoff)
    |> order_by Logs.ingested_at_ms
    |> limit batch
    |> compile)

let oldest_log_ids_select ~batch =
  Q.Select.(
    from Logs.table Q.Projection.(one Logs.id)
    |> order_by Logs.ingested_at_ms
    |> limit batch
    |> compile)

let delete_log_batch runner ~batch cutoff =
  let ids =
    match cutoff with
    | Some cutoff -> expired_log_ids_select ~batch cutoff
    | None -> oldest_log_ids_select ~batch
  in
  let open Result.Syntax in
  let* _ =
    q_exec_pool runner
      Q.Delete.(
        from Log_attributes.table
        |> where Q.Expr.(in_select Log_attributes.owner_id ids)
        |> compile)
  in
  q_exec_pool runner
    Q.Delete.(from Logs.table |> where Q.Expr.(in_select Logs.id ids) |> compile)

let expired_metric_ids_select ~batch cutoff =
  Q.Select.(
    from Metric_points.table Q.Projection.(one Metric_points.id)
    |> where Q.Expr.(lt Metric_points.ingested_at_ms cutoff)
    |> order_by Metric_points.ingested_at_ms
    |> limit batch
    |> compile)

let oldest_metric_ids_select ~batch =
  Q.Select.(
    from Metric_points.table Q.Projection.(one Metric_points.id)
    |> order_by Metric_points.ingested_at_ms
    |> limit batch
    |> compile)

let delete_metric_batch runner ~batch cutoff =
  let ids =
    match cutoff with
    | Some cutoff -> expired_metric_ids_select ~batch cutoff
    | None -> oldest_metric_ids_select ~batch
  in
  let open Result.Syntax in
  let* _ =
    q_exec_pool runner
      Q.Delete.(
        from Metric_attributes.table
        |> where Q.Expr.(in_select Metric_attributes.owner_id ids)
        |> compile)
  in
  q_exec_pool runner
    Q.Delete.(
      from Metric_points.table
      |> where Q.Expr.(in_select Metric_points.id ids)
      |> compile)

(* Trace expiry uses the summary's last-update time, so a trace is deleted only
   when none of its spans was received inside the trace TTL (ret-4hhb). *)

let expired_trace_ids_select ~batch cutoff =
  Q.Select.(
    from Trace_summaries.table Q.Projection.(one Trace_summaries.trace_id)
    |> where Q.Expr.(lt Trace_summaries.updated_at_ms cutoff)
    |> order_by Trace_summaries.updated_at_ms
    |> limit batch
    |> compile)

let oldest_trace_ids_select ~batch =
  Q.Select.(
    from Trace_summaries.table Q.Projection.(one Trace_summaries.trace_id)
    |> order_by Trace_summaries.updated_at_ms
    |> limit batch
    |> compile)

let trace_span_ids_select trace_ids =
  Q.Select.(
    from Spans.table Q.Projection.(one Spans.id)
    |> where Q.Expr.(in_select Spans.trace_id trace_ids)
    |> compile)

let delete_trace_batch runner ~batch cutoff =
  let trace_ids =
    match cutoff with
    | Some cutoff -> expired_trace_ids_select ~batch cutoff
    | None -> oldest_trace_ids_select ~batch
  in
  let open Result.Syntax in
  let* _ =
    q_exec_pool runner
      Q.Delete.(
        from Span_attributes.table
        |> where
             Q.Expr.(
               in_select Span_attributes.owner_id
                 (trace_span_ids_select trace_ids))
        |> compile)
  in
  let* _ = q_exec_pool runner Q.Delete.(
    from Trace_services.table
    |> where Q.Expr.(in_select Trace_services.trace_id trace_ids)
    |> compile) in
  let* spans =
    q_exec_pool runner
      Q.Delete.(
        from Spans.table
        |> where Q.Expr.(in_select Spans.trace_id trace_ids)
        |> compile)
  in
  let* traces =
    q_exec_pool runner
      Q.Delete.(
        from Trace_summaries.table
        |> where Q.Expr.(in_select Trace_summaries.trace_id trace_ids)
        |> compile)
  in
  Ok (traces, spans)

let in_batch t delete =
  Q.Pool.with_transaction t.pool delete |> Result.map_error widen_pool_error

let delete_log_batches t ?cutoff () =
  let rec loop deleted =
    let open Result.Syntax in
    let* count =
      in_batch t (fun tx -> delete_log_batch tx ~batch:prune_batch_size cutoff)
    in
    if count <= 0 then Ok deleted else loop (deleted + count)
  in
  loop 0

let delete_metric_batches t ?cutoff () =
  let rec loop deleted =
    let open Result.Syntax in
    let* count =
      in_batch t (fun tx ->
          delete_metric_batch tx ~batch:prune_batch_size cutoff)
    in
    if count <= 0 then Ok deleted else loop (deleted + count)
  in
  loop 0

let delete_trace_batches t ?cutoff () =
  let rec loop traces spans =
    let open Result.Syntax in
    let* batch =
      in_batch t (fun tx -> delete_trace_batch tx ~batch:prune_batch_size cutoff)
    in
    let batch_traces, batch_spans = batch in
    if batch_traces <= 0 then Ok (traces, spans)
    else loop (traces + batch_traces) (spans + batch_spans)
  in
  loop 0 0

let prune_time_retention t now_ms =
  let hour_ms = 60 * 60 * 1000 in
  let open Result.Syntax in
  let* logs =
    delete_log_batches t
      ~cutoff:(now_ms - (t.config.Config.logs_retention_hours * hour_ms))
      ()
  in
  let* metric_points =
    delete_metric_batches t
      ~cutoff:(now_ms - (t.config.Config.metrics_retention_hours * hour_ms))
      ()
  in
  let* traces, spans =
    delete_trace_batches t
      ~cutoff:(now_ms - (t.config.Config.traces_retention_hours * hour_ms))
      ()
  in
  Ok { traces; spans; logs; metric_points }

(* The size cap acts on live data, not on the file size, and stops as soon as
   live data is under the cap (ret-zjzs, ret-bizv). *)
let prune_size_retention t =
  let max_bytes = t.config.Config.max_db_size_mb * 1024 * 1024 in
  let batch = size_pressure_batch_size in
  let open Result.Syntax in
  let* live = live_bytes t.pool in
  if live <= max_bytes then Ok None
  else
    let rec loop counts =
      let* live = live_bytes t.pool in
      if live <= max_bytes then Ok counts
      else
        let* logs = in_batch t (fun tx -> delete_log_batch tx ~batch None) in
        let counts = { counts with logs = counts.logs + logs } in
        let* live = live_bytes t.pool in
        if live <= max_bytes then Ok counts
        else
          let* metric_points =
            in_batch t (fun tx -> delete_metric_batch tx ~batch None)
          in
          let counts =
            { counts with metric_points = counts.metric_points + metric_points }
          in
          let* live = live_bytes t.pool in
          if live <= max_bytes then Ok counts
          else
            let* traces, spans =
              in_batch t (fun tx -> delete_trace_batch tx ~batch None)
            in
            let counts =
              {
                counts with
                traces = counts.traces + traces;
                spans = counts.spans + spans;
              }
            in
            if logs + metric_points + traces = 0 then Ok counts
            else loop counts
    in
    let* counts = loop zero_prune_counts in
    Ok (Some counts)

let add_prune_counts left right =
  {
    traces = left.traces + right.traces;
    spans = left.spans + right.spans;
    logs = left.logs + right.logs;
    metric_points = left.metric_points + right.metric_points;
  }

let prune ?now_ms t =
  let now = match now_ms with Some value -> value | None -> t.now_ms () in
  let open Result.Syntax in
  let* time_counts = prune_time_retention t now in
  let* size_counts = prune_size_retention t in
  let counts =
    match size_counts with
    | None -> time_counts
    | Some size_counts -> add_prune_counts time_counts size_counts
  in
  let deleted =
    counts.traces + counts.spans + counts.logs + counts.metric_points
  in
  let* () =
    if deleted > 0 then sqlite_pragma t.pool "incremental_vacuum"
    else Ok ()
  in
  let report =
    {
      Model.pruned_at_ms = now;
      traces = counts.traces;
      spans = counts.spans;
      logs = counts.logs;
      metric_points = counts.metric_points;
      size_cap_triggered = Option.is_some size_counts;
    }
  in
  t.last_prune <- Some report;
  Ok report

let last_prune t = t.last_prune

let ingest_traces t spans =
  let open Result.Syntax in
  let now_ms = t.now_ms () in
  let touched = Hashtbl.create 16 in
  let insert_span runner (span : Model.span) =
    let id = span_row_id span in
    let insert =
      Q.Insert.(
        into Spans.table
        |> value Spans.id id
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
    in
    let* _ = q_exec_pool runner insert in
    let* () = insert_span_attrs runner id (span.resource @ span.attributes) in
    Hashtbl.replace touched span.trace_id ();
    Ok ()
  in
  let* () =
    Q.Pool.with_transaction t.pool (fun tx ->
        let* () = result_iter spans (insert_span tx) in
        let trace_ids = List.of_seq (Hashtbl.to_seq_keys touched) in
        result_iter trace_ids (refresh_trace ~now_ms tx))
    |> Result.map_error widen_pool_error
  in
  Ok (List.length spans)

let ingest_logs t logs =
  let open Result.Syntax in
  let now_ms = t.now_ms () in
  let insert_log runner (log : Model.log_record) =
    let id = fresh_id t.wall_now "log" in
    let timestamp_ns = if log.timestamp_ns = 0 then now_ms * 1_000_000 else log.timestamp_ns in
    let query =
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
    in
    let* _ = q_exec_pool runner query in
    insert_log_attrs runner id (log.resource @ log.attributes)
  in
  let* () =
    Q.Pool.with_transaction t.pool (fun tx ->
        result_iter logs (insert_log tx))
    |> Result.map_error widen_pool_error
  in
  Ok (List.length logs)

let ingest_metrics t points =
  let open Result.Syntax in
  let now_ms = t.now_ms () in
  let insert_point runner (point : Model.metric_point) =
    let id = fresh_id t.wall_now "metric" in
    let query =
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
    in
    let* _ = q_exec_pool runner query in
    insert_metric_attrs runner id (point.resource @ point.attributes)
  in
  let* () =
    Q.Pool.with_transaction t.pool (fun tx ->
        result_iter points (insert_point tx))
    |> Result.map_error widen_pool_error
  in
  Ok (List.length points)

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
  list_services_runner ?window ?include_metrics t.pool

let list_trace_summaries ?service ~window ?cursor ~limit t =
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
  q_select t.pool query
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
  }

(* A trace is served whenever it has spans, even if its summary row is missing
   (tree-ddll): the tree is the source of truth for the response, and the
   summary is only the stored projection of it. *)
let get_trace t trace_id =
  let open Result.Syntax in
  let* summaries =
    q_select t.pool
      Q.Select.(
        from Trace_summaries.table trace_summary_projection
        |> where Q.Expr.(eq Trace_summaries.trace_id trace_id)
        |> limit 1)
  in
  let* summary = one_or_none "trace summary lookup" summaries in
  let* spans = select_spans_for_trace t.pool trace_id in
  match (summary, spans) with
  | None, [] -> Ok None
  | summary, spans ->
      let tree = Trace_tree.assemble spans in
      let summary =
        match summary with
        | Some summary -> summary
        | None -> summary_of_tree trace_id tree
      in
      let* logs = q_select t.pool (logs_for_trace_query trace_id) in
      Ok
        (Some
           {
             Model.summary;
             spans = tree.nodes;
             logs;
             warnings = tree.warnings;
           })

let get_span t span_id =
  let open Result.Syntax in
  let* spans = q_select t.pool (span_id_query span_id) in
  one_or_none "span lookup" spans

(* The span detail carries the same tree context as the trace it belongs to, so
   one lookup is enough to place a span (tree-o79f). *)
let get_span_node t span_id =
  let open Result.Syntax in
  let* spans = q_select t.pool (span_id_query span_id) in
  match spans with
  | [] -> Ok None
  | span :: _ ->
      let* siblings = select_spans_for_trace t.pool span.Model.trace_id in
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
  let open Result.Syntax in
  let* spans = q_select t.pool (select_spans_for_trace_in_window trace_id window) in
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
  q_select t.pool (logs_for_trace_page_query ~window ~cursor ~limit trace_id)
  |> Result.map (page_of_rows ~limit ~position:log_position)

let list_span_logs t ~window ?cursor ~limit span_id =
  q_select t.pool (logs_for_span_page_query ~window ~cursor ~limit span_id)
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
  q_select t.pool Q.Select.(
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
  q_select t.pool (trace_summary_search_query ~attr_contains ?min_duration_ms filter)
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
  q_select t.pool
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
  q_select t.pool Q.Select.(from Logs.table log_projection
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
        let* durations = q_select t.pool Q.Select.(
          from Ranked_trace_duration.table Q.Projection.(one Ranked_trace_duration.duration_ms)
          |> with_cte ~name:"ranked_trace_duration" ranked
          |> where Q.Expr.(eq Ranked_trace_duration.rank wanted)) in
        Ok ((match durations with duration :: _ -> duration | [] -> 0.)) in
    Ok { Model.group; value; count } in
  let summaries col =
    q_select t.pool Q.Select.(
      from Trace_summaries.table Q.Projection.(t3
        (one col) (count ()) (avg Q.Numeric.float Trace_summaries.duration_ms))
      |> where predicate |> group_by col) in
  let errors col =
    q_select t.pool Q.Select.(
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
        let* counts = q_select t.pool Q.Select.(
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
           let* groups = q_select t.pool Q.Select.(
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
    let* groups = q_select t.pool Q.Select.(
      from Logs.table Q.Projection.(t2 (one col) (count ()))
      |> where predicate |> group_by col) in
    Ok (as_items groups) in
  match filter.group_by with
  | "service" -> by_column Logs.service_name
  | "severity" -> by_column Logs.severity_text
  | "scope" ->
      let* groups = q_select t.pool Q.Select.(
        from Logs.table Q.Projection.(t2 (one Logs.scope_name) (count ()))
        |> where predicate |> group_by Logs.scope_name) in
      Ok (as_items (List.map (fun (name,count) ->
        (Option.value name ~default:"unknown", count)) groups))
  | group_by ->
      (match attr_group_key group_by with
      | None ->
          let* count = q_select t.pool Q.Select.(
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
          let* groups = q_select t.pool Q.Select.(
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
  let trace_col col = q_select t.pool Q.Select.(
    from Trace_summaries.table Q.Projection.(t2 (one col) (count ()))
    |> where trace_predicate |> group_by col) in
  let log_col col = q_select t.pool Q.Select.(
    from Logs.table Q.Projection.(t2 (one col) (count ()))
    |> where log_predicate |> group_by col) in
  let grouped_pairs pairs =
    q_select t.pool Q.Select.(
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
      let count pred = q_select t.pool Q.Select.(
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
  q_select t.pool
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

let stats ?window t =
  let window = Option.value window ~default:Model.window_all in
  let open Result.Syntax in
  let* spans = count_windowed_rows t.pool Spans.table Spans.start_time_ns window in
  let* logs = count_windowed_rows t.pool Logs.table Logs.timestamp_ns window in
  let* metric_points =
    count_windowed_rows t.pool Metric_points.table Metric_points.timestamp_ns window
  in
  let* traces =
    count_windowed_rows t.pool Trace_summaries.table Trace_summaries.started_at_ns
      window
  in
  let* services = list_services_runner ~window t.pool in
  let* live_bytes = live_bytes t.pool in
  Ok
    {
      Model.spans;
      logs;
      metric_points;
      traces;
      services = List.length services;
      retention =
        {
          Model.traces_ttl_hours = t.config.Config.traces_retention_hours;
          logs_ttl_hours = t.config.logs_retention_hours;
          metrics_ttl_hours = t.config.metrics_retention_hours;
          prune_interval_seconds = t.config.prune_interval_seconds;
          max_db_size_mb = t.config.max_db_size_mb;
          live_bytes;
          last_prune = t.last_prune;
        };
    }
