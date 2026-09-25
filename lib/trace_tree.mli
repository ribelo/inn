(** Depth-first trace tree assembly.

    One pure module turns a trace's spans into the single order and annotation
    set that the trace detail, the trace spans list, and the span detail all
    share: depth-first from the roots, siblings by start time. Missing parents
    and parent cycles are reported as warnings instead of synthetic spans, and
    unfinished spans are marked running. *)

type t = {
  nodes : Model.span_node list;  (** depth-first, siblings by start time *)
  root_operation_name : string;
  root_service_name : string;
  started_at_ns : int;
  ended_at_ns : int;
  duration_ms : float;
  span_count : int;
  error_count : int;
  is_running : bool;
  warnings : string list;  (** trace-level; the same text as the span warnings *)
}

val is_running_span : Model.span -> bool
(** A span with no end time (zero) or an end before its start has not finished
    (tree-78hm). *)

val assemble : Model.span list -> t
(** [assemble spans] orders and annotates every span exactly once. A span whose
    parent id is not among [spans] is treated as a root at depth 0 and carries a
    warning (tree-ffmn); a trace with more than one root carries a warning
    (tree-ap92); a parent cycle terminates and the spans it hides are emitted
    with a warning. *)
