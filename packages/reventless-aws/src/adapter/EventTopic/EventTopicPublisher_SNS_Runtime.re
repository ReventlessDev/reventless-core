let publish = topic =>
  (. _id, _meta, json) =>
    topic->Util_SNS_Runtime.publish(json->Js.Json.stringify);
