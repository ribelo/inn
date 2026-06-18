type t = {
  state_dir : string;
  db_path : string;
  host : string;
  port : int;
  base_url : string;
  retention_hours : int;
  max_db_size_mb : int;
}

val default_port : int
val resolve : ?env:(string -> string option) -> ?home:string -> unit -> (t, string) result
val resolve_exn : unit -> t
