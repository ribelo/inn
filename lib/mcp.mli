(** Standard MCP stdio transport and read-only HTTP tool catalogue. *)

val tool_call :
  request:(string -> (int * string, string) result) ->
  status:(unit -> Yojson.Safe.t) ->
  base_url:string ->
  string ->
  Yojson.Safe.t ->
  (string, string) result

val handle_request :
  tool_call:(string -> Yojson.Safe.t -> (string, string) result) ->
  Yojson.Safe.t ->
  Yojson.Safe.t option
(** [handle_request] performs no I/O of its own: [tool_call] is supplied by the caller.
    JSON-RPC notifications do not produce responses. *)

val handle_line :
  tool_call:(string -> Yojson.Safe.t -> (string, string) result) ->
  string ->
  Yojson.Safe.t option

val run :
  caps:< Ox_caps.Cap.stdin ; Ox_caps.Cap.stdout ; .. > ->
  tool_call:(string -> Yojson.Safe.t -> (string, string) result) ->
  unit ->
  unit
(** Reads one request per stdin line and writes one flushed stdout line.
    ^inncap-q8hn ^innlint-b7km

    Suspension: may suspend in the caller-supplied [tool_call] callback; JSON
    parsing and printing are delegated to [Yojson.Safe.from_string] and
    [Yojson.Safe.to_string], while Stdlib [input_line], [flush] and
    [Ox_caps.Cap_stdlib.print_endline] use blocking channel I/O rather than
    Eio suspension.
    Cancellation: depends on [tool_call] and the delegated JSON parsing and
    printing in [Yojson.Safe.from_string] and [Yojson.Safe.to_string], whose
    exceptions propagate except for handled [Yojson.Json_error] parse failures;
    the stdin and stdout loop adds no Eio cancellation check.
    Finalizers: no release hook is registered and stdin and stdout are not closed.
    Locking: no Inn lock spans [tool_call]; Stdlib owns channel synchronisation.
    Cancellation safety: unsafe because progress is lost if [tool_call] cancels;
    the current stdin line has been consumed and callback effects are not undone.

    @raise Sys_error on failure of Stdlib [input_line] or [flush], or
    [Ox_caps.Cap_stdlib.print_endline]. *)
