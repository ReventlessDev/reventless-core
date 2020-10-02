let publish = topic =>
  (. json) =>
    topic->Util_SNS_Runtime.publish(json |> Js.Json.stringify);