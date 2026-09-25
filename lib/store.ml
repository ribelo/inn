module Q = Eta_sql
module Sqlite = Eta_sql.Sqlite
module String_set = Set.Make (String)

type error =
  [ Q.Pool.error
  | `Invalid_store of string
  ]

type t = {
  config : Config.t;
  pool : Q.Pool.t;
  now_ms : unit -> int;
  mutable last_prune : Model.prune_report option;
}

type ingest_counts = {
  spans : int;
  logs : int;
  metric_points : int;
}

type log_filter = {
  service : string option;
  severity : string option;
  contains : string option;
  limit : int;
}

type span_search_filter = {
  service : string option;
  trace_id : string option;
  operation : string option;
  parent_operation : string option;
  status : string option;
  attrs : (string * string) list;
  limit : int;
}

type trace_search_filter = {
  service : string option;
  operation : string option;
  status : string option;
  attrs : (string * string) list;
  limit : int;
}

type log_search_filter = {
  service : string option;
  trace_id : string option;
  span_id : string option;
  severity : string option;
  body : string option;
  attrs : (string * string) list;
  limit : int;
}

type trace_stats_filter = {
  group_by : string;
  agg : string;
  service : string option;
  operation : string option;
  status : string option;
  attrs : (string * string) list;
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
  limit : int;
}

type facet_filter = {
  kind : string;
  field : string;
  key : string option;
  service : string option;
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
  limit : int;
}

(* Bump this constant, and the fingerprint recorded in the schema test, with
   every change to the statements in [schemas]. [open_] recreates any database
   whose stored version differs, so a schema change without a bump would be
   silently skipped on an existing database (schm-hnis). *)
let schema_version = 2

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
  let start_time_ms = column "start_time_ms" Q.int
  let end_time_ms = column "end_time_ms" Q.int
  let duration_ms = column "duration_ms" Q.float
  let status = column "status" Q.text
  let status_message = column "status_message" (Q.nullable Q.text)
  let attributes_json = column "attributes_json" Q.text
  let resource_json = column "resource_json" Q.text
  let events_json = column "events_json" Q.text
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
  let severity_number = column "severity_number" (Q.nullable Q.int)
  let timestamp_ms = column "timestamp_ms" Q.int
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
  let started_at_ms = column "started_at_ms" Q.int
  let ended_at_ms = column "ended_at_ms" Q.int
  let duration_ms = column "duration_ms" Q.float
  let span_count = column "span_count" Q.int
  let error_count = column "error_count" Q.int
  let updated_at_ms = column "updated_at_ms" Q.int
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
  let start_time_ms = column "start_time_ms" (Q.nullable Q.int)
  let timestamp_ms = column "timestamp_ms" Q.int
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
  | `Eta_sql error -> Q.pp_error ppf error
  | `Pool_shutdown -> Format.pp_print_string ppf "pool shutdown"
  | `Pool_shutdown_timeout -> Format.pp_print_string ppf "pool shutdown timeout"
  | `Timeout -> Format.pp_print_string ppf "timeout"
  | `Invalid_store message -> Format.fprintf ppf "invalid store: %s" message

let widen_pool_error (error : Q.Pool.error) : error = (error :> error)

let rec mkdir_p path =
  if path = "" || path = "." || Sys.file_exists path then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)

let wall_now_ms () = int_of_float (Unix.gettimeofday () *. 1000.)

let id_counter = Atomic.make 0

let fresh_id prefix =
  let seq = Atomic.fetch_and_add id_counter 1 in
  Printf.sprintf "%s-%d-%d-%d" prefix (Unix.getpid ()) (wall_now_ms ()) seq

let span_row_id (span : Model.span) = span.trace_id ^ ":" ^ span.span_id
let attr_row_id owner_id index key = owner_id ^ ":" ^ string_of_int index ^ ":" ^ key

let event_to_json (event : Model.span_event) =
  `Assoc
    [
      ("name", `String event.Model.name);
      ("timestampMs", `Int event.timestamp_ms);
      ("attributes", Model.attrs_to_json event.attributes);
    ]

let events_json events = Yojson.Safe.to_string (`List (List.map event_to_json events))

let attrs_of_json text =
  match Yojson.Safe.from_string text with
  | `Assoc fields ->
      List.filter_map
        (function
          | key, `String value -> Some (key, value)
          | key, value -> Some (key, Yojson.Safe.to_string value))
        fields
  | _ -> []
  | exception _ -> []

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
              let timestamp_ms =
                match find "timestampMs" with
                | Some (`Int value) -> value
                | _ -> 0
              in
              let attributes =
                match find "attributes" with
                | Some json -> attrs_of_json (Yojson.Safe.to_string json)
                | None -> []
              in
              Some { Model.name; timestamp_ms; attributes }
          | _ -> None)
        events
  | _ -> []
  | exception _ -> []

let q_schema_pool runner schema =
  Q.Pool.Typed.run_schema runner (Q.Eta_schema.compile schema)

let q_exec_pool runner query = Q.Pool.Typed.execute_compiled runner query

let q_select_pool runner query =
  Q.Pool.Typed.select runner (Q.Select.compile query)

let q_schema runner schema =
  Q.Pool.Typed.run_schema runner (Q.Eta_schema.compile schema)
  |> Eta.Effect.map_error widen_pool_error

let q_exec runner query =
  Q.Pool.Typed.execute_compiled runner query |> Eta.Effect.map_error widen_pool_error

let q_select runner query =
  Q.Pool.Typed.select runner (Q.Select.compile query)
  |> Eta.Effect.map_error widen_pool_error

let rec effect_iter list f =
  let open Eta.Syntax in
  match list with
  | [] -> Eta.Effect.unit
  | item :: rest ->
      let* () = f item in
      effect_iter rest f

let rec effect_fold list init f =
  let open Eta.Syntax in
  match list with
  | [] -> Eta.Effect.pure init
  | item :: rest ->
      let* init = f init item in
      effect_fold rest init f

let one_or_none operation rows =
  match rows with
  | [] -> Eta.Effect.pure None
  | [ row ] -> Eta.Effect.pure (Some row)
  | _ -> Eta.Effect.fail (`Invalid_store (operation ^ " returned more than one row"))

let scalar operation rows =
  match rows with
  | [ row ] -> Eta.Effect.pure row
  | [] -> Eta.Effect.fail (`Invalid_store (operation ^ " returned no rows"))
  | _ -> Eta.Effect.fail (`Invalid_store (operation ^ " returned more than one row"))

let schemas =
  let open Q.Eta_schema in
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
        column ~not_null:true Spans.start_time_ms;
        column ~not_null:true Spans.end_time_ms;
        column ~not_null:true Spans.duration_ms;
        column ~not_null:true Spans.status;
        column Spans.status_message;
        column ~not_null:true Spans.attributes_json;
        column ~not_null:true Spans.resource_json;
        column ~not_null:true Spans.events_json;
        column ~not_null:true Spans.ingested_at_ms;
      ];
    create_index ~if_not_exists:true ~name:"idx_spans_service" Spans.table
      [ Q.Column.any Spans.service_name ];
    create_index ~if_not_exists:true ~name:"idx_spans_start_time" Spans.table
      [ Q.Column.any Spans.start_time_ms ];
    create_index ~if_not_exists:true ~name:"idx_spans_trace" Spans.table
      [ Q.Column.any Spans.trace_id ];
    create_index ~if_not_exists:true ~name:"idx_spans_span_id" Spans.table
      [ Q.Column.any Spans.span_id ];
    create_index ~if_not_exists:true ~name:"idx_spans_status" Spans.table
      [ Q.Column.any Spans.status ];
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
        column Logs.severity_number;
        column ~not_null:true Logs.timestamp_ms;
        column ~not_null:true Logs.body;
        column ~not_null:true Logs.attributes_json;
        column ~not_null:true Logs.resource_json;
        column ~not_null:true Logs.ingested_at_ms;
      ];
    create_index ~if_not_exists:true ~name:"idx_logs_service" Logs.table
      [ Q.Column.any Logs.service_name ];
    create_index ~if_not_exists:true ~name:"idx_logs_timestamp" Logs.table
      [ Q.Column.any Logs.timestamp_ms ];
    create_index ~if_not_exists:true ~name:"idx_logs_trace" Logs.table
      [ Q.Column.any Logs.trace_id ];
    create_index ~if_not_exists:true ~name:"idx_logs_span" Logs.table
      [ Q.Column.any Logs.span_id ];
    create_index ~if_not_exists:true ~name:"idx_logs_severity" Logs.table
      [ Q.Column.any Logs.severity_text ];
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
        column ~not_null:true Trace_summaries.started_at_ms;
        column ~not_null:true Trace_summaries.ended_at_ms;
        column ~not_null:true Trace_summaries.duration_ms;
        column ~not_null:true Trace_summaries.span_count;
        column ~not_null:true Trace_summaries.error_count;
        column ~not_null:true Trace_summaries.updated_at_ms;
      ];
    create_index ~if_not_exists:true ~name:"idx_trace_summaries_service"
      Trace_summaries.table [ Q.Column.any Trace_summaries.service_name ];
    create_index ~if_not_exists:true ~name:"idx_trace_summaries_started"
      Trace_summaries.table [ Q.Column.any Trace_summaries.started_at_ms ];
    create_index ~if_not_exists:true ~name:"idx_trace_summaries_updated"
      Trace_summaries.table [ Q.Column.any Trace_summaries.updated_at_ms ];
    create_table ~if_not_exists:true Metric_points.table
      [
        column ~primary_key:true Metric_points.id;
        column ~not_null:true Metric_points.service_name;
        column Metric_points.scope_name;
        column ~not_null:true Metric_points.name;
        column Metric_points.description;
        column Metric_points.unit_;
        column ~not_null:true Metric_points.kind;
        column Metric_points.start_time_ms;
        column ~not_null:true Metric_points.timestamp_ms;
        column ~not_null:true Metric_points.value;
        column ~not_null:true Metric_points.attributes_json;
        column ~not_null:true Metric_points.resource_json;
        column ~not_null:true Metric_points.raw_json;
        column ~not_null:true Metric_points.ingested_at_ms;
      ];
    create_index ~if_not_exists:true ~name:"idx_metric_points_service"
      Metric_points.table [ Q.Column.any Metric_points.service_name ];
    create_index ~if_not_exists:true ~name:"idx_metric_points_timestamp"
      Metric_points.table [ Q.Column.any Metric_points.timestamp_ms ];
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
    (fun schema -> Q.Compiled.schema_sql (Q.Eta_schema.compile schema))
    schemas

let schema_fingerprint =
  Digest.to_hex (Digest.string (String.concat "\n" schema_statements))

let init_schema runner =
  let open Eta.Syntax in
  let* () = effect_iter schemas (q_schema_pool runner) in
  let query =
    Q.Insert.(
      into Meta.table
      |> value Meta.key "schema_version"
      |> value Meta.value schema_version_text
      |> on_conflict_update [ Q.Column.any Meta.key ] ~set:[ Q.Column.any Meta.value ]
      |> compile)
  in
  let* _ = q_exec_pool runner query in
  Eta.Effect.unit

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

(* Eta SQL has no typed pragma API. Eta_sql.mli documents [Pool.Raw] as the
   escape hatch for "migrations, pragmas, diagnostics, and backend-specific
   SQL", so every pragma Inn runs goes through these two helpers, and no other
   raw SQL exists in the store. *)
let sqlite_pragma_int runner pragma =
  let open Eta.Syntax in
  let* rows =
    Q.Pool.Raw.query runner ("PRAGMA " ^ pragma) []
    |> Eta.Effect.map_error widen_pool_error
  in
  let column_value row =
    match Q.Row.fields row with
    | name :: _ -> Q.Row.int name row
    | [] -> None
  in
  match List.filter_map column_value rows with
  | value :: _ -> Eta.Effect.pure value
  | [] ->
      Eta.Effect.fail
        (`Invalid_store
          (Printf.sprintf "PRAGMA %s did not return an integer value" pragma))

let sqlite_pragma runner pragma =
  let open Eta.Syntax in
  (* [PRAGMA incremental_vacuum] steps once per freed page, so the pragma is
     folded rather than executed; [Raw.execute] rejects a row-returning
     statement. *)
  let* () =
    Q.Pool.Raw.fold runner ("PRAGMA " ^ pragma) [] ~init:()
      ~f:(fun () _ -> ())
    |> Eta.Effect.map_error widen_pool_error
  in
  Eta.Effect.unit

(* Live data is the pages in use, not the file size: SQLite never shrinks the
   file on delete alone, so the file size is a poor size-cap input (ret-zjzs). *)
let live_bytes runner =
  let open Eta.Syntax in
  let* page_count = sqlite_pragma_int runner "page_count" in
  let* freelist_count = sqlite_pragma_int runner "freelist_count" in
  let* page_size = sqlite_pragma_int runner "page_size" in
  Eta.Effect.pure ((page_count - freelist_count) * page_size)

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

let with_local_pool ?mode path f =
  Eta.Effect.with_resource
    ~acquire:
      (Q.Pool.create ~default_timeout:(Eta.Duration.ms 5000) ~max_size:1
         (local_sqlite_config ?mode path)
      |> Eta.Effect.map_error widen_pool_error)
    ~release:(fun pool ->
      Q.Pool.shutdown pool |> Eta.Effect.map_error widen_pool_error)
    f

let sqlite_magic = "SQLite format 3\000"

(* A zero-length file is a valid empty SQLite database; anything else must
   carry the SQLite header. Refusing a file that is not SQLite before opening a
   connection keeps a misconfigured path from being touched at all
   (schm-xkk2). *)
let file_is_sqlite path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
      let length = in_channel_length channel in
      if length = 0 then true
      else if length < String.length sqlite_magic then false
      else String.equal (really_input_string channel 16) sqlite_magic)

let read_database_state path =
  if not (Sys.file_exists path) then Eta.Effect.pure Database_absent
  else if not (file_is_sqlite path) then
    Eta.Effect.fail
      (`Invalid_store
        (Printf.sprintf "refusing to open %s: it is not an SQLite database" path))
  else
    let open Eta.Syntax in
    let* result =
      with_local_pool path (fun pool ->
          let open Eta.Syntax in
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
            Eta.Effect.pure
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
                Eta.Effect.pure Database_current
            | [ stored ] -> Eta.Effect.pure (Database_stale stored)
            | [] -> Eta.Effect.pure (Database_stale "none")
            | _ ->
                Eta.Effect.fail
                  (`Invalid_store
                    "inn_meta holds more than one schema_version row"))
      |> Eta.Effect.fold ~ok:(fun state -> Ok state) ~error:(fun error ->
             Error error)
    in
    match result with
    | Ok state -> Eta.Effect.pure state
    | Error error ->
        Eta.Effect.fail
          (`Invalid_store
            (Printf.sprintf "cannot read %s as an SQLite database: %s" path
               (Format.asprintf "%a" pp_error error)))

let remove_if_exists path =
  if Sys.file_exists path then
    try Sys.remove path with Sys_error _ -> ()

let remove_database_files path =
  List.iter remove_if_exists [ path; path ^ "-wal"; path ^ "-shm" ]

let default_report line = prerr_endline ("inn: " ^ line)

let open_ ?(now_ms = wall_now_ms) ?(report = default_report) config =
  let open Eta.Syntax in
  let path = config.Config.db_path in
  let* () =
    Eta.Effect.sync (fun () -> mkdir_p (Filename.dirname path))
  in
  let* state = read_database_state path in
  let* () =
    match state with
    | Database_current -> Eta.Effect.unit
    | Database_foreign ->
        Eta.Effect.fail
          (`Invalid_store
            (Printf.sprintf
               "refusing to recreate %s: it has tables but no inn_meta table, so it is not an Inn database"
               path))
    | Database_stale stored ->
        let* () =
          Eta.Effect.sync (fun () ->
              report
                (Printf.sprintf
                   "schema version %s at %s does not match version %d; deleting the old database and creating a fresh one"
                   stored path schema_version))
        in
        Eta.Effect.sync (fun () -> remove_database_files path)
    | Database_absent | Database_fresh ->
        Eta.Effect.sync (fun () -> remove_database_files path)
  in
  let* () =
    (* [auto_vacuum] must be set while the database is still empty, and before
       any other connection switches it to WAL, or SQLite ignores it. *)
    match state with
    | Database_current -> Eta.Effect.unit
    | _ ->
        with_local_pool ~mode:Sqlite.Read_write_create path (fun pool ->
            sqlite_pragma pool "auto_vacuum = INCREMENTAL")
  in
  let* pool =
    Q.Pool.create ~default_timeout:(Eta.Duration.ms 5000) ~max_size:4
      (sqlite_config path)
    |> Eta.Effect.map_error widen_pool_error
  in
  let* () = init_schema pool |> Eta.Effect.map_error widen_pool_error in
  Eta.Effect.pure { config; pool; now_ms; last_prune = None }

let close t = Q.Pool.shutdown t.pool |> Eta.Effect.map_error widen_pool_error

let with_db ?now_ms ?report config f =
  Eta.Effect.with_resource
    ~acquire:(open_ ?now_ms ?report config)
    ~release:close f

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
               start_time_ms ),
             ( end_time_ms,
               duration_ms,
               status,
               status_message,
               attributes_json,
               resource_json,
               events_json ) ) ->
        {
          Model.trace_id;
          span_id;
          parent_span_id;
          service_name;
          scope_name;
          operation_name;
          kind;
          start_time_ms;
          end_time_ms;
          duration_ms;
          status;
          status_message;
          attributes = attrs_of_json attributes_json;
          resource = attrs_of_json resource_json;
          events = events_of_json events_json;
        })
      (t2
         (t8 (one Spans.trace_id) (one Spans.span_id) (one Spans.parent_span_id)
            (one Spans.service_name) (one Spans.scope_name)
            (one Spans.operation_name) (one Spans.kind) (one Spans.start_time_ms))
         (t7 (one Spans.end_time_ms) (one Spans.duration_ms) (one Spans.status)
            (one Spans.status_message) (one Spans.attributes_json)
            (one Spans.resource_json) (one Spans.events_json))))

let log_projection =
  Q.Projection.(
    map
      (fun ( ( trace_id,
               span_id,
               service_name,
               scope_name,
               severity_text,
               severity_number,
               timestamp_ms,
               body ),
             (attributes_json, resource_json) ) ->
        {
          Model.trace_id;
          span_id;
          service_name;
          scope_name;
          severity_text;
          severity_number;
          timestamp_ms;
          body;
          attributes = attrs_of_json attributes_json;
          resource = attrs_of_json resource_json;
        })
      (t2
         (t8 (one Logs.trace_id) (one Logs.span_id) (one Logs.service_name)
            (one Logs.scope_name) (one Logs.severity_text)
            (one Logs.severity_number) (one Logs.timestamp_ms) (one Logs.body))
         (t2 (one Logs.attributes_json) (one Logs.resource_json))))

let metric_projection =
  Q.Projection.(
    map
      (fun ( ( service_name,
               scope_name,
               name,
               description,
               unit_,
               kind,
               start_time_ms,
               timestamp_ms ),
             (value, attributes_json, resource_json, raw_json) ) ->
        let raw_json =
          match Yojson.Safe.from_string raw_json with
          | json -> json
          | exception _ -> `Assoc []
        in
        {
          Model.service_name;
          scope_name;
          name;
          description;
          unit_;
          kind;
          start_time_ms;
          timestamp_ms;
          value;
          attributes = attrs_of_json attributes_json;
          resource = attrs_of_json resource_json;
          raw_json;
        })
      (t2
         (t8 (one Metric_points.service_name) (one Metric_points.scope_name)
            (one Metric_points.name) (one Metric_points.description)
            (one Metric_points.unit_) (one Metric_points.kind)
            (one Metric_points.start_time_ms) (one Metric_points.timestamp_ms))
         (t4 (one Metric_points.value) (one Metric_points.attributes_json)
            (one Metric_points.resource_json) (one Metric_points.raw_json))))

let trace_summary_projection =
  Q.Projection.(
    map
      (fun ( trace_id,
             service_name,
             root_operation_name,
             started_at_ms,
             ended_at_ms,
             duration_ms,
             span_count,
             error_count ) ->
        {
          Model.trace_id;
          service_name;
          root_operation_name;
          started_at_ms;
          ended_at_ms;
          duration_ms;
          span_count;
          error_count;
        })
      (t8 (one Trace_summaries.trace_id) (one Trace_summaries.service_name)
         (one Trace_summaries.root_operation_name)
         (one Trace_summaries.started_at_ms) (one Trace_summaries.ended_at_ms)
         (one Trace_summaries.duration_ms) (one Trace_summaries.span_count)
         (one Trace_summaries.error_count)))

let span_query trace_id =
    Q.Select.(
      from Spans.table span_projection
      |> where Q.Expr.(eq Spans.trace_id trace_id)
      |> order_by Spans.start_time_ms)

let select_spans_for_trace_pool runner trace_id =
  q_select_pool runner (span_query trace_id)

let select_spans_for_trace runner trace_id =
  q_select runner (span_query trace_id)

let span_id_query span_id =
  Q.Select.(
    from Spans.table span_projection
    |> where Q.Expr.(eq Spans.span_id span_id)
    |> order_by ~desc:true Spans.start_time_ms
    |> limit 1)

let logs_for_trace_query trace_id =
  Q.Select.(
    from Logs.table log_projection
    |> where Q.Expr.(eq Logs.trace_id (Some trace_id))
    |> order_by Logs.timestamp_ms)

let logs_for_span_query span_id =
  Q.Select.(
    from Logs.table log_projection
    |> where Q.Expr.(eq Logs.span_id (Some span_id))
    |> order_by Logs.timestamp_ms)

let sorted_unique values = List.sort_uniq String.compare values

let rec take count values =
  if count <= 0 then []
  else
    match values with
    | [] -> []
    | value :: rest -> value :: take (count - 1) rest

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

let attr_value key attrs = List.assoc_opt key attrs

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

let owner_ids_for_span_attr runner key value =
  q_select runner
    Q.Select.(
      from Span_attributes.table Q.Projection.(one Span_attributes.owner_id)
      |> where
           Q.Expr.(
             and_ (eq Span_attributes.key key) (eq Span_attributes.value value)))

let owner_ids_for_log_attr runner key value =
  q_select runner
    Q.Select.(
      from Log_attributes.table Q.Projection.(one Log_attributes.owner_id)
      |> where
           Q.Expr.(
             and_ (eq Log_attributes.key key) (eq Log_attributes.value value)))

let span_attr_values_for_key runner key =
  q_select runner
    Q.Select.(
      from Span_attributes.table
        Q.Projection.(t2 (one Span_attributes.owner_id) (one Span_attributes.value))
      |> where Q.Expr.(eq Span_attributes.key key))

let span_owner_ids_for_attrs runner attrs =
  let open Eta.Syntax in
  let* ids =
    effect_fold attrs None (fun acc (key, value) ->
        let* ids = owner_ids_for_span_attr runner key value in
        let ids = sorted_unique ids in
        let next =
          match acc with
          | None -> ids
          | Some existing -> intersect_sorted existing ids
        in
        Eta.Effect.pure (Some next))
  in
  Eta.Effect.pure (Option.value ids ~default:[])

let log_owner_ids_for_attrs runner attrs =
  let open Eta.Syntax in
  let* ids =
    effect_fold attrs None (fun acc (key, value) ->
        let* ids = owner_ids_for_log_attr runner key value in
        let ids = sorted_unique ids in
        let next =
          match acc with
          | None -> ids
          | Some existing -> intersect_sorted existing ids
        in
        Eta.Effect.pure (Some next))
  in
  Eta.Effect.pure (Option.value ids ~default:[])

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
  let open Eta.Syntax in
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
      |> value Span_attributes.value attr_value
      |> compile)
  in
  let* _ =
    effect_fold attrs 0 (fun index attr ->
        let* _ = q_exec_pool runner (insert index attr) in
        Eta.Effect.pure (index + 1))
  in
  Eta.Effect.unit

let insert_log_attrs runner owner_id attrs =
  let open Eta.Syntax in
  let insert index (key, attr_value) =
    Q.Insert.(
      into Log_attributes.table
      |> value Log_attributes.id (attr_row_id owner_id index key)
      |> value Log_attributes.owner_id owner_id
      |> value Log_attributes.key key
      |> value Log_attributes.value attr_value
      |> compile)
  in
  let* _ =
    effect_fold attrs 0 (fun index attr ->
        let* _ = q_exec_pool runner (insert index attr) in
        Eta.Effect.pure (index + 1))
  in
  Eta.Effect.unit

let insert_metric_attrs runner owner_id attrs =
  let open Eta.Syntax in
  let insert index (key, attr_value) =
    Q.Insert.(
      into Metric_attributes.table
      |> value Metric_attributes.id (attr_row_id owner_id index key)
      |> value Metric_attributes.owner_id owner_id
      |> value Metric_attributes.key key
      |> value Metric_attributes.value attr_value
      |> compile)
  in
  let* _ =
    effect_fold attrs 0 (fun index attr ->
        let* _ = q_exec_pool runner (insert index attr) in
        Eta.Effect.pure (index + 1))
  in
  Eta.Effect.unit

let refresh_trace_summary ~now_ms runner trace_id =
  let open Eta.Syntax in
  let* spans = select_spans_for_trace_pool runner trace_id in
  match spans with
  | [] -> Eta.Effect.unit
  | spans ->
      let ordered =
        List.sort
          (fun (left : Model.span) right ->
            compare left.start_time_ms right.start_time_ms)
          spans
      in
      let root =
        match List.find_opt (fun span -> Option.is_none span.Model.parent_span_id) ordered with
        | Some span -> span
        | None -> List.hd ordered
      in
      let started_at_ms =
        List.fold_left
          (fun acc (span : Model.span) -> min acc span.start_time_ms)
          root.start_time_ms spans
      in
      let ended_at_ms =
        List.fold_left
          (fun acc (span : Model.span) -> max acc span.end_time_ms)
          root.end_time_ms spans
      in
      let error_count =
        List.fold_left
          (fun acc (span : Model.span) ->
            if String.equal span.status "error" then acc + 1 else acc)
          0 spans
      in
      let insert =
        Q.Insert.(
          into Trace_summaries.table
          |> value Trace_summaries.trace_id trace_id
          |> value Trace_summaries.service_name root.service_name
          |> value Trace_summaries.root_operation_name root.operation_name
          |> value Trace_summaries.started_at_ms started_at_ms
          |> value Trace_summaries.ended_at_ms ended_at_ms
          |> value Trace_summaries.duration_ms
               (float_of_int (ended_at_ms - started_at_ms))
          |> value Trace_summaries.span_count (List.length spans)
          |> value Trace_summaries.error_count error_count
          |> value Trace_summaries.updated_at_ms now_ms
          |> on_conflict_do_nothing [ Q.Column.any Trace_summaries.trace_id ]
          |> compile)
      in
      let update =
        Q.Update.(
          table Trace_summaries.table
          |> set Trace_summaries.service_name root.service_name
          |> set Trace_summaries.root_operation_name root.operation_name
          |> set Trace_summaries.started_at_ms started_at_ms
          |> set Trace_summaries.ended_at_ms ended_at_ms
          |> set Trace_summaries.duration_ms (float_of_int (ended_at_ms - started_at_ms))
          |> set Trace_summaries.span_count (List.length spans)
          |> set Trace_summaries.error_count error_count
          |> set Trace_summaries.updated_at_ms now_ms
          |> where Q.Expr.(eq Trace_summaries.trace_id trace_id)
          |> compile)
      in
      let* _ = q_exec_pool runner insert in
      let* _ = q_exec_pool runner update in
      Eta.Effect.unit

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
  let open Eta.Syntax in
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
  let open Eta.Syntax in
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
  let open Eta.Syntax in
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
  Eta.Effect.pure (traces, spans)

let in_batch t delete =
  Q.Pool.with_transaction t.pool delete |> Eta.Effect.map_error widen_pool_error

let delete_log_batches t ?cutoff () =
  let rec loop deleted =
    let open Eta.Syntax in
    let* count =
      in_batch t (fun tx -> delete_log_batch tx ~batch:prune_batch_size cutoff)
    in
    if count <= 0 then Eta.Effect.pure deleted else loop (deleted + count)
  in
  loop 0

let delete_metric_batches t ?cutoff () =
  let rec loop deleted =
    let open Eta.Syntax in
    let* count =
      in_batch t (fun tx ->
          delete_metric_batch tx ~batch:prune_batch_size cutoff)
    in
    if count <= 0 then Eta.Effect.pure deleted else loop (deleted + count)
  in
  loop 0

let delete_trace_batches t ?cutoff () =
  let rec loop traces spans =
    let open Eta.Syntax in
    let* batch =
      in_batch t (fun tx -> delete_trace_batch tx ~batch:prune_batch_size cutoff)
    in
    let batch_traces, batch_spans = batch in
    if batch_traces <= 0 then Eta.Effect.pure (traces, spans)
    else loop (traces + batch_traces) (spans + batch_spans)
  in
  loop 0 0

let prune_time_retention t now_ms =
  let hour_ms = 60 * 60 * 1000 in
  let open Eta.Syntax in
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
  Eta.Effect.pure { traces; spans; logs; metric_points }

(* The size cap acts on live data, not on the file size, and stops as soon as
   live data is under the cap (ret-zjzs, ret-bizv). *)
let prune_size_retention t =
  let max_bytes = t.config.Config.max_db_size_mb * 1024 * 1024 in
  let batch = size_pressure_batch_size in
  let open Eta.Syntax in
  let* live = live_bytes t.pool in
  if live <= max_bytes then Eta.Effect.pure None
  else
    let rec loop counts =
      let* live = live_bytes t.pool in
      if live <= max_bytes then Eta.Effect.pure counts
      else
        let* logs = in_batch t (fun tx -> delete_log_batch tx ~batch None) in
        let counts = { counts with logs = counts.logs + logs } in
        let* live = live_bytes t.pool in
        if live <= max_bytes then Eta.Effect.pure counts
        else
          let* metric_points =
            in_batch t (fun tx -> delete_metric_batch tx ~batch None)
          in
          let counts =
            { counts with metric_points = counts.metric_points + metric_points }
          in
          let* live = live_bytes t.pool in
          if live <= max_bytes then Eta.Effect.pure counts
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
            if logs + metric_points + traces = 0 then Eta.Effect.pure counts
            else loop counts
    in
    let* counts = loop zero_prune_counts in
    Eta.Effect.pure (Some counts)

let add_prune_counts left right =
  {
    traces = left.traces + right.traces;
    spans = left.spans + right.spans;
    logs = left.logs + right.logs;
    metric_points = left.metric_points + right.metric_points;
  }

let prune ?now_ms t =
  let now = match now_ms with Some value -> value | None -> t.now_ms () in
  let open Eta.Syntax in
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
    else Eta.Effect.unit
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
  Eta.Effect.pure report

let last_prune t = t.last_prune

let ingest_traces t spans =
  let open Eta.Syntax in
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
        |> value Spans.kind span.kind
        |> value Spans.start_time_ms span.start_time_ms
        |> value Spans.end_time_ms span.end_time_ms
        |> value Spans.duration_ms span.duration_ms
        |> value Spans.status span.status
        |> value Spans.status_message span.status_message
        |> value Spans.attributes_json (Model.attrs_json_string span.attributes)
        |> value Spans.resource_json (Model.attrs_json_string span.resource)
        |> value Spans.events_json (events_json span.events)
        |> value Spans.ingested_at_ms now_ms
        |> on_conflict_do_nothing [ Q.Column.any Spans.id ]
        |> compile)
    in
    let update =
      Q.Update.(
        table Spans.table
        |> set Spans.trace_id span.trace_id
        |> set Spans.span_id span.span_id
        |> set Spans.parent_span_id span.parent_span_id
        |> set Spans.service_name span.service_name
        |> set Spans.scope_name span.scope_name
        |> set Spans.operation_name span.operation_name
        |> set Spans.kind span.kind
        |> set Spans.start_time_ms span.start_time_ms
        |> set Spans.end_time_ms span.end_time_ms
        |> set Spans.duration_ms span.duration_ms
        |> set Spans.status span.status
        |> set Spans.status_message span.status_message
        |> set Spans.attributes_json (Model.attrs_json_string span.attributes)
        |> set Spans.resource_json (Model.attrs_json_string span.resource)
        |> set Spans.events_json (events_json span.events)
        |> set Spans.ingested_at_ms now_ms
        |> where Q.Expr.(eq Spans.id id)
        |> compile)
    in
    let* _ = q_exec_pool runner insert in
    let* _ = q_exec_pool runner update in
    let* () = insert_span_attrs runner id (span.resource @ span.attributes) in
    Hashtbl.replace touched span.trace_id ();
    Eta.Effect.unit
  in
  let* () =
    Q.Pool.with_transaction t.pool (fun tx ->
        let* () = effect_iter spans (insert_span tx) in
        let trace_ids = List.of_seq (Hashtbl.to_seq_keys touched) in
        effect_iter trace_ids (refresh_trace_summary ~now_ms tx))
    |> Eta.Effect.map_error widen_pool_error
  in
  Eta.Effect.pure (List.length spans)

let ingest_logs t logs =
  let open Eta.Syntax in
  let now_ms = t.now_ms () in
  let insert_log runner (log : Model.log_record) =
    let id = fresh_id "log" in
    let query =
      Q.Insert.(
        into Logs.table
        |> value Logs.id id
        |> value Logs.trace_id log.trace_id
        |> value Logs.span_id log.span_id
        |> value Logs.service_name log.service_name
        |> value Logs.scope_name log.scope_name
        |> value Logs.severity_text log.severity_text
        |> value Logs.severity_number log.severity_number
        |> value Logs.timestamp_ms log.timestamp_ms
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
        effect_iter logs (insert_log tx))
    |> Eta.Effect.map_error widen_pool_error
  in
  Eta.Effect.pure (List.length logs)

let ingest_metrics t points =
  let open Eta.Syntax in
  let now_ms = t.now_ms () in
  let insert_point runner (point : Model.metric_point) =
    let id = fresh_id "metric" in
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
        |> value Metric_points.start_time_ms point.start_time_ms
        |> value Metric_points.timestamp_ms point.timestamp_ms
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
        effect_iter points (insert_point tx))
    |> Eta.Effect.map_error widen_pool_error
  in
  Eta.Effect.pure (List.length points)

let list_services_runner runner =
  let open Eta.Syntax in
  let* span_services =
    q_select runner
      Q.Select.(
        from Spans.table Q.Projection.(one Spans.service_name)
        |> distinct
        |> order_by Spans.service_name)
  in
  let* log_services =
    q_select runner
      Q.Select.(
        from Logs.table Q.Projection.(one Logs.service_name)
        |> distinct
        |> order_by Logs.service_name)
  in
  let* metric_services =
    q_select runner
      Q.Select.(
        from Metric_points.table Q.Projection.(one Metric_points.service_name)
        |> distinct
        |> order_by Metric_points.service_name)
  in
  Eta.Effect.pure
    (List.sort_uniq String.compare
       (span_services @ log_services @ metric_services))

let list_services t = list_services_runner t.pool

let list_trace_summaries ?service ?(limit = 100) t =
  let max_rows = limit in
  let predicate =
    match service with
    | None -> Q.Expr.true_
    | Some service -> Q.Expr.eq Trace_summaries.service_name service
  in
  let query =
    Q.Select.(
      from Trace_summaries.table trace_summary_projection
      |> where predicate
      |> order_by ~desc:true Trace_summaries.started_at_ms)
    |> Q.Select.limit max_rows
  in
  q_select t.pool query

let get_trace t trace_id =
  let open Eta.Syntax in
  let* summaries =
    q_select t.pool
      Q.Select.(
        from Trace_summaries.table trace_summary_projection
        |> where Q.Expr.(eq Trace_summaries.trace_id trace_id)
        |> limit 1)
  in
  let* summary = one_or_none "trace summary lookup" summaries in
  match summary with
  | None -> Eta.Effect.pure None
  | Some summary ->
      let* spans = select_spans_for_trace t.pool trace_id in
      let* logs = q_select t.pool (logs_for_trace_query trace_id) in
      Eta.Effect.pure (Some { Model.summary; spans; logs })

let get_span t span_id =
  let open Eta.Syntax in
  let* spans = q_select t.pool (span_id_query span_id) in
  one_or_none "span lookup" spans

let list_trace_spans t trace_id = select_spans_for_trace t.pool trace_id

let list_trace_logs t trace_id = q_select t.pool (logs_for_trace_query trace_id)

let list_span_logs t span_id = q_select t.pool (logs_for_span_query span_id)

let span_search_predicate (filter : span_search_filter) owner_ids parent_span_ids =
  let predicate = Q.Expr.true_ in
  let predicate =
    match filter.service with
    | None -> predicate
    | Some service -> Q.Expr.and_ predicate (Q.Expr.eq Spans.service_name service)
  in
  let predicate =
    match filter.trace_id with
    | None -> predicate
    | Some trace_id -> Q.Expr.and_ predicate (Q.Expr.eq Spans.trace_id trace_id)
  in
  let predicate =
    match filter.operation with
    | None -> predicate
    | Some operation ->
        Q.Expr.and_ predicate (Q.Expr.eq Spans.operation_name operation)
  in
  let predicate =
    match filter.status with
    | None -> predicate
    | Some status -> Q.Expr.and_ predicate (Q.Expr.eq Spans.status status)
  in
  let predicate =
    match owner_ids with
    | None -> predicate
    | Some ids -> Q.Expr.and_ predicate (Q.Expr.in_values Spans.id ids)
  in
  match parent_span_ids with
  | None -> predicate
  | Some ids ->
      Q.Expr.and_ predicate
        (Q.Expr.in_values Spans.parent_span_id (List.map Option.some ids))

let search_spans (filter : span_search_filter) t =
  let open Eta.Syntax in
  let* owner_ids =
    match filter.attrs with
    | [] -> Eta.Effect.pure None
    | attrs ->
        let* ids = span_owner_ids_for_attrs t.pool attrs in
        Eta.Effect.pure (Some ids)
  in
  match owner_ids with
  | Some [] -> Eta.Effect.pure []
  | _ ->
      let* parent_span_ids =
        match filter.parent_operation with
        | None -> Eta.Effect.pure None
        | Some operation ->
            let* ids = parent_span_ids_for_operation t.pool ?service:filter.service operation in
            Eta.Effect.pure (Some (sorted_unique ids))
      in
      (match parent_span_ids with
      | Some [] -> Eta.Effect.pure []
      | _ ->
          q_select t.pool
            Q.Select.(
              from Spans.table span_projection
              |> where (span_search_predicate filter owner_ids parent_span_ids)
              |> order_by ~desc:true Spans.start_time_ms
              |> limit filter.limit))

let trace_summary_search_query (filter : trace_search_filter) trace_ids =
  let predicate = Q.Expr.true_ in
  let predicate =
    match filter.service with
    | None -> predicate
    | Some service ->
        Q.Expr.and_ predicate (Q.Expr.eq Trace_summaries.service_name service)
  in
  let predicate =
    match trace_ids with
    | None -> predicate
    | Some ids ->
        Q.Expr.and_ predicate (Q.Expr.in_values Trace_summaries.trace_id ids)
  in
  Q.Select.(
    from Trace_summaries.table trace_summary_projection
    |> where predicate
    |> order_by ~desc:true Trace_summaries.started_at_ms
    |> limit filter.limit)

let search_traces (filter : trace_search_filter) t =
  let needs_span_filter =
    Option.is_some filter.operation || Option.is_some filter.status
    || filter.attrs <> []
  in
  if not needs_span_filter then q_select t.pool (trace_summary_search_query filter None)
  else
    let open Eta.Syntax in
    let span_filter =
      {
        service = filter.service;
        trace_id = None;
        operation = filter.operation;
        parent_operation = None;
        status = filter.status;
        attrs = filter.attrs;
        limit = 10_000;
      }
    in
    let* spans = search_spans span_filter t in
    let trace_ids =
      spans |> List.map (fun (span : Model.span) -> span.trace_id) |> sorted_unique
    in
    match trace_ids with
    | [] -> Eta.Effect.pure []
    | trace_ids -> q_select t.pool (trace_summary_search_query filter (Some trace_ids))

let log_predicate (filter : log_filter) =
  let predicate = Q.Expr.true_ in
  let predicate =
    match filter.service with
    | None -> predicate
    | Some service -> Q.Expr.and_ predicate (Q.Expr.eq Logs.service_name service)
  in
  let predicate =
    match filter.severity with
    | None -> predicate
    | Some severity -> Q.Expr.and_ predicate (Q.Expr.eq Logs.severity_text severity)
  in
  match filter.contains with
  | None -> predicate
  | Some contains ->
      Q.Expr.and_ predicate (Q.Expr.like Logs.body ("%" ^ contains ^ "%"))

let list_logs (filter : log_filter) t =
  q_select t.pool
    Q.Select.(
      from Logs.table log_projection
      |> where (log_predicate filter)
      |> order_by ~desc:true Logs.timestamp_ms
      |> limit filter.limit)

let log_search_predicate (filter : log_search_filter) owner_ids =
  let predicate = Q.Expr.true_ in
  let predicate =
    match filter.service with
    | None -> predicate
    | Some service -> Q.Expr.and_ predicate (Q.Expr.eq Logs.service_name service)
  in
  let predicate =
    match filter.trace_id with
    | None -> predicate
    | Some trace_id ->
        Q.Expr.and_ predicate (Q.Expr.eq Logs.trace_id (Some trace_id))
  in
  let predicate =
    match filter.span_id with
    | None -> predicate
    | Some span_id -> Q.Expr.and_ predicate (Q.Expr.eq Logs.span_id (Some span_id))
  in
  let predicate =
    match filter.severity with
    | None -> predicate
    | Some severity -> Q.Expr.and_ predicate (Q.Expr.eq Logs.severity_text severity)
  in
  let predicate =
    match filter.body with
    | None -> predicate
    | Some body -> Q.Expr.and_ predicate (Q.Expr.like Logs.body ("%" ^ body ^ "%"))
  in
  match owner_ids with
  | None -> predicate
  | Some ids -> Q.Expr.and_ predicate (Q.Expr.in_values Logs.id ids)

let search_logs (filter : log_search_filter) t =
  let open Eta.Syntax in
  let* owner_ids =
    match filter.attrs with
    | [] -> Eta.Effect.pure None
    | attrs ->
        let* ids = log_owner_ids_for_attrs t.pool attrs in
        Eta.Effect.pure (Some ids)
  in
  match owner_ids with
  | Some [] -> Eta.Effect.pure []
  | _ ->
      q_select t.pool
        Q.Select.(
          from Logs.table log_projection
          |> where (log_search_predicate filter owner_ids)
          |> order_by ~desc:true Logs.timestamp_ms
          |> limit filter.limit)

let trace_attr_lookup t trace_ids key =
  let open Eta.Syntax in
  let trace_id_set = String_set.of_list trace_ids in
  let* rows = span_attr_values_for_key t.pool key in
  let table = Hashtbl.create 16 in
  List.iter
    (fun (owner_id, value) ->
      let trace_id = owner_trace_id owner_id in
      if
        String_set.mem trace_id trace_id_set
        && not (Hashtbl.mem table trace_id)
      then Hashtbl.add table trace_id value)
    rows;
  Eta.Effect.pure table

let trace_stats (filter : trace_stats_filter) t =
  let open Eta.Syntax in
  let* summaries =
    search_traces
      {
        service = filter.service;
        operation = filter.operation;
        status = filter.status;
        attrs = filter.attrs;
        limit = 10_000;
      }
      t
  in
  let trace_ids =
    summaries
    |> List.map (fun (summary : Model.trace_summary) -> summary.trace_id)
    |> sorted_unique
  in
  let* attr_lookup =
    match attr_group_key filter.group_by with
    | None -> Eta.Effect.pure None
    | Some key ->
        let* lookup = trace_attr_lookup t trace_ids key in
        Eta.Effect.pure (Some lookup)
  in
  let buckets = Hashtbl.create 16 in
  let group_for_summary (summary : Model.trace_summary) =
    match filter.group_by with
    | "service" -> summary.service_name
    | "operation" -> summary.root_operation_name
    | "status" -> if summary.error_count > 0 then "error" else "ok"
    | group_by -> (
        match (attr_group_key group_by, attr_lookup) with
        | Some _, Some lookup ->
            Option.value (Hashtbl.find_opt lookup summary.trace_id)
              ~default:"unknown"
        | _ -> "unknown")
  in
  List.iter
    (fun (summary : Model.trace_summary) ->
      let group = group_for_summary summary in
      let bucket =
        match Hashtbl.find_opt buckets group with
        | Some bucket -> bucket
        | None ->
            let bucket =
              {
                stat_count = 0;
                total_duration_ms = 0.0;
                durations_ms = [];
                error_traces = 0;
              }
            in
            Hashtbl.add buckets group bucket;
            bucket
      in
      bucket.stat_count <- bucket.stat_count + 1;
      bucket.total_duration_ms <- bucket.total_duration_ms +. summary.duration_ms;
      bucket.durations_ms <- summary.duration_ms :: bucket.durations_ms;
      if summary.error_count > 0 then
        bucket.error_traces <- bucket.error_traces + 1)
    summaries;
  let items =
    Hashtbl.fold
      (fun group bucket acc ->
        let count = bucket.stat_count in
        let value =
          match filter.agg with
          | "count" -> float_of_int count
          | "avg_duration" ->
              bucket.total_duration_ms /. float_of_int (max 1 count)
          | "p95_duration" -> percentile 0.95 bucket.durations_ms
          | "error_rate" ->
              float_of_int bucket.error_traces /. float_of_int (max 1 count)
          | _ -> float_of_int count
        in
        { Model.group; value; count } :: acc)
      buckets []
  in
  Eta.Effect.pure (sort_stat_items filter.limit items)

let log_stats (filter : log_stats_filter) t =
  let open Eta.Syntax in
  let* logs =
    search_logs
      {
        service = filter.service;
        trace_id = filter.trace_id;
        span_id = filter.span_id;
        severity = filter.severity;
        body = filter.body;
        attrs = filter.attrs;
        limit = 10_000;
      }
      t
  in
  let groups = Hashtbl.create 16 in
  let group_for_log (log : Model.log_record) =
    match filter.group_by with
    | "service" -> log.service_name
    | "severity" -> log.severity_text
    | "scope" -> Option.value log.scope_name ~default:"unknown"
    | group_by -> (
        match attr_group_key group_by with
        | Some key ->
            Option.value
              (match attr_value key log.attributes with
              | Some _ as value -> value
              | None -> attr_value key log.resource)
              ~default:"unknown"
        | None -> "unknown")
  in
  List.iter (fun log -> add_count groups (group_for_log log)) logs;
  let items =
    Hashtbl.fold
      (fun group count acc ->
        { Model.group; value = float_of_int count; count } :: acc)
      groups []
  in
  Eta.Effect.pure (sort_stat_items filter.limit items)

let count_span_facets spans field key =
  let counts = Hashtbl.create 16 in
  let count_attrs attrs =
    match field with
    | "attribute_keys" -> List.iter (fun (key, _) -> add_count counts key) attrs
    | "attribute_values" -> (
        match key with
        | None -> ()
        | Some wanted ->
            List.iter
              (fun (key, value) ->
                if String.equal key wanted then add_count counts value)
              attrs)
    | _ -> ()
  in
  List.iter
    (fun (span : Model.span) ->
      match field with
      | "service" -> add_count counts span.service_name
      | "operation" -> add_count counts span.operation_name
      | "status" -> add_count counts span.status
      | "attribute_keys" | "attribute_values" ->
          count_attrs (span.resource @ span.attributes)
      | _ -> ())
    spans;
  counts

let count_log_facets logs field key =
  let counts = Hashtbl.create 16 in
  let count_attrs attrs =
    match field with
    | "attribute_keys" -> List.iter (fun (key, _) -> add_count counts key) attrs
    | "attribute_values" -> (
        match key with
        | None -> ()
        | Some wanted ->
            List.iter
              (fun (key, value) ->
                if String.equal key wanted then add_count counts value)
              attrs)
    | _ -> ()
  in
  List.iter
    (fun (log : Model.log_record) ->
      match field with
      | "service" -> add_count counts log.service_name
      | "severity" -> add_count counts log.severity_text
      | "scope" -> add_count counts (Option.value log.scope_name ~default:"unknown")
      | "attribute_keys" | "attribute_values" ->
          count_attrs (log.resource @ log.attributes)
      | _ -> ())
    logs;
  counts

let facets (filter : facet_filter) t =
  let open Eta.Syntax in
  match filter.kind with
  | "traces" ->
      let* spans =
        search_spans
          {
            service = filter.service;
            trace_id = None;
            operation = None;
            parent_operation = None;
            status = None;
            attrs = [];
            limit = 10_000;
          }
          t
      in
      Eta.Effect.pure
        (facet_items_from_counts filter.limit
           (count_span_facets spans filter.field filter.key))
  | "logs" ->
      let* logs =
        search_logs
          {
            service = filter.service;
            trace_id = None;
            span_id = None;
            severity = None;
            body = None;
            attrs = [];
            limit = 10_000;
          }
          t
      in
      Eta.Effect.pure
        (facet_items_from_counts filter.limit
           (count_log_facets logs filter.field filter.key))
  | _ -> Eta.Effect.pure []

let metric_predicate (filter : metric_filter) =
  let predicate = Q.Expr.true_ in
  let predicate =
    match filter.service with
    | None -> predicate
    | Some service ->
        Q.Expr.and_ predicate (Q.Expr.eq Metric_points.service_name service)
  in
  match filter.name with
  | None -> predicate
  | Some name -> Q.Expr.and_ predicate (Q.Expr.eq Metric_points.name name)

let list_metric_points (filter : metric_filter) t =
  q_select t.pool
    Q.Select.(
      from Metric_points.table metric_projection
      |> where (metric_predicate filter)
      |> order_by ~desc:true Metric_points.timestamp_ms
      |> limit filter.limit)

let count_rows runner table =
  let open Eta.Syntax in
  let* rows = q_select runner Q.Select.(from table Q.Projection.(count ())) in
  scalar "count" rows

let stats t =
  let open Eta.Syntax in
  let* spans = count_rows t.pool Spans.table in
  let* logs = count_rows t.pool Logs.table in
  let* metric_points = count_rows t.pool Metric_points.table in
  let* traces = count_rows t.pool Trace_summaries.table in
  let* services = list_services_runner t.pool in
  let* live_bytes = live_bytes t.pool in
  Eta.Effect.pure
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
