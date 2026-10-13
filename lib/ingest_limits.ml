(* Ingest limits: one program cannot fill Inn with large values
   (bcache-t8nc). Each function returns the record unchanged when nothing is
   over a limit; otherwise it cuts the long values and adds the attribute
   [inn.truncated = true], so a reader can see that the record is cut. *)

let max_attribute_bytes = 1024
let max_text_bytes = 8192
let truncated_key = "inn.truncated"

(* Cut [text] to at most [limit] bytes without splitting a UTF-8 sequence:
   continuation bytes (10xxxxxx) before the cut are dropped with the cut. *)
let cut_utf8 limit text =
  if String.length text <= limit then text
  else
    let rec boundary index =
      if index <= 0 then 0
      else if Char.code text.[index] land 0xC0 = 0x80 then boundary (index - 1)
      else index
    in
    String.sub text 0 (boundary limit)

type 'a checked = { value : 'a; cut : bool }

let keep value = { value; cut = false }

let text limit value =
  if String.length value <= limit then keep value
  else { value = cut_utf8 limit value; cut = true }

let attribute_value (value : Yojson.Safe.t) =
  match value with
  | `String value ->
      let checked = text max_attribute_bytes value in
      { value = `String checked.value; cut = checked.cut }
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Null -> keep value
  | `List _ | `Assoc _ | `Tuple _ | `Variant _ ->
      let encoded = Yojson.Safe.to_string value in
      if String.length encoded <= max_attribute_bytes then keep value
      else { value = `String (cut_utf8 max_attribute_bytes encoded); cut = true }

let attributes (attrs : Model.attrs) =
  List.fold_right
    (fun (key, value) { value = attrs; cut } ->
      let checked = attribute_value value in
      { value = (key, checked.value) :: attrs; cut = cut || checked.cut })
    attrs (keep [])

let mark cut (attrs : Model.attrs) =
  if cut && not (List.mem_assoc truncated_key attrs) then
    attrs @ [ (truncated_key, `Bool true) ]
  else attrs

let span (span : Model.span) =
  let attrs = attributes span.attributes in
  let resource = attributes span.resource in
  let events =
    List.map
      (fun (event : Model.span_event) ->
        let checked = attributes event.attributes in
        { value = { event with attributes = checked.value }; cut = checked.cut })
      span.events
  in
  let links =
    List.map
      (fun (link : Model.span_link) ->
        let checked = attributes link.attributes in
        { value = { link with attributes = checked.value }; cut = checked.cut })
      span.links
  in
  let status_message =
    match span.status_message with
    | None -> keep None
    | Some message ->
        let checked = text max_text_bytes message in
        { value = Some checked.value; cut = checked.cut }
  in
  let cut =
    attrs.cut || resource.cut || status_message.cut
    || List.exists (fun checked -> checked.cut) events
    || List.exists (fun checked -> checked.cut) links
  in
  {
    span with
    attributes = mark cut attrs.value;
    resource = resource.value;
    events = List.map (fun checked -> checked.value) events;
    links = List.map (fun checked -> checked.value) links;
    status_message = status_message.value;
  }

let log (log : Model.log_record) =
  let attrs = attributes log.attributes in
  let resource = attributes log.resource in
  let body = text max_text_bytes log.body in
  let cut = attrs.cut || resource.cut || body.cut in
  {
    log with
    attributes = mark cut attrs.value;
    resource = resource.value;
    body = body.value;
  }

let metric_point (point : Model.metric_point) =
  let attrs = attributes point.attributes in
  let resource = attributes point.resource in
  let cut = attrs.cut || resource.cut in
  { point with attributes = mark cut attrs.value; resource = resource.value }
