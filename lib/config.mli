type t = {
  state_dir : string;
  db_path : string;
  host : string;
  port : int;
  base_url : string;
  traces_retention_hours : int;
  logs_retention_hours : int;
  metrics_retention_hours : int;
  prune_interval_seconds : int;
  max_db_size_mb : int;
}

val default_port : int
val resolve :
  caps:< Ox_caps.Cap.env ; .. > ->
  ?env:(string -> string option) ->
  ?home:string ->
  unit ->
  (t, string) result
(** [caps] reads the environment when [env] or [home] is omitted. ^inncap-q8hn *)

val resolve_exn : caps:< Ox_caps.Cap.env ; .. > -> unit -> t
