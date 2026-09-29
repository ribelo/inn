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

let default_port = 27687
let default_traces_retention_hours = 48
let default_logs_retention_hours = 24
let default_metrics_retention_hours = 48
let default_prune_interval_seconds = 300
let default_max_db_size_mb = 1024

let getenv ~caps key =
  match Ox_caps.Cap_sys.getenv_opt ~caps key with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None

let clean_env env key =
  match env key with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let parse_positive_int ~name value =
  match int_of_string_opt value with
  | Some n when n > 0 -> Ok n
  | _ -> Error (Printf.sprintf "%s must be a positive integer, got %S" name value)

let positive_int_env env ~name ~default =
  parse_positive_int ~name
    (Option.value (clean_env env name) ~default:(string_of_int default))

let default_home ~caps () =
  match Ox_caps.Cap_sys.getenv_opt ~caps "HOME" with
  | Some value when String.trim value <> "" -> value
  | _ -> "."

let concat a b = Filename.concat a b

let legacy_retention_error =
  "INN_RETENTION_HOURS is no longer supported: use \
   INN_TRACES_RETENTION_HOURS, INN_LOGS_RETENTION_HOURS, and \
   INN_METRICS_RETENTION_HOURS instead"

let ( let* ) = Result.bind

let resolve ~caps ?(env = getenv ~caps) ?home () =
  let home = Option.value home ~default:(default_home ~caps ()) in
  let state_home =
    match clean_env env "XDG_STATE_HOME" with
    | Some path -> path
    | None -> concat (concat home ".local") "state"
  in
  let state_dir =
    match clean_env env "INN_STATE_DIR" with
    | Some path -> path
    | None -> concat state_home "inn"
  in
  let db_path =
    match clean_env env "INN_DB_PATH" with
    | Some path -> path
    | None -> concat state_dir "telemetry.sqlite"
  in
  let host = Option.value (clean_env env "INN_HOST") ~default:"127.0.0.1" in
  match clean_env env "INN_RETENTION_HOURS" with
  | Some _ -> Error legacy_retention_error
  | None ->
      let* port =
        positive_int_env env ~name:"INN_PORT" ~default:default_port
      in
      let* traces_retention_hours =
        positive_int_env env ~name:"INN_TRACES_RETENTION_HOURS"
          ~default:default_traces_retention_hours
      in
      let* logs_retention_hours =
        positive_int_env env ~name:"INN_LOGS_RETENTION_HOURS"
          ~default:default_logs_retention_hours
      in
      let* metrics_retention_hours =
        positive_int_env env ~name:"INN_METRICS_RETENTION_HOURS"
          ~default:default_metrics_retention_hours
      in
      let* prune_interval_seconds =
        positive_int_env env ~name:"INN_PRUNE_INTERVAL_SECONDS"
          ~default:default_prune_interval_seconds
      in
      let* max_db_size_mb =
        positive_int_env env ~name:"INN_MAX_DB_SIZE_MB"
          ~default:default_max_db_size_mb
      in
      let base_url =
        Option.value (clean_env env "INN_BASE_URL")
          ~default:(Printf.sprintf "http://%s:%d" host port)
      in
      Ok
        {
          state_dir;
          db_path;
          host;
          port;
          base_url;
          traces_retention_hours;
          logs_retention_hours;
          metrics_retention_hours;
          prune_interval_seconds;
          max_db_size_mb;
        }

let resolve_exn ~caps () =
  match resolve ~caps () with
  | Ok config -> config
  | Error message -> invalid_arg message
