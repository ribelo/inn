type t

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

type metric_filter = {
  service : string option;
  name : string option;
  limit : int;
}

type error =
  [ Eta_sql.Pool.error
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
  ?now_ms:(unit -> int) ->
  ?report:(string -> unit) ->
  Config.t ->
  (t, error) Eta.Effect.t
(** Open the store, recreating a database whose schema version differs from
    [schema_version]. [now_ms] is the ingestion clock (the wall clock by
    default) and [report] receives schema diagnostics (stderr by default). *)

val close : t -> (unit, error) Eta.Effect.t

val with_db :
  ?now_ms:(unit -> int) ->
  ?report:(string -> unit) ->
  Config.t ->
  (t -> ('a, error) Eta.Effect.t) ->
  ('a, error) Eta.Effect.t

val prune : ?now_ms:int -> t -> (Model.prune_report, error) Eta.Effect.t
(** Delete expired telemetry and, when live data is over the size cap, the
    oldest telemetry until it is under the cap. [now_ms] is the current
    ingestion-clock time. *)

val last_prune : t -> Model.prune_report option

val ingest_traces : t -> Model.span list -> (int, error) Eta.Effect.t
val ingest_logs : t -> Model.log_record list -> (int, error) Eta.Effect.t
val ingest_metrics : t -> Model.metric_point list -> (int, error) Eta.Effect.t

val list_services : t -> (string list, error) Eta.Effect.t
val list_trace_summaries :
  ?service:string -> ?limit:int -> t -> (Model.trace_summary list, error) Eta.Effect.t
val get_trace : t -> string -> (Model.trace option, error) Eta.Effect.t
val get_span : t -> string -> (Model.span option, error) Eta.Effect.t
val list_trace_spans : t -> string -> (Model.span list, error) Eta.Effect.t
val list_trace_logs : t -> string -> (Model.log_record list, error) Eta.Effect.t
val list_span_logs : t -> string -> (Model.log_record list, error) Eta.Effect.t
val list_logs : log_filter -> t -> (Model.log_record list, error) Eta.Effect.t
val search_spans :
  span_search_filter -> t -> (Model.span list, error) Eta.Effect.t
val search_traces :
  trace_search_filter -> t -> (Model.trace_summary list, error) Eta.Effect.t
val search_logs :
  log_search_filter -> t -> (Model.log_record list, error) Eta.Effect.t
val trace_stats :
  trace_stats_filter -> t -> (Model.stat_item list, error) Eta.Effect.t
val log_stats :
  log_stats_filter -> t -> (Model.stat_item list, error) Eta.Effect.t
val facets : facet_filter -> t -> (Model.facet_item list, error) Eta.Effect.t
val list_metric_points :
  metric_filter -> t -> (Model.metric_point list, error) Eta.Effect.t
val stats : t -> (Model.stats, error) Eta.Effect.t
