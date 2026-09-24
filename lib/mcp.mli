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
(** [handle_request] has no I/O: tool execution is supplied by the caller.
    JSON-RPC notifications do not produce responses. *)

val handle_line :
  tool_call:(string -> Yojson.Safe.t -> (string, string) result) ->
  string ->
  Yojson.Safe.t option

val run :
  tool_call:(string -> Yojson.Safe.t -> (string, string) result) -> unit -> unit
