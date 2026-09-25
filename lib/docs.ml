(* The embedded agent guides. The Markdown lives in docs/guides and is compiled
   into the binary by the dune rule that generates [Docs_data], so the server
   depends on no checkout path at run time (desc-bqwh). *)

type guide = {
  name : string;
  title : string;
  path : string;
  content : string;
}

let guides =
  List.map
    (fun (name, title, content) -> { name; title; path = "/docs/" ^ name; content })
    Docs_data.guides

let find name = List.find_opt (fun guide -> String.equal guide.name name) guides

let names = List.map (fun guide -> guide.name) guides

let index_json () =
  `Assoc
    [
      ( "guides",
        `List
          (List.map
             (fun guide ->
               `Assoc
                 [
                   ("name", `String guide.name);
                   ("title", `String guide.title);
                   ("path", `String guide.path);
                 ])
             guides) );
    ]
