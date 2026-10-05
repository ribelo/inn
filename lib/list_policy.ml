(* Query window, limit, and cursor policy for Inn list and search endpoints.
   The HTTP layer resolves one request into a [request] value here; the store
   only ever sees a resolved window and a decoded cursor position.

   Stories: win-nzur, win-e7k8, win-m4ld, win-jee9, win-xl30, win-fl8w,
   win-7xet, win-xi3q. *)

type kind = Trace | Span | Log | Ai_call | Metric

let kind_to_string = function
  | Trace -> "trace"
  | Span -> "span"
  | Log -> "log"
  | Ai_call -> "ai_call"
  | Metric -> "metric"

let kind_of_string = function
  | "trace" -> Some Trace
  | "span" -> Some Span
  | "log" -> Some Log
  | "ai_call" -> Some Ai_call
  | "metric" -> Some Metric
  | _ -> None

let kind_label = function
  | Trace -> "trace"
  | Span -> "span"
  | Log -> "log"
  | Ai_call -> "AI call"
  | Metric -> "metric"

let lookback_grammar =
  "lookback must be a positive integer followed by m, h, or d (for example "
  ^ "15m, 2h, or 1d), or all"

let list_lookback = "1h"
let history_lookback = "all"
let default_list_limit = 100
let default_stats_limit = 20

type lookback = { label : string; ms : int option }

let all_lookback = { label = history_lookback; ms = None }

let is_digit code = code >= 48 && code <= 57

let is_digits text =
  text <> "" && String.for_all (fun char -> is_digit (Char.code char)) text

let parse_lookback text =
  let text = String.trim text in
  if String.equal text history_lookback then Ok all_lookback
  else
    let length = String.length text in
    if length < 2 then Error lookback_grammar
    else
      let digits = String.sub text 0 (length - 1) in
      let unit_ = String.sub text (length - 1) 1 in
      let multiplier =
        if String.equal unit_ "m" then Some 60_000
        else if String.equal unit_ "h" then Some 3_600_000
        else if String.equal unit_ "d" then Some 86_400_000
        else None
      in
      match (multiplier, is_digits digits, int_of_string_opt digits) with
      | Some multiplier, true, Some value when value > 0 ->
          if value > max_int / multiplier then
            Error "lookback is too large for the server clock"
          else Ok { label = text; ms = Some (value * multiplier) }
      | _ -> Error lookback_grammar

let parse_limit ?(default = default_list_limit) params =
  match List.assoc_opt "limit" params with
  | None -> Ok default
  | Some value -> (
      match int_of_string_opt (String.trim value) with
      | Some limit when limit > 0 && limit <= 10_000 -> Ok limit
      | _ -> Error "limit must be an integer between 1 and 10000")

let lookback_of_params ~default params =
  match List.assoc_opt "lookback" params with
  | None -> parse_lookback default
  | Some value -> parse_lookback value

let resolve ~now_ms (lookback : lookback) =
  match lookback.ms with
  | None -> Model.window_all
  | Some ms -> Model.window_lookback ~now_ms ~ms

(* The cursor is opaque: a base64url token over a small JSON payload. Decoding
   validates the shape, the endpoint kind, and the window carried by page one. *)

let base64url_alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

let base64url_encode text =
  let length = String.length text in
  let buffer = Buffer.create (((length + 2) / 3) * 4) in
  let byte index = Char.code text.[index] in
  let rec loop index =
    if index >= length then ()
    else begin
      let first = byte index in
      let second = if index + 1 < length then byte (index + 1) else 0 in
      let third = if index + 2 < length then byte (index + 2) else 0 in
      Buffer.add_char buffer base64url_alphabet.[first lsr 2];
      Buffer.add_char buffer
        base64url_alphabet.[((first land 0x03) lsl 4) lor (second lsr 4)];
      if index + 1 < length then
        Buffer.add_char buffer
          base64url_alphabet.[((second land 0x0F) lsl 2) lor (third lsr 6)];
      if index + 2 < length then
        Buffer.add_char buffer base64url_alphabet.[third land 0x3F];
      loop (index + 3)
    end
  in
  loop 0;
  Buffer.contents buffer

let base64url_value char =
  let code = Char.code char in
  if code >= 65 && code <= 90 then Some (code - 65)
  else if code >= 97 && code <= 122 then Some (code - 97 + 26)
  else if code >= 48 && code <= 57 then Some (code - 48 + 52)
  else if code = 45 then Some 62
  else if code = 95 then Some 63
  else None

let base64url_decode text =
  let length = String.length text in
  if length = 0 || length mod 4 = 1 then None
  else begin
    let buffer = Buffer.create ((length * 3) / 4) in
    let ok = ref true in
    let rec loop index =
      if index >= length then ()
      else begin
        let take = min 4 (length - index) in
        let values = Array.make take 0 in
        for offset = 0 to take - 1 do
          match base64url_value text.[index + offset] with
          | Some value -> values.(offset) <- value
          | None -> ok := false
        done;
        if !ok then begin
          Buffer.add_char buffer
            (Char.chr ((values.(0) lsl 2) lor (values.(1) lsr 4)));
          if take >= 3 then
            Buffer.add_char buffer
              (Char.chr (((values.(1) land 0x0F) lsl 4) lor (values.(2) lsr 2)));
          if take >= 4 then
            Buffer.add_char buffer
              (Char.chr (((values.(2) land 0x03) lsl 6) lor values.(3)))
        end;
        loop (index + 4)
      end
    in
    loop 0;
    if !ok then Some (Buffer.contents buffer) else None
  end

let malformed_cursor =
  "cursor is not a valid page cursor; pass the nextCursor value from a "
  ^ "previous response unchanged"

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let cursor_window_of_json json =
  match json_field "windowStartMs" json with
  | Some `Null -> Some Model.window_all
  | Some (`Int start_ms) -> Some { Model.start_ms = Some start_ms }
  | _ -> None

type cursor = {
  cursor_kind : kind;
  cursor_position : Model.cursor_position;
  cursor_window : Model.window;
  cursor_lookback : string;
}

let decode_cursor ~kind text =
  match base64url_decode text with
  | None -> Error malformed_cursor
  | Some raw -> (
      match Yojson.Safe.from_string raw with
      | exception Yojson.Json_error _ -> Error malformed_cursor
      | json -> (
          match
            ( json_field "kind" json,
              json_field "sortKeyNs" json,
              json_field "id" json,
              cursor_window_of_json json,
              json_field "lookback" json )
          with
          | Some (`String cursor_kind), Some (`Int sort_key_ns),
            Some (`String tie_breaker), Some cursor_window,
            Some (`String cursor_lookback) -> (
              match kind_of_string cursor_kind with
              | None -> Error malformed_cursor
              | Some decoded when decoded <> kind ->
                  Error
                    (Printf.sprintf "cursor is for %s results, not %s results"
                       (kind_label decoded) (kind_label kind))
              | Some decoded ->
                  Ok
                    {
                      cursor_kind = decoded;
                      cursor_position = { Model.sort_key_ns; tie_breaker };
                      cursor_window;
                      cursor_lookback;
                    })
          | _ -> Error malformed_cursor))

let encode_cursor ~kind ~window ~lookback position =
  let json =
    `Assoc
      [
        ("kind", `String (kind_to_string kind));
        ("sortKeyNs", `Int position.Model.sort_key_ns);
        ("id", `String position.Model.tie_breaker);
        ( "windowStartMs",
          match window.Model.start_ms with
          | None -> `Null
          | Some ms -> `Int ms );
        ("lookback", `String lookback);
      ]
  in
  base64url_encode (Yojson.Safe.to_string json)

type request = {
  kind : kind option;
  window : Model.window;
  lookback : string;
  limit : int;
  cursor : Model.cursor_position option;
}

let list_request ?(default_limit = default_list_limit)
    ?(default_lookback = list_lookback) ~kind ~now_ms params =
  match parse_limit ~default:default_limit params with
  | Error message -> Error message
  | Ok limit -> (
      match lookback_of_params ~default:default_lookback params with
      | Error message -> Error message
      | Ok requested -> (
          match List.assoc_opt "cursor" params with
          | None ->
              Ok
                {
                  kind = Some kind;
                  window = resolve ~now_ms requested;
                  lookback = requested.label;
                  limit;
                  cursor = None;
                }
          | Some token -> (
              match decode_cursor ~kind token with
              | Error message -> Error message
              | Ok cursor ->
                  Ok
                    {
                      kind = Some kind;
                      window = cursor.cursor_window;
                      lookback = cursor.cursor_lookback;
                      limit;
                      cursor = Some cursor.cursor_position;
                    })))

let summary_request ?(default_limit = default_stats_limit)
    ?(default_lookback = history_lookback) ~now_ms params =
  match parse_limit ~default:default_limit params with
  | Error message -> Error message
  | Ok limit -> (
      match lookback_of_params ~default:default_lookback params with
      | Error message -> Error message
      | Ok requested ->
          Ok
            {
              kind = None;
              window = resolve ~now_ms requested;
              lookback = requested.label;
              limit;
              cursor = None;
            })

let resolve_lookback ?(default = history_lookback) ~now_ms params =
  match lookback_of_params ~default params with
  | Error message -> Error message
  | Ok requested -> Ok (resolve ~now_ms requested, requested.label)

let meta_json request ~returned ~truncated ~next =
  let next_cursor =
    match (request.kind, next) with
    | Some kind, Some position ->
        [
          ( "nextCursor",
            `String
              (encode_cursor ~kind ~window:request.window
                 ~lookback:request.lookback position) );
        ]
    | _ -> []
  in
  `Assoc
    ([
       ("limit", `Int request.limit);
       ("lookback", `String request.lookback);
       ("returned", `Int returned);
       ("truncated", `Bool truncated);
     ]
    @ next_cursor)

let stats_meta ~lookback ~limit =
  `Assoc [ ("lookback", `String lookback); ("limit", `Int limit) ]

let services_meta ~lookback ~returned =
  `Assoc [ ("lookback", `String lookback); ("returned", `Int returned) ]

let store_stats_meta ~lookback = `Assoc [ ("lookback", `String lookback) ]
