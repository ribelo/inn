(** Endpoint declarations for the Inn HTTP API.

    One declaration per endpoint carries the method, the path, the parameters
    (name, kind, default, allowed values, description), the request body, and
    the response schemas. The HTTP router, the [/endpoints] inventory, and the
    OpenAPI 3.1 document are rendered from this list, and the query parser
    validates every request against it, so the documentation cannot drift from
    behavior (desc-iduq, desc-de6o). *)

type method_ = Get | Post

val method_to_string : method_ -> string
val method_to_lowercase : method_ -> string

type location = Query | Path

type kind = String | Integer | Number

val kind_to_string : kind -> string

type param = {
  name : string;
  location : location;
  kind : kind;
  default : string option;
  allowed : string list;
  required : bool;
  minimum : float option;
  maximum : float option;
  dynamic : bool;
  description : string;
}
(** [dynamic] marks a prefix such as [attr.<key>]: every query key with that
    prefix is accepted. [allowed] is the documented value set; an empty list
    means free text. *)

type response = {
  status : int;
  description : string;
  content_type : string;
  schema : Yojson.Safe.t;
}
(** [schema] is a JSON Schema fragment for the response body. *)

type t = {
  id : string;
  method_ : method_;
  path : string;
  summary : string;
  description : string;
  group : string;
  params : param list;
  responses : response list;
  request_body : string option;
}

val all : t list
(** Every endpoint the server serves, in declaration order. *)

val alias_prefix : string

val alias_path : t -> string
(** The [/api]-prefixed alias of a declared path. *)

val alias_description : string

val query_params : t -> param list
(** The declared query parameters, dynamic prefixes included. *)

val validate_query : t -> (string * string) list -> (unit, string) result
(** Reject a query string that names a parameter the declaration does not
    carry, omits a required one, or gives a wrongly typed value. *)

val inventory_json : t -> Yojson.Safe.t
(** One [/endpoints] entry: method, path, alias, filters, parameters,
    responses. *)

val document : base_url:string -> t list -> Yojson.Safe.t
(** The OpenAPI 3.1 document for the declarations, including the [/api]
    alias paths. *)

(** {1 Allowed-value catalog}

    The declarations and the request handlers share these lists, so a value set
    can never be documented without being enforced, or enforced without being
    documented. *)

val trace_agg : string list
val log_agg : string list
val log_group_by : string list
val severity_levels : string list
val facet_types : string list
val service_signals : string list
val span_statuses : string list

val allowed_values : string -> string list -> string
(** ["name must be one of a, b, c"], the shared error wording. *)
