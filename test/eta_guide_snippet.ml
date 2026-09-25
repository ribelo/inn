open Eta

let run () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in

  let runtime_factory tracer = Eta_eio.Runtime.create ~sw ~clock ~tracer () in
  let http_client = Eta_http_eio.Client.make_h1 ~sw ~net () in

  let exporter =
    Eta_otel.create ~runtime_factory ~http_client ~clock:(Eta_eio.clock clock)
      ~endpoint:(Eta_http.Core.Url.of_string "http://127.0.0.1:27687")
      ~service_name:"my-app" ~service_version:"0.1.0" ()
  in

  let rt =
    Eta_eio.Runtime.create ~sw ~clock
      ~tracer:(Eta_otel.tracer exporter)
      ~logger:(Eta_otel.logger exporter)
      ~meter:(Eta_otel.meter exporter) ()
  in

  let work = Eta_observability.named "http.request" (Effect.pure "ok") in
  let result = Eta.Runtime.run rt work in
  let settlement = Eta_otel.shutdown exporter in
  (result, settlement)
