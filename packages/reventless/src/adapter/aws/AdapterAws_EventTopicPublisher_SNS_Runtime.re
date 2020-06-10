let publish = topic =>
  (. json) =>
    topic->AdapterAws_Util_SNS_Runtime.publish(json |> Js.Json.stringify);