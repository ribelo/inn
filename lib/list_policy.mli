(** Query window, limit, and cursor policy for Inn list and search endpoints.

    One module owns the [lookback] grammar, the [limit] range, and the opaque
    keyset cursor, so the HTTP, CLI, and MCP surfaces agree on all three. The
    store never parses a parameter: it receives a resolved window and a
    decoded cursor position. *)

type kind = Trace | Span | Log | Metric
(** The row family a cursor belongs to. A cursor issued for another family is
    rejected with an error. *)

val kind_to_string : kind -> string
val kind_of_string : string -> kind option
val kind_label : kind -> string

val list_lookback : string
(** The default window for list and search queries: [1h] (win-e7k8). *)

val history_lookback : string
(** The default window for stats, facets, services, and store stats: [all]
    (win-jee9, win-3ghy). *)

val default_list_limit : int
val default_stats_limit : int
val lookback_grammar : string
(** The error text for an invalid lookback. *)

type lookback = { label : string; ms : int option }

val parse_lookback : string -> (lookback, string) result
(** Grammar: a positive integer followed by [m], [h], or [d] (for example
    [15m], [2h], [1d]), or the literal [all] (win-nzur, win-m4ld). *)

val parse_limit : ?default:int -> (string * string) list -> (int, string) result
(** The limit range stays 1..10000. *)

val resolve : now_ms:int -> lookback -> Model.window
(** Resolve a lookback once per request against the server clock. *)

type cursor = {
  cursor_kind : kind;
  cursor_position : Model.cursor_position;
  cursor_window : Model.window;
  cursor_lookback : string;
}

val encode_cursor :
  kind:kind ->
  window:Model.window ->
  lookback:string ->
  Model.cursor_position ->
  string

val decode_cursor : kind:kind -> string -> (cursor, string) result
(** Decoding validates the token shape and the endpoint kind (win-xl30). *)

type request = {
  kind : kind option;
  window : Model.window;
  lookback : string;
  limit : int;
  cursor : Model.cursor_position option;
}

val list_request :
  ?default_limit:int ->
  ?default_lookback:string ->
  kind:kind ->
  now_ms:int ->
  (string * string) list ->
  (request, string) result
(** List and search policy. [lookback] defaults to [1h]; a cursor resumes the
    window resolved for page one. *)

val summary_request :
  ?default_limit:int ->
  ?default_lookback:string ->
  now_ms:int ->
  (string * string) list ->
  (request, string) result
(** Stats and facet policy. [lookback] defaults to [all] and no cursor is
    accepted. *)

val resolve_lookback :
  ?default:string ->
  now_ms:int ->
  (string * string) list ->
  (Model.window * string, string) result
(** The services and store-stats policy: a window and its label. *)

val meta_json :
  request ->
  returned:int ->
  truncated:bool ->
  next:Model.cursor_position option ->
  Yojson.Safe.t
(** The list and search [meta] object. [nextCursor] is present only when
    another page exists (win-fl8w, win-7xet). *)

val stats_meta : lookback:string -> limit:int -> Yojson.Safe.t
val services_meta : lookback:string -> returned:int -> Yojson.Safe.t
val store_stats_meta : lookback:string -> Yojson.Safe.t
