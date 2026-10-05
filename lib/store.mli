type t

type ingest_counts = {
  spans : int;
  logs : int;
  metric_points : int;
}

type 'a page = {
  items : 'a list;
  next : Model.cursor_position option;
}
(** One page of a keyset-paginated query. [next] is [Some] only when more rows
    exist after [items], so a caller emits a next cursor only then
    (win-7xet). *)

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

type ai_call_filter = {
  service : string option;
  trace_id : string option;
  operation : string option;
  status : string option;
  provider : string option;
  model : string option;
  session_id : string option;
  function_id : string option;
  finish_reason : string option;
  text : string option;
  attrs : (string * string) list;
  window : Model.window;
  cursor : Model.cursor_position option;
  limit : int;
}
(** Every AI call filter, resolved by the caller. The store never parses a
    query parameter (aic-yfcd). *)

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

type error =
  [ Ox_sql.Pool.error
  | `Invalid_store of string
  ]

val pp_error : Format.formatter -> error -> unit

val schema_version : int
(** The schema version written to and expected from the database. Bump it with
    every schema statement change; [schema_fingerprint] and the schema test
    guard that. *)

val schema_fingerprint : string
(** Fingerprint of the compiled schema statements for [schema_version]. *)

val open_ :
  caps:< Ox_caps.Cap.time
       ; Ox_caps.Cap.fs_read
       ; Ox_caps.Cap.fs_write
       ; Ox_caps.Cap.stderr
       ; .. > ->
  sw:Eio.Switch.t ->
  ?now_ms:(unit -> int) ->
  ?report:(string -> unit) ->
  Config.t ->
  (t, error) result
(** Open the store, recreating a database whose schema version differs from
    [schema_version]. [now_ms] is the ingestion clock (the wall clock by the
    default) and [report] receives schema diagnostics (stderr by default).
    [now_ms] is stored for later use, not called while opening. ^innlint-b7km

    Opening delegates filesystem work to [Ox_caps.Cap_unix.mkdir],
    [Ox_caps.Cap_stdlib.open_in_bin] and [Ox_caps.Cap_sys.remove], query construction
    to [Ox_sql.Dsl], schema compilation to [Ox_sql.Ox_schema.compile], execution
    to [Ox_sql.Pool], error rendering to
    [Ox_sql.pp_error], timeout conversion to [Ox.Duration.seconds], and temporary
    scope management to [Eio.Switch.run]. Named Stdlib helpers are [Sys.file_exists],
    [Filename.dirname], [close_in], [in_channel_length], [really_input_string],
    [Printf.sprintf], [Format.asprintf], [Format.fprintf], [Format.pp_print_string],
    comparisons and concatenation, and [String], [List] and [Result] operations.

    Suspension: may suspend in the caller-supplied [report] callback and waits
    delegated to [Ox_sql.Pool] and [Eio.Switch.run]; [Ox_caps] filesystem calls
    and Stdlib channel operations may block the domain, while other behaviour
    is delegated to [Ox_sql.Dsl], [Ox_sql.Ox_schema.compile], [Ox_sql.pp_error],
    [Ox.Duration.seconds] and the named Stdlib helpers.
    Cancellation: propagates from [report] and calls delegated to [Ox_sql.Pool],
    [Eio.Switch.run], [Ox_caps], [Ox_sql.Dsl], [Ox_sql.Ox_schema.compile], [Ox_sql.pp_error],
    [Ox.Duration.seconds] and the named Stdlib helpers; [Ox_sql.Pool] owns
    protection of its bookkeeping and cleanup.
    Finalizers: Stdlib [Fun.protect] closes the inspected file; temporary pools
    are owned by local Eio switches, while the returned pool is owned by [sw],
    whose release shuts it down even after cancellation during schema setup.
    Locking: [Ox_sql.Pool] owns its lease and internal locks; no Inn lock spans
    [report], and SQLite calls retain their native locking.
    Cancellation safety: unsafe because data is lost if an obsolete database
    has been deleted before cancellation; directory creation and completed SQL
    are not rolled back.

    Exceptions from [report], [Ox_sql.Pool], [Ox_caps.Cap_unix.mkdir] and Stdlib
    input-channel operations propagate.
    @raise Eio.Cancel.Cancelled if [Eio.Switch.run] observes an already-cancelled
    calling fiber while entering a temporary [Ox_sql.Pool] scope, or cancellation
    propagates from delegated pool waits or the caller-supplied [report] callback.
    @raise Invalid_argument if [Ox_sql.Pool.create] registers on a finished [sw]. *)

val close : t -> (unit, error) result

val ping : t -> (unit, error) result
(** A cheap metadata read that proves the store still answers, used by
    [GET /ready]. *)

val with_db :
  caps:< Ox_caps.Cap.time
       ; Ox_caps.Cap.fs_read
       ; Ox_caps.Cap.fs_write
       ; Ox_caps.Cap.stderr
       ; .. > ->
  sw:Eio.Switch.t ->
  ?now_ms:(unit -> int) ->
  ?report:(string -> unit) ->
  Config.t ->
  (t -> ('a, error) result) ->
  ('a, error) result
(** Open a store, call the supplied callback and then close the store when the
    callback returns a result; its [Error] takes precedence over a close error.
    ^innlint-b7km

    Suspension: may suspend in the caller-supplied store callback or [report],
    and waits delegated to [Ox_sql.Pool] and [Eio.Switch.run]; opening also
    delegates filesystem work to [Ox_caps], query construction to [Ox_sql.Dsl],
    schema compilation to [Ox_sql.Ox_schema.compile], error rendering to
    [Ox_sql.pp_error], timeout conversion to
    [Ox.Duration.seconds], and other behaviour to the Stdlib helpers named in
    [open_], including blocking channel I/O.
    Cancellation: propagates from the caller callbacks and calls delegated to
    [Ox_sql.Pool], [Eio.Switch.run], [Ox_caps], [Ox_sql.Dsl], [Ox_sql.Ox_schema.compile], [Ox_sql.pp_error],
    [Ox.Duration.seconds] and the Stdlib helpers named in [open_]; [Ox_sql.Pool]
    owns protection of its bookkeeping and cleanup.
    Finalizers: on a normal callback return [close] is called; an exception or
    cancellation bypasses that call, leaving the pool owned by [sw] until its
    release hook runs; temporary opening resources follow [open_]'s cleanup.
    Locking: no Inn lock spans the store callback or [report]; [Ox_sql.Pool] and
    SQLite own locks taken by database operations.
    Cancellation safety: unsafe because progress is lost; completed SQL and
    caller callback effects are not rolled back, and [open_] may already have
    deleted an obsolete database.

    Exceptions from the store callback, [report], [Ox_sql.Pool] and [open_]'s
    [Ox_caps.Cap_unix.mkdir] and Stdlib input-channel operations propagate.
    @raise Eio.Cancel.Cancelled if [open_]'s [Eio.Switch.run] observes caller
    cancellation on entry to a temporary [Ox_sql.Pool] scope, or cancellation
    propagates from delegated pool waits or either caller callback.
    @raise Invalid_argument if [Ox_sql.Pool.create] registers on a finished [sw]. *)

val now_ms : t -> int
(** The store clock. The HTTP layer resolves a lookback window once per request
    against this clock, so tests can drive it. *)

val span_position : Model.span -> Model.cursor_position
(** The keyset position of a span row: its start time and unique row id, for
    span search. *)

val prune : ?now_ms:int -> t -> (Model.prune_report, error) result
(** Delete expired telemetry and, when live data is over the size cap, the
    oldest telemetry until it is under the cap. [now_ms] is the current
    ingestion-clock time. *)

val last_prune : t -> Model.prune_report option

val ingest_traces : t -> Model.span list -> (int, error) result
val ingest_logs : t -> Model.log_record list -> (int, error) result
val ingest_metrics : t -> Model.metric_point list -> (int, error) result

val list_services :
  ?window:Model.window -> ?include_metrics:bool -> t -> (string list, error) result
val list_trace_summaries :
  ?service:string ->
  window:Model.window ->
  ?cursor:Model.cursor_position ->
  limit:int ->
  t ->
  (Model.trace_summary page, error) result
val get_trace : t -> string -> (Model.trace option, error) result
(** [None] only when the trace has no spans at all: a trace whose summary row is
    missing is still served from its spans (tree-ddll). *)
val get_span : t -> string -> (Model.span option, error) result
val get_span_node :
  t -> string -> (Model.span_node option, error) result
(** The span with its place in the trace tree (tree-o79f). *)
val list_trace_spans :
  t ->
  window:Model.window ->
  ?cursor:Model.cursor_position ->
  limit:int ->
  string ->
  (Model.span_node page, error) result
(** Depth-first tree order, the same one the trace detail returns (tree-uv04).
    The cursor carries the position in that order. *)
val span_ai_kind : t -> string -> (string option, error) result
(** The stored AI classification of a span: [call], [tool], [nested], [none],
    or [None] when no such span exists (aic-t8tl). *)
val list_span_children : t -> string -> (Model.span list, error) result
val list_trace_logs :
  t ->
  window:Model.window ->
  ?cursor:Model.cursor_position ->
  limit:int ->
  string ->
  (Model.log_record page, error) result
val list_span_logs :
  t ->
  window:Model.window ->
  ?cursor:Model.cursor_position ->
  limit:int ->
  string ->
  (Model.log_record page, error) result
val list_logs :
  ?min_severity:int -> log_filter -> t -> (Model.log_record page, error) result
val search_ai_calls :
  ?attr_contains:(string * string) list -> ?min_duration_ms:float ->
  ai_call_filter -> t ->
  (Model.ai_call page, error) result
(** AI calls only, over their own indexed table (aic-yfcd). *)
val search_spans :
  ?attr_contains:(string * string) list -> ?min_duration_ms:float -> span_search_filter -> t -> (Model.span page, error) result
val search_traces :
  ?attr_contains:(string * string) list -> ?min_duration_ms:float -> ?text:string ->
  trace_search_filter -> t -> (Model.trace_summary page, error) result
val search_logs :
  ?attr_contains:(string * string) list -> ?min_severity:int -> log_search_filter -> t -> (Model.log_record page, error) result
val trace_stats :
  ?attr_contains:(string * string) list -> ?min_duration_ms:float -> trace_stats_filter -> t -> (Model.stat_item list, error) result
val ai_stats :
  ?attr_contains:(string * string) list -> ?min_duration_ms:float ->
  group_by:string -> agg:string -> ai_call_filter -> t ->
  (Model.stat_item list, error) result
(** Exact SQL grouping and aggregation over AI calls; an unknown [group_by] is
    an empty list, and the HTTP layer rejects it first (aic-qpv6, aic-e67r). *)
val log_stats :
  ?attr_contains:(string * string) list -> ?min_severity:int -> log_stats_filter -> t -> (Model.stat_item list, error) result
val facets : facet_filter -> t -> (Model.facet_item list, error) result
val list_metric_points :
  metric_filter -> t -> (Model.metric_point page, error) result
val stats : ?window:Model.window -> t -> (Model.stats, error) result
