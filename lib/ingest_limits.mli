(** Ingest limits applied before Inn stores a record (bcache-t8nc).

    A string attribute value longer than [max_attribute_bytes] is cut to that
    length; a list or object attribute whose JSON is longer becomes the cut JSON
    text. A log body or a span status message longer than [max_text_bytes] is
    cut to that length. Cuts never split a UTF-8 sequence. A record with any cut
    gets the attribute [inn.truncated = true]. A record within the limits is
    returned unchanged. *)

val max_attribute_bytes : int
val max_text_bytes : int
val truncated_key : string
val span : Model.span -> Model.span
val log : Model.log_record -> Model.log_record
val metric_point : Model.metric_point -> Model.metric_point
