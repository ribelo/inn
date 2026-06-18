type payload = {
  spans : Model.span list;
  logs : Model.log_record list;
  metric_points : Model.metric_point list;
}

val empty : payload
val decode_traces_json : string -> (Model.span list, string) result
val decode_logs_json : string -> (Model.log_record list, string) result
val decode_metrics_json : string -> (Model.metric_point list, string) result
