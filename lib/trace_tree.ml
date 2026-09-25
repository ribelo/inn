let is_running_span (span : Model.span) =
  span.end_time_ns = 0 || span.end_time_ns < span.start_time_ns

(* Siblings and roots are read top to bottom: earliest start first, with the
   span id as a stable tie-breaker (tree-tflv). *)
let span_order (left : Model.span) (right : Model.span) =
  let by_start = compare left.start_time_ns right.start_time_ns in
  if by_start <> 0 then by_start else String.compare left.span_id right.span_id

type t = {
  nodes : Model.span_node list;
  root_operation_name : string;
  root_service_name : string;
  started_at_ns : int;
  ended_at_ns : int;
  duration_ms : float;
  span_count : int;
  error_count : int;
  is_running : bool;
  warnings : string list;
}

let empty =
  {
    nodes = [];
    root_operation_name = "";
    root_service_name = "";
    started_at_ns = 0;
    ended_at_ns = 0;
    duration_ms = 0.;
    span_count = 0;
    error_count = 0;
    is_running = false;
    warnings = [];
  }

let assemble spans =
  match spans with
  | [] -> empty
  | spans ->
      let by_id = Hashtbl.create (List.length spans) in
      List.iter
        (fun (span : Model.span) -> Hashtbl.replace by_id span.span_id span)
        spans;
      let missing_parent (span : Model.span) =
        match span.parent_span_id with
        | Some parent -> not (Hashtbl.mem by_id parent)
        | None -> false
      in
      let children = Hashtbl.create (List.length spans) in
      List.iter
        (fun (span : Model.span) ->
          match span.parent_span_id with
          | Some parent when Hashtbl.mem by_id parent ->
              let existing =
                Option.value (Hashtbl.find_opt children parent) ~default:[]
              in
              Hashtbl.replace children parent (span :: existing)
          | _ -> ())
        spans;
      let children_of span_id =
        Option.value (Hashtbl.find_opt children span_id) ~default:[]
        |> List.sort span_order
      in
      let roots =
        List.filter
          (fun (span : Model.span) ->
            match span.parent_span_id with
            | None -> true
            | Some parent -> not (Hashtbl.mem by_id parent))
          spans
        |> List.sort span_order
      in
      let visited = Hashtbl.create (List.length spans) in
      let rec walk ~depth ~root_operation ~warning (span : Model.span) =
        if Hashtbl.mem visited span.span_id then []
        else begin
          Hashtbl.replace visited span.span_id ();
          let warnings =
            if missing_parent span then
              [
                Printf.sprintf
                  "span %s references missing parent %s; treated as a root"
                  span.span_id
                  (Option.value span.parent_span_id ~default:"");
              ]
            else warning
          in
          let node =
            {
              Model.span;
              depth;
              parent_operation_name =
                Option.bind span.parent_span_id (fun parent ->
                    Option.map
                      (fun (parent_span : Model.span) -> parent_span.operation_name)
                      (Hashtbl.find_opt by_id parent));
              root_operation_name = root_operation;
              is_running = is_running_span span;
              warnings;
            }
          in
          node
          :: List.concat_map
               (walk ~depth:(depth + 1) ~root_operation ~warning:[])
               (children_of span.span_id)
        end
      in
      (* Spans hidden behind a parent cycle have no root to hang from. They are
         emitted after the rooted tree, once each, so a bad parent chain can
         never loop forever (tree-ffmn). *)
      let rec unvisited_roots acc =
        let remaining =
          List.filter (fun (span : Model.span) -> not (Hashtbl.mem visited span.span_id)) spans
        in
        match remaining with
        | [] -> List.rev acc
        | _ ->
            let entry = List.hd (List.sort span_order remaining) in
            let cycle_warning =
              Printf.sprintf
                "span %s is hidden behind a parent cycle; treated as a root"
                entry.span_id
            in
            let nodes =
              walk ~depth:0 ~root_operation:entry.operation_name
                ~warning:[ cycle_warning ] entry
            in
            unvisited_roots (List.rev_append nodes acc)
      in
      (* Sequential [let]s on purpose: OCaml evaluates the operands of [`@`] in
         an unspecified order, and the cycle pass must run after the roots have
         marked their spans visited. *)
      let rooted =
        List.concat_map
          (fun (root : Model.span) ->
            walk ~depth:0 ~root_operation:root.operation_name ~warning:[] root)
          roots
      in
      let hidden = unvisited_roots [] in
      let nodes = rooted @ hidden in
      let first_root = List.find_opt (fun (node : Model.span_node) -> node.depth = 0) nodes in
      let started_at_ns =
        List.fold_left
          (fun acc (span : Model.span) -> min acc span.start_time_ns)
          (List.hd spans).start_time_ns spans
      in
      let ended_at_ns =
        List.fold_left
          (fun acc (span : Model.span) ->
            let end_time =
              if is_running_span span then span.start_time_ns else span.end_time_ns
            in
            max acc end_time)
          started_at_ns spans
      in
      let warnings =
        List.concat_map (fun (node : Model.span_node) -> node.warnings) nodes
        @ (if List.length roots > 1 then
             [ Printf.sprintf "trace has %d roots" (List.length roots) ]
           else [])
      in
      {
        nodes;
        root_operation_name =
          (match first_root with
          | Some node -> node.span.operation_name
          | None -> "");
        root_service_name =
          (match first_root with Some node -> node.span.service_name | None -> "");
        started_at_ns;
        ended_at_ns;
        duration_ms = float_of_int (ended_at_ns - started_at_ns) /. 1_000_000.;
        span_count = List.length spans;
        error_count =
          List.fold_left
            (fun acc (span : Model.span) ->
              if span.status = Model.Error then acc + 1 else acc)
            0 spans;
        is_running = List.exists is_running_span spans;
        warnings;
      }
