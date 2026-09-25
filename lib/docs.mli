(** The embedded agent guides served by [GET /docs] and [GET /docs/{name}].

    The Markdown sources live in [docs/guides] and are compiled into the binary,
    so the service serves them without reading a checkout path at run time. *)

type guide = {
  name : string;
  title : string;
  path : string;
  content : string;
}

val guides : guide list
val find : string -> guide option
val names : string list
(** The available guide names, in catalog order, for a 404 that lists them. *)

val index_json : unit -> Yojson.Safe.t
(** The [GET /docs] body: every guide's name, title, and path. *)
