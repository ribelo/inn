type t = {
  state_dir : string;
  data_dir : string;
  host : string;
  port : int;
  base_url : string;
  max_db_size_mb : int;
}

let default_port = 27687
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

(* Inn keeps the newest INN_MAX_DB_SIZE_MB of telemetry and nothing else
   decides what it keeps. A removed setting is refused rather than ignored, so
   a stale unit or shell profile is noticed (bcache-c4p7). *)
let removed_settings =
  [
    "INN_DB_PATH";
    "INN_RETENTION_HOURS";
    "INN_TRACES_RETENTION_HOURS";
    "INN_LOGS_RETENTION_HOURS";
    "INN_METRICS_RETENTION_HOURS";
    "INN_PRUNE_INTERVAL_SECONDS";
  ]

let removed_setting_error name =
  Printf.sprintf
    "%s is no longer supported: Inn keeps the newest INN_MAX_DB_SIZE_MB of \
     telemetry in INN_STATE_DIR/segments and has no other retention or path \
     setting"
    name

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
  let host = Option.value (clean_env env "INN_HOST") ~default:"127.0.0.1" in
  match List.find_opt (fun name -> Option.is_some (clean_env env name)) removed_settings with
  | Some name -> Error (removed_setting_error name)
  | None ->
      let* port =
        positive_int_env env ~name:"INN_PORT" ~default:default_port
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
          data_dir = concat state_dir "segments";
          host;
          port;
          base_url;
          max_db_size_mb;
        }

let resolve_exn ~caps () =
  match resolve ~caps () with
  | Ok config -> config
  | Error message -> invalid_arg message
