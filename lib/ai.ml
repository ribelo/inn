(* AI call classification and extraction.

   Classification and extraction are pure: the span (plus, for tool calls, its
   child spans) is the only input. Ingest stores what comes out of here; the
   HTTP layer never re-derives it from raw attributes. *)

type classification = Ai_call | Tool_execution | Nested_provider | Not_ai

let classification_to_string = function
  | Ai_call -> "call"
  | Tool_execution -> "tool"
  | Nested_provider -> "nested"
  | Not_ai -> "none"

let classification_of_string = function
  | "call" -> Ai_call
  | "tool" -> Tool_execution
  | "nested" -> Nested_provider
  | _ -> Not_ai

(* Attribute access ------------------------------------------------------ *)

let all_attrs (span : Model.span) = span.resource @ span.attributes

let attr_value keys (span : Model.span) =
  let attrs = all_attrs span in
  List.find_map
    (fun key -> Option.map Model.attr_string_value (List.assoc_opt key attrs))
    keys

let event_value keys (span : Model.span) =
  List.find_map
    (fun (event : Model.span_event) ->
      List.find_map
        (fun key ->
          Option.map Model.attr_string_value (List.assoc_opt key event.attributes))
        keys)
    span.events

let int_of_string_opt_trimmed text =
  let text = String.trim text in
  let text =
    match String.index_opt text '.' with
    | Some index -> String.sub text 0 index
    | None -> text
  in
  int_of_string_opt text

let int_of_json = function
  | `Int value -> Some value
  | `Intlit text -> int_of_string_opt_trimmed text
  | `String text -> int_of_string_opt_trimmed text
  | `Float value when Float.is_integer value -> Some (int_of_float value)
  | _ -> None

let float_of_json = function
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit text | `String text -> float_of_string_opt (String.trim text)
  | _ -> None

let int_attr keys span =
  Option.bind (attr_value keys span) int_of_string_opt_trimmed

let float_attr keys span = Option.bind (attr_value keys span) float_of_string_opt

let lowercase = String.lowercase_ascii

let contains ~needle haystack =
  let haystack = lowercase haystack in
  let needle = lowercase needle in
  let length = String.length haystack and needle_length = String.length needle in
  let rec loop index =
    if needle_length = 0 then true
    else if index + needle_length > length then false
    else if String.equal (String.sub haystack index needle_length) needle then true
    else loop (index + 1)
  in
  loop 0

(* Classification -------------------------------------------------------- *)

let has_ai_attribute (span : Model.span) =
  List.exists
    (fun (key, _) ->
      String.starts_with ~prefix:"ai." key
      || String.starts_with ~prefix:"gen_ai." key)
    (all_attrs span)

(* Vercel AI SDK operations that are not provider sub-spans. The SDK names the
   top-level span after the call and nests provider work under "<op>.do<X>". *)
let vercel_top_level_operations =
  [ "generateText"; "streamText"; "generateObject"; "streamObject";
    "embedMany"; "embed"; "generateImage"; "transcribe"; "rerank" ]

let has_vercel_operation_name (span : Model.span) =
  List.exists (fun needle -> contains ~needle span.operation_name)
    vercel_top_level_operations

let operation_attribute (span : Model.span) =
  attr_value [ "gen_ai.operation.name"; "ai.operationId" ] span

let is_tool_execution (span : Model.span) =
  let is_execute_tool value =
    String.equal (lowercase (String.trim value)) "execute_tool"
    || String.equal (lowercase (String.trim value)) "ai.toolcall"
  in
  match operation_attribute span with
  | Some value when is_execute_tool value -> true
  | _ -> contains ~needle:"ai.toolcall" span.operation_name

let operation_id (span : Model.span) =
  Option.value (attr_value [ "ai.operationId" ] span) ~default:span.operation_name

(* A Vercel provider span: "ai.generateText.doGenerate", "ai.streamText.doStream",
   "ai.embed.doEmbed". *)
let is_nested_provider (span : Model.span) =
  let id = operation_id span in
  String.starts_with ~prefix:"ai." id && contains ~needle:".do" id

let base_class (span : Model.span) =
  if is_tool_execution span then Tool_execution
  else if has_ai_attribute span || has_vercel_operation_name span then Ai_call
  else Not_ai

let classify_spans spans =
  let base_by_id = Hashtbl.create (List.length spans) in
  let base = List.map (fun span -> (span, base_class span)) spans in
  List.iter
    (fun ((span : Model.span), kind) -> Hashtbl.replace base_by_id span.span_id kind)
    base;
  List.map
    (fun ((span : Model.span), kind) ->
      match kind with
      | Ai_call when is_nested_provider span -> (
          match span.parent_span_id with
          | Some parent -> (
              match Hashtbl.find_opt base_by_id parent with
              | Some Ai_call -> (span, Nested_provider)
              | _ -> (span, Ai_call))
          | None -> (span, Ai_call))
      | _ -> (span, kind))
    base

(* A single span that is an AI call from its own evidence. A nested provider
   span is still a call here: only the parent decides that classification. *)
let is_ai_span (span : Model.span) = base_class span = Ai_call

(* Extraction ------------------------------------------------------------ *)

let tool_spans ~children =
  List.filter (fun child -> base_class child = Tool_execution) children

let prompt_keys =
  [ "gen_ai.input.messages"; "gen_ai.prompt"; "ai.prompt.messages"; "ai.prompt" ]

let response_keys =
  [ "gen_ai.output.messages"; "gen_ai.completion"; "ai.response.text";
    "ai.response.messages"; "ai.response" ]

(* Content is an attribute when the instrumentation emits it directly and a
   span event when it follows the GenAI event conventions. *)
let prompt_value span =
  match attr_value prompt_keys span with
  | Some _ as value -> value
  | None -> event_value [ "gen_ai.content.prompt"; "gen_ai.prompt" ] span

let response_value span =
  match attr_value response_keys span with
  | Some _ as value -> value
  | None ->
      event_value [ "gen_ai.content.completion"; "gen_ai.completion" ] span

let operation span =
  Option.value (operation_attribute span) ~default:span.operation_name

let provider span =
  attr_value
    [ "gen_ai.provider.name"; "gen_ai.system"; "ai.model.provider"; "ai.provider" ]
    span

let model span =
  attr_value
    [ "gen_ai.request.model"; "gen_ai.response.model"; "ai.model.id"; "ai.model" ]
    span

let session_id span =
  attr_value
    [ "ai.telemetry.metadata.sessionId"; "gen_ai.session.id"; "ai.session.id";
      "session.id" ]
    span

let function_id span =
  attr_value
    [ "ai.telemetry.functionId"; "gen_ai.function.id"; "ai.function.id";
      "function.id" ]
    span

let user_id span =
  attr_value
    [ "gen_ai.user.id"; "ai.telemetry.metadata.userId"; "ai.user.id"; "user.id" ]
    span

let finish_reason span =
  attr_value [ "gen_ai.response.finish_reasons"; "ai.response.finishReason" ] span

let input_tokens span =
  int_attr
    [ "gen_ai.usage.input_tokens"; "ai.usage.inputTokens";
      "ai.usage.promptTokens"; "gen_ai.usage.prompt_tokens" ]
    span

let output_tokens span =
  int_attr
    [ "gen_ai.usage.output_tokens"; "ai.usage.outputTokens";
      "ai.usage.completionTokens"; "gen_ai.usage.completion_tokens" ]
    span

let total_tokens span =
  match int_attr [ "gen_ai.usage.total_tokens"; "ai.usage.totalTokens" ] span with
  | Some _ as explicit -> explicit
  | None -> (
      match (input_tokens span, output_tokens span) with
      | None, None -> None
      | input, output ->
          Some
            (Option.value input ~default:0 + Option.value output ~default:0))

let cached_input_tokens span =
  int_attr
    [ "gen_ai.usage.cached_input_tokens"; "ai.usage.cachedInputTokens";
      "gen_ai.usage.cache_read.input_tokens" ]
    span

let reasoning_tokens span =
  int_attr [ "gen_ai.usage.reasoning_tokens"; "ai.usage.reasoningTokens" ] span

let usage span =
  {
    Model.input_tokens = input_tokens span;
    output_tokens = output_tokens span;
    total_tokens = total_tokens span;
    cached_input_tokens = cached_input_tokens span;
    reasoning_tokens = reasoning_tokens span;
  }

let status_string (span : Model.span) = Model.span_status_to_string span.status

(* JSON-string content is parsed when valid and kept raw otherwise. *)
let json_of_string text =
  match Yojson.Safe.from_string text with
  | json -> Some json
  | exception Yojson.Json_error _ -> None

let rec text_of_json = function
  | `String value -> Some value
  | `List items ->
      let parts = List.filter_map text_of_json items in
      if parts = [] then None else Some (String.concat "\n" parts)
  | `Assoc fields ->
      List.find_map
        (fun key ->
          match List.assoc_opt key fields with
          | Some value -> text_of_json value
          | None -> None)
        [ "text"; "content"; "output_text"; "body"; "parts"; "messages";
          "value"; "output" ]
  | _ -> None

let text_of_value = function
  | None -> None
  | Some value -> (
      match json_of_string value with
      | Some json -> (
          match text_of_json json with
          | Some text -> Some text
          | None -> Some value)
      | None -> Some value)

let preview ?(limit = 200) = function
  | None -> None
  | Some text ->
      if String.length text <= limit then Some text
      else Some (String.sub text 0 limit)

let messages_of_value = function
  | None -> ([], None)
  | Some value -> (
      match json_of_string value with
      | Some (`List items) -> (items, Some value)
      | Some json -> ([ json ], Some value)
      | None -> ([], Some value))

let tool_call_name (span : Model.span) =
  Option.value
    (attr_value [ "gen_ai.tool.name"; "ai.toolCall.name" ] span)
    ~default:span.operation_name

let tool_call_from_span span =
  {
    Model.tool_name = tool_call_name span;
    tool_span_id = Some span.Model.span_id;
    tool_status = status_string span;
    tool_duration_ms =
      (if Model.span_is_running span then None else Some span.Model.duration_ms);
    tool_arguments =
      attr_value [ "gen_ai.tool.call.arguments"; "ai.toolCall.args" ] span;
    tool_result =
      attr_value [ "gen_ai.tool.call.result"; "ai.toolCall.result" ] span;
  }

(* Vercel records the tool calls the model asked for on the call span itself
   (ai.response.toolCalls) when no tool-execution span was exported. *)
let tool_calls_from_response span =
  let member key json =
    match json with
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some value -> text_of_json value
        | None -> None)
    | _ -> None
  in
  List.map
    (fun json ->
      {
        Model.tool_name =
          Option.value (member "toolName" json)
            ~default:(Option.value (member "name" json) ~default:"tool");
        tool_span_id = None;
        tool_status = "ok";
        tool_duration_ms = None;
        tool_arguments = member "input" json;
        tool_result = None;
      })
    (match attr_value [ "ai.response.toolCalls" ] span with
    | None -> []
    | Some value -> (
        match json_of_string value with
        | Some (`List items) -> items
        | _ -> []))

let tool_calls ~children span =
  match tool_spans ~children with
  | [] -> tool_calls_from_response span
  | spans -> List.map tool_call_from_span spans

let json_list_of_value = function
  | None -> []
  | Some value -> (
      match json_of_string value with
      | Some (`List items) -> items
      | Some json -> [ json ]
      | None -> [])

let tools span =
  json_list_of_value (attr_value [ "ai.prompt.tools"; "gen_ai.tool.definitions" ] span)

let provider_metadata span =
  match attr_value [ "ai.response.providerMetadata" ] span with
  | None -> None
  | Some value -> json_of_string value

let time_to_first_chunk_ms span =
  match attr_value [ "gen_ai.response.time_to_first_chunk" ] span with
  | Some value ->
      Option.map
        (fun seconds -> seconds *. 1000.)
        (float_of_string_opt (String.trim value))
  | None -> float_attr [ "ai.response.msToFirstChunk" ] span

let time_to_finish_ms span duration_ms =
  match float_attr [ "ai.response.msToFinish" ] span with
  | Some value -> Some value
  | None -> (
      match duration_ms with
      | None -> None
      | Some duration -> (
          match time_to_first_chunk_ms span with
          | Some first_chunk -> Some (max 0. (duration -. first_chunk))
          | None -> Some duration))

let timing ~duration_ms ~output_tokens span =
  let first_chunk = time_to_first_chunk_ms span in
  let finish = time_to_finish_ms span duration_ms in
  let rate =
    match float_attr [ "ai.response.avgOutputTokensPerSecond" ] span with
    | Some value -> Some value
    | None -> (
        match (finish, output_tokens) with
        | Some finish_ms, Some tokens when finish_ms > 0. ->
            Some (float_of_int tokens /. (finish_ms /. 1000.))
        | _ -> None)
  in
  {
    Model.time_to_first_chunk_ms = first_chunk;
    time_to_finish_ms = finish;
    output_tokens_per_second = rate;
  }

let search_text ~children span =
  let tool_content =
    tool_spans ~children
    |> List.concat_map (fun (tool : Model.span) ->
           [
             tool_call_name tool;
             Option.value
               (attr_value [ "gen_ai.tool.call.arguments"; "ai.toolCall.args" ] tool)
               ~default:"";
             Option.value
               (attr_value [ "gen_ai.tool.call.result"; "ai.toolCall.result" ] tool)
               ~default:"";
           ])
  in
  let content =
    [
      Option.value (prompt_value span) ~default:"";
      Option.value (response_value span) ~default:"";
      Option.value
        (event_value [ "gen_ai.content.prompt"; "gen_ai.prompt" ] span)
        ~default:"";
      Option.value
        (event_value [ "gen_ai.content.completion"; "gen_ai.completion" ] span)
        ~default:"";
      Option.value (attr_value [ "ai.response.toolCalls" ] span) ~default:"";
    ]
    @ tool_content
  in
  String.concat "\n"
    (List.filter (fun text -> not (String.equal text "")) content)

let call_of_span ~children (span : Model.span) =
  let prompt = prompt_value span in
  let response = response_value span in
  let calls = tool_calls ~children span in
  {
    Model.span_id = span.span_id;
    trace_id = span.trace_id;
    service_name = span.service_name;
    operation = operation span;
    provider = provider span;
    model = model span;
    status = status_string span;
    start_time_ns = span.start_time_ns;
    duration_ms =
      (if Model.span_is_running span then None else Some span.Model.duration_ms);
    is_running = Model.span_is_running span;
    finish_reason = finish_reason span;
    session_id = session_id span;
    function_id = function_id span;
    user_id = user_id span;
    tool_call_count = List.length calls;
    usage = usage span;
    prompt_preview = preview (text_of_value prompt);
    response_preview = preview (text_of_value response);
  }

let detail_of_span ~children (span : Model.span) =
  let call = call_of_span ~children span in
  let prompt = prompt_value span in
  let response = response_value span in
  let messages, raw = messages_of_value prompt in
  {
    Model.call;
    prompt = { Model.messages; raw };
    response_text = text_of_value response;
    response_raw = response;
    tool_calls = tool_calls ~children span;
    tools = tools span;
    provider_metadata = provider_metadata span;
    timing =
      timing ~duration_ms:call.duration_ms
        ~output_tokens:(usage span).Model.output_tokens span;
  }