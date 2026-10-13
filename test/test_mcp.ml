open Inn

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let required name json =
  match member name json with
  | Some value -> value
  | None -> Alcotest.fail ("missing " ^ name)

let response = function
  | Some json -> json
  | None -> Alcotest.fail "expected a JSON-RPC response"

let unavailable _ _ = Error "server unavailable"
let handle = Mcp.handle_request ~tool_call:unavailable

let request ?(params = `Assoc []) ?(id = `Int 1) method_ =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", id);
      ("method", `String method_);
      ("params", params);
    ]

let test_versions () =
  (* mcp-592g, mcp-zxs5: supported versions echo; unknown selects latest. *)
  List.iter
    (fun (asked, expected) ->
      let json =
        response
          (handle
             (request
                ~params:(`Assoc [ ("protocolVersion", `String asked) ])
                "initialize"))
      in
      let result = required "result" json in
      Alcotest.(check string)
        "negotiated version" expected
        (match required "protocolVersion" result with
        | `String value -> value
        | _ -> Alcotest.fail "protocolVersion is not a string");
      Alcotest.(check (testable Yojson.Safe.pretty_print Yojson.Safe.equal))
        "real build version" (`String Version.value)
        (required "version" (required "serverInfo" result)))
    [
      ("2025-11-25", "2025-11-25");
      ("2025-06-18", "2025-06-18");
      ("2025-03-26", "2025-03-26");
      ("2024-11-05", "2024-11-05");
      ("2099-01-01", "2025-11-25");
    ]

let tools () =
  let json = response (handle (request "tools/list")) in
  match required "tools" (required "result" json) with
  | `List tools -> tools
  | _ -> Alcotest.fail "tools is not an array"

let contains haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop index =
    if index + needle_length > length then false
    else if String.equal (String.sub haystack index needle_length) needle then true
    else loop (index + 1)
  in
  needle_length = 0 || loop 0

let test_catalogue () =
  (* mcp-gurs: tools/list advertises the existing read-only HTTP catalogue. *)
  let tools = tools () in
  Alcotest.(check int) "tool count" 20 (List.length tools);
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " listed") true
        (List.exists
           (fun tool -> member "name" tool = Some (`String name))
           tools))
    [
      "inn_status";
      "inn_services";
      "inn_search_traces";
      "inn_stats";
      "inn_openapi";
      "inn_docs_index";
      "inn_get_doc";
    ]

let test_window_arguments_in_schemas () =
  (* win-2olw, srch-reld: schemas advertise every matching filter. *)
  let tools = tools () in
  let check name expected =
    match List.find_opt (fun tool -> member "name" tool = Some (`String name)) tools with
    | None -> Alcotest.failf "%s is not listed" name
    | Some tool ->
        let properties = required "properties" (required "inputSchema" tool) in
        List.iter
          (fun property ->
            Alcotest.(check bool)
              (name ^ " lists " ^ property) true
              (match member property properties with
              | Some (`Assoc _) -> true
              | _ -> false))
          expected
  in
  check "inn_services" [ "lookback" ];
  check "inn_search_traces" [ "lookback"; "cursor"; "minDurationMs"; "attributeContains" ];
  check "inn_get_trace_spans" [ "lookback"; "cursor"; "limit" ];
  check "inn_get_trace_logs" [ "lookback"; "cursor"; "limit"; "attributeContains" ];
  check "inn_search_spans" [ "lookback"; "cursor"; "minDurationMs"; "attributeContains" ];
  check "inn_get_span_logs" [ "lookback"; "cursor"; "limit"; "attributeContains" ];
  check "inn_search_logs" [ "lookback"; "cursor"; "minSeverity"; "attributeContains" ];
  check "inn_trace_stats" [ "lookback"; "minDurationMs"; "attributeContains" ];
  check "inn_log_stats" [ "lookback"; "minSeverity"; "attributeContains" ];
  check "inn_facets" [ "lookback" ];
  check "inn_metrics" [ "lookback"; "cursor" ];
  check "inn_stats" [ "lookback" ];
  check "inn_get_doc" [ "name" ]

let test_window_arguments_reach_http () =
  (* win-2olw and ret-eeb1: the tool arguments become query parameters. *)
  let paths = ref [] in
  let stats_body =
    {|{"spans":1,"logs":2,"retention":{"tracesTtlHours":48,"lastPrune":null}}|}
  in
  let request path =
    paths := path :: !paths;
    if contains path "/stats" then Ok (200, stats_body) else Ok (200, "{}")
  in
  let tool_call =
    Mcp.tool_call ~request ~status:(fun () -> `Assoc [])
      ~base_url:"http://127.0.0.1:27687"
  in
  let call name args =
    match tool_call name args with
    | Ok _ -> ()
    | Error message -> Alcotest.failf "%s: %s" name message
  in
  call "inn_search_logs"
    (`Assoc
      [
        ("lookback", `String "15m");
        ("cursor", `String "abc-def");
        ("limit", `Int 5);
        ("minSeverity", `String "warn");
        ("attributeContains", `Assoc [ ("tag", `String "50%") ]);
      ]);
  call "inn_services" (`Assoc [ ("lookback", `String "2h") ]);
  let stats_text =
    match tool_call "inn_stats" (`Assoc [ ("lookback", `String "1h") ]) with
    | Ok text -> text
    | Error message -> Alcotest.fail message
  in
  Alcotest.(check bool)
    "inn_stats returns the retention section (ret-eeb1)" true
    (contains stats_text "retention");
  call "inn_search_traces"
    (`Assoc [ ("lookback", `String "all"); ("cursor", `String "xyz");
      ("minDurationMs", `Float 5.);
      ("attributeContains", `Assoc [ ("tag", `String "50%") ]) ]);
  let paths = List.rev !paths in
  let check_contains index fragment =
    match List.nth_opt paths index with
    | None -> Alcotest.failf "call %d did not reach HTTP" index
    | Some path ->
        Alcotest.(check bool)
          (Printf.sprintf "call %d carries %s (win-2olw)" index fragment) true
          (contains path fragment)
  in
  check_contains 0 "lookback=15m";
  check_contains 0 "cursor=abc-def";
  check_contains 0 "limit=5";
  check_contains 0 "minSeverity=warn";
  check_contains 0 "attrContains.tag=50%25";
  check_contains 0 "/logs/search";
  check_contains 1 "/services?lookback=2h";
  (* inn_stats proxies GET /stats, so the retention section is reachable from
     MCP (ret-eeb1). *)
  Alcotest.(check (option string))
    "inn_stats proxies /stats (ret-eeb1)" (Some "/stats?lookback=1h")
    (List.nth_opt paths 2);
  check_contains 3 "/traces/search";
  check_contains 3 "lookback=all";
  check_contains 3 "cursor=xyz";
  check_contains 3 "minDurationMs=5";
  check_contains 3 "attrContains.tag=50%25"

let test_docs_tools () =
  (* desc-s5j5: inn_docs_index and inn_get_doc read the guides over MCP. *)
  let paths = ref [] in
  let request path =
    paths := path :: !paths;
    Ok (200, {|{"guides":[{"name":"debug","title":"Debugging with Inn","path":"/docs/debug"}]}|})
  in
  let tool_call =
    Mcp.tool_call ~request ~status:(fun () -> `Assoc [])
      ~base_url:"http://127.0.0.1:27687"
  in
  (match tool_call "inn_docs_index" (`Assoc []) with
  | Ok text ->
      Alcotest.(check bool) "the index is returned" true (contains text "debug")
  | Error message -> Alcotest.fail message);
  (match tool_call "inn_get_doc" (`Assoc [ ("name", `String "debug") ]) with
  | Ok _ -> ()
  | Error message -> Alcotest.fail message);
  Alcotest.(check (list string))
    "the docs tools proxy the docs endpoints" [ "/docs"; "/docs/debug" ]
    (List.rev !paths);
  match tool_call "inn_get_doc" (`Assoc []) with
  | Ok _ -> Alcotest.fail "a missing name must be a tool error"
  | Error message ->
      Alcotest.(check bool) "the error names the argument" true
        (contains message "name")

let test_down_server () =
  (* mcp-j7lb: connection errors stay tool results, not protocol errors. *)
  let tool_call =
    Mcp.tool_call
      ~request:(fun _ -> Error "connection refused")
      ~status:(fun () -> `Assoc [])
      ~base_url:"http://127.0.0.1:27687"
  in
  let json =
    response
      (Mcp.handle_request ~tool_call
         (request
            ~params:(`Assoc [ ("name", `String "inn_services") ])
            "tools/call"))
  in
  let result = required "result" json in
  Alcotest.(check bool) "isError" true (required "isError" result = `Bool true);
  match required "content" result with
  | `List [ content ] -> (
      match required "text" content with
      | `String message ->
          Alcotest.(check bool)
            "startup hint" true
            (let needle = "inn daemon" in
             let n = String.length needle in
             let rec search i =
               i + n <= String.length message
               && (String.sub message i n = needle || search (i + 1))
             in
             search 0)
      | _ -> Alcotest.fail "text content missing")
  | _ -> Alcotest.fail "content is not a singleton text list"

let test_protocol_errors () =
  (* mcp-i9qo, mcp-v9fl: notifications never execute or respond. *)
  let notification =
    `Assoc [ ("jsonrpc", `String "2.0"); ("method", `String "tools/call") ]
  in
  Alcotest.(check bool)
    "notification no response" true
    (handle notification = None);
  let unknown = response (handle (request "unknown/method")) in
  Alcotest.(check int)
    "unknown method" (-32601)
    (match required "code" (required "error" unknown) with
    | `Int code -> code
    | _ -> Alcotest.fail "missing error code");
  let invalid = response (handle (`List [])) in
  Alcotest.(check int)
    "batch invalid" (-32600)
    (match required "code" (required "error" invalid) with
    | `Int code -> code
    | _ -> Alcotest.fail "missing error code");
  let parse = response (Mcp.handle_line ~tool_call:unavailable "{bad") in
  Alcotest.(check int)
    "parse error" (-32700)
    (match required "code" (required "error" parse) with
    | `Int code -> code
    | _ -> Alcotest.fail "missing error code")

let () =
  Alcotest.run "mcp-stdio"
    [
      ( "protocol",
        [
          Alcotest.test_case "mcp-592g mcp-zxs5 version negotiation" `Quick
            test_versions;
          Alcotest.test_case "mcp-gurs tools catalogue" `Quick test_catalogue;
          Alcotest.test_case "window and filter arguments in schemas (win-2olw, srch-reld)" `Quick
            test_window_arguments_in_schemas;
          Alcotest.test_case "window and filter arguments reach HTTP (win-2olw, srch-reld)"
            `Quick test_window_arguments_reach_http;
          Alcotest.test_case "desc-s5j5 docs tools reach the docs endpoints"
            `Quick test_docs_tools;
          Alcotest.test_case "mcp-j7lb server down" `Quick test_down_server;
          Alcotest.test_case "mcp-i9qo mcp-v9fl errors notifications" `Quick
            test_protocol_errors;
        ] );
    ]
