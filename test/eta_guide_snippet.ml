let run () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let http_client =
    Eta_http.Client.create ~sw ~net:(Eio.Stdenv.net stdenv) ~clock ()
  in
  let exporter =
    match
      Eta_otel.create ~sw ~clock ~http_client
        ~endpoint:"http://127.0.0.1:27687" ~service_name:"my-app"
        ~resource:[ ("service.version", "0.1.0") ] ()
    with
    | Ok exporter -> exporter
    | Error error -> failwith (Format.asprintf "%a" Eta_otel.pp_error error)
  in
  let logger =
    Eta_observability.Logger.create ~service:"my-app" ~clock
      ~mono_clock:stdenv#mono_clock ~reporter:(Eta_otel.reporter exporter)
      ~span_ids:(Eta_otel.span_ids exporter) ()
  in
  let result =
    Eta_observability.Logger.span logger "http.request" (fun () ->
        Eta_observability.Logger.info logger "work completed";
        Ok "ok")
  in
  let settlement = Eta_otel.shutdown exporter in
  (result, settlement)
