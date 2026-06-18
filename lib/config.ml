type t = {
  state_dir : string;
  db_path : string;
  host : string;
  port : int;
  base_url : string;
  retention_hours : int;
  max_db_size_mb : int;
}

let default_port = 27687

let getenv key =
  match Sys.getenv_opt key with
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

let default_home () =
  match Sys.getenv_opt "HOME" with
  | Some value when String.trim value <> "" -> value
  | _ -> "."

let concat a b = Filename.concat a b

let resolve ?(env = getenv) ?home () =
  let home = Option.value home ~default:(default_home ()) in
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
  let port_value =
    Option.value (clean_env env "INN_PORT") ~default:(string_of_int default_port)
  in
  let base_url_from_port port =
    Printf.sprintf "http://%s:%d" host port
  in
  match parse_positive_int ~name:"INN_PORT" port_value with
  | Error _ as error -> error
  | Ok port -> (
      let base_url =
        Option.value (clean_env env "INN_BASE_URL") ~default:(base_url_from_port port)
      in
      let retention_value =
        Option.value (clean_env env "INN_RETENTION_HOURS") ~default:"168"
      in
      match parse_positive_int ~name:"INN_RETENTION_HOURS" retention_value with
      | Error _ as error -> error
      | Ok retention_hours -> (
          let max_db_value =
            Option.value (clean_env env "INN_MAX_DB_SIZE_MB") ~default:"1024"
          in
          match parse_positive_int ~name:"INN_MAX_DB_SIZE_MB" max_db_value with
          | Error _ as error -> error
          | Ok max_db_size_mb ->
              Ok
                {
                  state_dir;
                  db_path;
                  host;
                  port;
                  base_url;
                  retention_hours;
                  max_db_size_mb;
                }))

let resolve_exn () =
  match resolve () with
  | Ok config -> config
  | Error message -> invalid_arg message
