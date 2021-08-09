let publish = topic =>
  (. id, _meta, json) =>
    topic->Util_SNS_Runtime.publishFifo(
      ~messageGroupId=id,
      ~message=json |> Js.Json.stringify,
    );
