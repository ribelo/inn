type 'a decoded = { items : 'a list; rejected : int; error_message : string }

type payload = {
  spans : Model.span list;
  logs : Model.log_record list;
  metric_points : Model.metric_point list;
}

val empty : payload
val decode_traces_json : string -> (Model.span decoded, string) result
val decode_logs_json : string -> (Model.log_record decoded, string) result
val decode_metrics_json : string -> (Model.metric_point decoded, string) result
