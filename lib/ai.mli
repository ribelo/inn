(** AI call classification and extraction.

    One pure module decides what is an AI call, a tool execution, or a nested
    provider span, and turns a classified span into a typed summary and detail
    (aic-cw6h, aic-jupv, aic-qs41, aic-q5qt, aic-fy0u). It understands the
    OpenTelemetry GenAI semantic conventions first and the Vercel AI SDK keys
    second; the precedence table is documented in the README. *)

type classification = Ai_call | Tool_execution | Nested_provider | Not_ai
(** What a span is, not just whether it carries an [ai.] attribute
    (aic-cw6h). *)

val classification_to_string : classification -> string
(** [call], [tool], [nested], or [none]. *)

val classification_of_string : string -> classification

val classify_spans : Model.span list -> (Model.span * classification) list
(** Classify a trace's spans together, in input order: a Vercel provider span
    ([ai.*.do*]) is nested only when its parent in [spans] is an AI call
    (aic-jupv). *)

val is_ai_span : Model.span -> bool
(** A single span that is an AI call on its own evidence; a nested provider span
    still counts, since only its parent decides that classification, and a tool
    execution never does. *)

val tool_spans : children:Model.span list -> Model.span list
val call_of_span : children:Model.span list -> Model.span -> Model.ai_call
(** The denormalized summary (aic-q5qt, aic-khv). *)
val detail_of_span : children:Model.span list -> Model.span -> Model.ai_call_detail
val search_text : children:Model.span list -> Model.span -> string
(** Prompt, response, and tool content, for the case-insensitive substring
    filter (aic-gywl). *)
