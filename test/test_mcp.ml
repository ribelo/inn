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

let test_catalogue () =
  (* mcp-gurs: tools/list advertises the existing read-only HTTP catalogue. *)
  let json = response (handle (request "tools/list")) in
  match required "tools" (required "result" json) with
  | `List tools ->
      Alcotest.(check int) "tool count" 20 (List.length tools);
      List.iter
        (fun name ->
          Alcotest.(check bool)
            (name ^ " listed") true
            (List.exists
               (fun tool -> member "name" tool = Some (`String name))
               tools))
        [ "inn_status"; "inn_services"; "inn_search_traces"; "inn_openapi" ]
  | _ -> Alcotest.fail "tools is not an array"

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
          Alcotest.test_case "mcp-j7lb server down" `Quick test_down_server;
          Alcotest.test_case "mcp-i9qo mcp-v9fl errors notifications" `Quick
            test_protocol_errors;
        ] );
    ]
