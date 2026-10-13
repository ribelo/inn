type t = {
  state_dir : string;
  data_dir : string;
  (** [state_dir/segments]: the segment files of the store. *)
  host : string;
  port : int;
  base_url : string;
  max_db_size_mb : int;
  (** The whole store budget. Inn keeps the newest telemetry that fits. *)
}

val default_port : int
val default_max_db_size_mb : int
val resolve :
  caps:< Ox_caps.Cap.env ; .. > ->
  ?env:(string -> string option) ->
  ?home:string ->
  unit ->
  (t, string) result
(** [caps] supplies the default [env] callback and reads HOME even when [home]
    is supplied, because the default home expression is evaluated eagerly.
    ^inncap-q8hn ^innlint-b7km

    Suspension: may suspend in the caller-supplied [env] callback; default
    environment reads and diagnostic formatting are delegated to
    [Ox_caps.Cap_sys.getenv_opt] and [Stdlib.Printf.sprintf], with no scheduling operation
    in local resolution.
    Cancellation: depends on the caller-supplied [env] callback and delegated
    [Ox_caps.Cap_sys.getenv_opt] and [Stdlib.Printf.sprintf] calls; local resolution adds
    no cancellation check, and exceptions propagate.
    Finalizers: no resource is acquired or release hook registered.
    Locking: no lock is acquired around [env].
    Cancellation safety: unsafe because progress is lost if [env] cancels; sampled
    configuration values are discarded and callback effects are not rolled back. *)

val resolve_exn : caps:< Ox_caps.Cap.env ; .. > -> unit -> t
(** Resolve using the default environment reader. ^innlint-b7km

    Suspension: never suspends in local resolution; environment reads and
    diagnostic formatting are delegated to [Ox_caps.Cap_sys.getenv_opt] and
    [Stdlib.Printf.sprintf].
    Cancellation: not a cancellation point in local resolution; environment reads
    and diagnostic formatting are delegated to [Ox_caps.Cap_sys.getenv_opt] and
    [Stdlib.Printf.sprintf], whose exceptions propagate.
    Finalizers: no resource is acquired or release hook registered.
    Locking: no lock is acquired by resolution.

    @raise Invalid_argument when [resolve] returns a configuration error. *)
